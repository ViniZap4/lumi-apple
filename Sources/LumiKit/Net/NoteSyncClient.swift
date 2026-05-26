import Foundation

/// `URLSessionWebSocketTask`-backed subscription to a lumi-server v2 note's
/// live-sync channel (`WSS /api/vaults/:vault/notes/:id/sync`).
///
/// **Scope:** the WS client itself only handles the framing — opens the
/// socket, sends `SyncStep1` with the caller-supplied state vector, and
/// emits events carrying raw `Data` payloads. Decoding + applying the
/// CRDT updates lives in `LumiCRDT` (Phase H slice 1) and is wired in
/// by `RemoteVaultsStore` (Phase H slice 2). Slice 4e originally
/// discarded the payload; H.2 carries it through.
///
/// Auth: lumi-server's WS endpoints accept `?token=` query-string auth
/// because browsers cannot set custom headers on WebSocket upgrades. We
/// use the same path everywhere — the token is appended to the URL.
///
/// **Threading contract:** `start(stateVector:)` and `stop()` must be
/// called from a single actor (typically `@MainActor` via the store).
/// The detached read loop captures the `URLSessionWebSocketTask` by value
/// and feeds events through the `AsyncStream` continuation (thread-safe
/// per `AsyncStream.Continuation` docs).
public final class NoteSyncClient: @unchecked Sendable {
    /// Event surface delivered via the `events` AsyncStream.
    public enum Event: Sendable, Equatable {
        /// WebSocket handshake succeeded; we're subscribed and SyncStep1
        /// has been sent. Pure signal — no body.
        case opened

        /// Server replied to our SyncStep1 with the missing-update diff.
        /// `payload` is the lib0-v1 encoded Y.Doc update — feed it into
        /// `LumiCRDT.apply(update:)`. Slice H.2 added the payload (slice
        /// 4e discarded it).
        case syncStep2(payload: Data)

        /// Fan-out from another client (or our own REST writes echoing
        /// through the hub). `payload` is the lib0-v1 encoded incremental
        /// Y.Doc update — apply it to merge the remote edit live.
        case syncUpdate(payload: Data)

        /// Opaque awareness blob. Reserved for a future slice that wires
        /// cursors / presence.
        case awareness(payload: Data)

        /// Connection closed cleanly or with an error. `reason` is best-
        /// effort; nil means clean close.
        case closed(reason: String?)

        /// Connection closed for a *transient* reason (network blip, server
        /// restart, decode error). Emitted right before `.closed` so the
        /// host knows the close wasn't user-initiated. Carries the suggested
        /// attempt number to use on the next `subscribeToOpenNote` call,
        /// plus a delay (seconds) computed via exponential backoff with
        /// jitter. Slice 4f.
        case willReconnect(attempt: Int, delaySeconds: Double)
    }

    private let baseURL: URL
    private let token: String
    private let vaultID: UUID
    private let noteID: String
    private let session: URLSession
    /// The 1-based attempt number for *this* connection. Slice 4f hosts
    /// pass an incremented attempt when re-subscribing after a transient
    /// close so the emitted `.willReconnect(attempt:)` can carry the
    /// correct "next attempt" number without the host having to do its
    /// own arithmetic. Initial subscribes default to 1.
    private let attempt: Int

    private let continuation: AsyncStream<Event>.Continuation
    public let events: AsyncStream<Event>

    /// Mutable state — owned by the calling actor (start/stop contract).
    /// Reads from inside the detached receive loop are avoided by
    /// capturing the task into the Task closure on creation.
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    public init(
        baseURL: URL,
        token: String,
        vaultID: UUID,
        noteID: String,
        session: URLSession = .shared,
        attempt: Int = 1
    ) {
        self.baseURL = baseURL
        self.token = token
        self.vaultID = vaultID
        self.noteID = noteID
        self.session = session
        self.attempt = max(1, attempt)
        var c: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { c = $0 }
        self.continuation = c
    }

    deinit {
        receiveTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }

