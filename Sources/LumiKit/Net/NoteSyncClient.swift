import Foundation

/// `URLSessionWebSocketTask`-backed subscription to a lumi-server v2 note's
/// live-sync channel (`WSS /api/vaults/:vault/notes/:id/sync`).
///
/// **Scope (E.1.2 slice 4e):** Apple-side decoding of Yjs CRDT updates is
/// deferred until a future Phase H slice adds a yswift-equivalent Swift
/// binding. This client opens the WS, sends the initial `SyncStep1` with
/// our last-known state vector, and surfaces *signals* to consumers ("a
/// remote update arrived") so the host can refetch the snapshot via REST.
/// We do not decode or apply Y.Doc updates locally.
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
        /// Body discarded by slice 4e since we don't apply CRDT updates;
        /// host treats this the same as `syncUpdate` (refetch trigger).
        case syncStep2

        /// Fan-out from another client (or our own REST writes echoing
        /// through the hub). Host should refetch the snapshot when not
        /// dirty, or surface a "remote changes pending" hint when dirty.
        case syncUpdate

        /// Opaque awareness blob. Reserved for a future slice that wires
        /// cursors / presence.
        case awareness(payload: Data)

        /// Connection closed cleanly or with an error. `reason` is best-
        /// effort; nil means clean close.
        case closed(reason: String?)
    }

    private let baseURL: URL
    private let token: String
    private let vaultID: UUID
    private let noteID: String
    private let session: URLSession

    private let continuation: AsyncStream<Event>.Continuation
    public let events: AsyncStream<Event>

    /// Mutable state — owned by the calling actor (start/stop contract).
    /// Reads from inside the detached receive loop are avoided by
    /// capturing the task into the Task closure on creation.
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    public init(baseURL: URL, token: String, vaultID: UUID, noteID: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.vaultID = vaultID
        self.noteID = noteID
        self.session = session
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
        receiveTask = Task.detached { [newTask, cont] in
            await Self.runReceiveLoop(task: newTask, continuation: cont)
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
        continuation: AsyncStream<Event>.Continuation
    ) async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                let data: Data
                switch msg {
                case .data(let d): data = d
                case .string(let s):
                    // Server spec'd to send binary frames — text means a
                    // misbehaving peer. Surface as a close.
                    continuation.yield(.closed(reason: "unexpected text frame: \(s.prefix(40))"))
                    return
                @unknown default:
                    continuation.yield(.closed(reason: "unknown frame type"))
                    return
                }
                handleIncoming(data, continuation: continuation)
            } catch is CancellationError {
                return
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                continuation.yield(.closed(reason: nil))
                return
            } catch {
                // `receive()` after a normal close returns POSIX 57
                // (ENOTCONN) on Apple platforms — surface as a clean
                // disconnect rather than an error.
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
                    continuation.yield(.syncStep2)
                case YProtocol.syncUpdate:
                    continuation.yield(.syncUpdate)
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