    /// Build the WS URL by swapping the scheme (http→ws, https→wss),
    /// appending the sync path, and stamping the auth token in the query
    /// string. Returns nil if the configured baseURL is structurally
    /// unusable.
    public func wsURL() -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        let slugEscaped = noteID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? noteID
        let basePath = components.path.isEmpty || components.path == "/" ? "" : components.path
        // Use `percentEncodedPath` because slugEscaped is *already* encoded.
        // Setting `.path` would re-encode the `%` characters and produce
        // `%2520` instead of `%20` for a space.
        components.percentEncodedPath = basePath + "/api/vaults/\(vaultID.uuidString.lowercased())/notes/\(slugEscaped)/sync"
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "token" }
        query.append(URLQueryItem(name: "token", value: token))
        components.queryItems = query
        return components.url
    }

    /// Open the WS connection. Sends `SyncStep1(stateVector)` on success.
    /// Idempotent — calling twice is a no-op while a task is alive. The
    /// `stateVector` is the base64-decoded form of the snapshot's clock
    /// (pass empty Data if unknown — the server will reply with the full
    /// state on Step2).
    public func start(stateVector: Data) {
        guard task == nil else { return }
        guard let url = wsURL() else {
            continuation.yield(.closed(reason: "invalid server URL"))
            return
        }
        let req = URLRequest(url: url)
        let newTask = session.webSocketTask(with: req)
        task = newTask
        newTask.resume()

        let step1 = YProtocol.encodeSyncStep1(stateVector: stateVector)
        let cont = continuation
        newTask.send(.data(step1)) { err in
            if let err {
                cont.yield(.closed(reason: "send step1: \(err.localizedDescription)"))
            } else {
                cont.yield(.opened)
            }
        }

        // Capture task + continuation by value so the detached loop never
        // touches `self` — no actor-isolation question, no race against
        // a concurrent `stop()` that nils them on the calling actor.
        let myAttempt = attempt
        receiveTask = Task.detached { [newTask, cont, myAttempt] in
            await Self.runReceiveLoop(task: newTask, continuation: cont, attempt: myAttempt)
        }
    }

    /// Send an awareness frame to the server. The server fans it out to
    /// every other subscriber on the same room (it does NOT persist
    /// awareness). `payload` is the opaque application-defined body —
    /// in lumi we send JSON-encoded `PresenceState`. No-op when the
    /// connection isn't open. Phase H slice 4.
    public func send(awareness payload: Data) {
        guard let task else { return }
        let frame = YProtocol.encodeAwareness(payload)
        task.send(.data(frame)) { _ in
            // Best-effort. A failure here is the same shape as any other
            // WS send failure — the read loop will surface a .closed
            // event and the host will reconnect.
        }
    }

    /// Tear down the connection. Idempotent. Caller must invoke from the
    /// same actor as `start()` (no internal serialization).
    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        // 1000 = normal closure
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    // MARK: - Receive loop

    private static func runReceiveLoop(
        task: URLSessionWebSocketTask,
        continuation: AsyncStream<Event>.Continuation,
        attempt: Int
    ) async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                let data: Data
                switch msg {
                case .data(let d): data = d
                case .string(let s):
                    // Server spec'd to send binary frames — text means a
                    // misbehaving peer. Surface as a close. This is a
                    // protocol mismatch, not a transient blip — no
                    // willReconnect signal.
                    continuation.yield(.closed(reason: "unexpected text frame: \(s.prefix(40))"))
                    return
                @unknown default:
                    continuation.yield(.closed(reason: "unknown frame type"))
                    return
                }
                handleIncoming(data, continuation: continuation)
            } catch is CancellationError {
                // Explicit stop() on our side — no reconnect signal.
                return
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                // WS task cancelled (also from stop()) — clean close.
                continuation.yield(.closed(reason: nil))
                return
            } catch {
                // Anything else is treated as a transient close: network
                // hiccup, server restart, ENOTCONN after a clean close
                // from the peer. Emit `.willReconnect` so the host can
                // schedule a retry, then the terminal `.closed`.
                let nextAttempt = attempt + 1
                let delay = backoffSeconds(attempt: nextAttempt)
                continuation.yield(.willReconnect(attempt: nextAttempt, delaySeconds: delay))
                let nserr = error as NSError
                if nserr.domain == NSPOSIXErrorDomain && nserr.code == 57 {
                    continuation.yield(.closed(reason: nil))
                } else {
                    continuation.yield(.closed(reason: error.localizedDescription))
                }
                return
            }
        }
    }

    // MARK: - Backoff

    /// Exponential backoff with jitter for slice 4f reconnect timing.
    ///
    /// Base curve: `min(32, 2^(attempt-1))` seconds — so attempt 1 → 1s,
    /// 2 → 2s, 3 → 4s … 6+ → 32s (the cap). On top of that we layer
    /// ±20% uniform jitter so independent clients don't lock-step into
    /// the same retry instant after a regional outage.
    ///
    /// Pure (deterministic up to the jitter random) — exposed as a
    /// static so the host can compute its own delay if it ever needs to
    /// (e.g. to display "retrying in Xs" to the user without waiting
    /// for the WS to actually emit `.willReconnect`).
    public static func backoffSeconds(attempt: Int) -> Double {
        let n = max(1, attempt)
        let raw = pow(2.0, Double(n - 1))
        let capped = min(32.0, raw)
        let jitter = Double.random(in: -0.2 ... 0.2) * capped
        // Clamp at >=0 to avoid negative sleeps if jitter undershoots
        // a small base (shouldn't happen at 1s with ±20%, but cheap).
        return max(0, capped + jitter)
    }

    private static func handleIncoming(
        _ data: Data,
        continuation: AsyncStream<Event>.Continuation
    ) {
        do {
            let parsed = try YProtocol.decode(data)
            switch parsed.type {
            case YProtocol.messageSync:
                switch parsed.syncSub {
                case YProtocol.syncStep1:
                    // Server's own initial Step1 — it asks us for a diff.
                    // Slice 4e doesn't maintain a Y.Doc, so we can't
                    // produce Step2. Silently drop; subsequent updates
                    // still fan out via the hub.
                    return
                case YProtocol.syncStep2:
                    continuation.yield(.syncStep2(payload: parsed.body))
                case YProtocol.syncUpdate:
                    continuation.yield(.syncUpdate(payload: parsed.body))
                default:
                    return
                }
            case YProtocol.messageAwareness:
                continuation.yield(.awareness(payload: parsed.body))
            case YProtocol.messageQueryAwareness, YProtocol.messageAuth:
                // Nothing host-actionable in slice 4e.
                return
            default:
                return
            }
        } catch {
            // Malformed frame — a peer shipping bad framing is a server
            // bug; we don't try to resync.
            continuation.yield(.closed(reason: "decode: \(error)"))
        }
    }
}
