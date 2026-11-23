import Foundation
import Synchronization

/// Raw WebSocket-level events of one connection attempt.
public enum TransportEvent: Sendable, Equatable {
    /// The socket is open (first frame or pong received).
    case opened
    /// One binary frame.
    case message(Data)
    /// The socket closed. `code` is the WebSocket close code when the
    /// peer sent one (4401/4403/4404/1008/1011…), nil for a transport
    /// failure (network drop, refused upgrade → browser-style 1006).
    case closed(code: Int?, reason: String?)
}

/// One live connection. Implementations must be safe to call from any
/// isolation domain.
public protocol SyncTransport: AnyObject, Sendable {
    var events: AsyncStream<TransportEvent> { get }
    /// CRDT lineage (`crdt_epoch`) of the doc this connection joins, from
    /// the ws-ticket it was dialled with. Nil without a ticket or on
    /// servers predating the field.
    var crdtEpoch: String? { get }
    /// True when the upgrade authenticated with a single-use ws-ticket
    /// (a 4401 may then just mean "stale ticket": re-mint once).
    var usedTicket: Bool { get }
    func send(_ frame: Data)
    func close()
    /// Close with an application code (e.g. client-side 4409
    /// `ReplicaLineage.closeLineageChanged`).
    func close(code: Int, reason: String?)
}

extension SyncTransport {
    public var crdtEpoch: String? { nil }
    public var usedTicket: Bool { false }
    public func close(code: Int, reason: String?) { close() }
}

/// Opens connections for a note session: resolves auth (ws-ticket first,
/// `?token=` fallback), builds the URL and dials. Also answers the
/// auth probe of CRDT-CLIENT-PROTOCOL §5.
public protocol SyncConnector: Sendable {
    func connect(vaultID: UUID, noteID: String) async throws(SyncConnectError) -> any SyncTransport
    func probeAuth() async -> AuthProbeResult
    /// Lineage identity of the note (`crdt_epoch` + `created_at`, from
    /// `GET …/notes/:id`), checked before a persisted replica is merged
    /// (`ReplicaLineage`).
    func noteLineage(vaultID: UUID, noteID: String) async -> NoteLineageProbe
}

extension SyncConnector {
    /// Connectors that cannot look the note up skip the stamp check; the
    /// state-vector half of the lineage guard still runs.
    public func noteLineage(vaultID: UUID, noteID: String) async -> NoteLineageProbe { .unsupported }
}

/// Answer of `SyncConnector.noteLineage`.
public enum NoteLineageProbe: Sendable, Equatable {
    /// The note exists. `crdtEpoch` is the server's lineage id (nil on
    /// servers predating it); `createdAt` is the row's stamp (second
    /// resolution), the fallback identity.
    case note(createdAt: Date?, crdtEpoch: String?)
    /// 404: the note is gone.
    case notFound
    case unauthorized
    case forbidden
    /// Network failure — retry with backoff.
    case unavailable(String)
    /// No identity available (connector without REST).
    case unsupported

    /// A pre-epoch server's answer: only the stamp.
    public static func createdAt(_ date: Date) -> NoteLineageProbe {
        .note(createdAt: date, crdtEpoch: nil)
    }
}

public enum SyncConnectError: Error, Sendable, Equatable {
    /// The token is dead (ticket endpoint said 401). Terminal.
    case unauthorized
    /// The caller lacks `note.edit`. Terminal.
    case forbidden
    /// Missing server URL / token — nothing to dial.
    case notConfigured
    /// Network failure resolving auth; retry with backoff.
    case transient(String)
}

public enum AuthProbeResult: Sendable, Equatable {
    case ok
    case unauthorized
    case unknown
}

/// `URLSessionWebSocketTask`-backed transport.
public final class WebSocketTransport: SyncTransport {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let task: URLSessionWebSocketTask
    private let state = Mutex<(opened: Bool, finished: Bool, loop: Task<Void, Never>?)>((false, false, nil))
    public let crdtEpoch: String?
    public let usedTicket: Bool

    public init(url: URL, session: URLSession = .shared, crdtEpoch: String? = nil, usedTicket: Bool = false) {
        self.crdtEpoch = ReplicaLineage.normalized(crdtEpoch)
        self.usedTicket = usedTicket
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        task = session.webSocketTask(with: url)
        // Server→client Step2 for a large note can exceed the 1 MiB
        // default; the server caps *inbound* frames at 1 MiB.
        task.maximumMessageSize = 64 << 20
        task.resume()
        let loop = Task.detached { [task, weak self] in
            while !Task.isCancelled {
                do {
                    let msg = try await task.receive()
                    // y-protocols is binary-only; text frames are ignored.
                    if case .data(let d) = msg { self?.deliver(d) }
                } catch {
                    let raw = task.closeCode.rawValue
                    let code: Int? = raw == 0 ? nil : raw
                    let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
                    self?.finish(code: code, reason: reason ?? error.localizedDescription)
                    return
                }
            }
        }
        state.withLock { $0.loop = loop }
        // A pong proves the upgrade succeeded even if the server stays
        // quiet (it always sends Step1 first, so this is belt and braces).
        task.sendPing { [weak self] error in
            if error == nil { self?.markOpened() }
        }
    }

    deinit {
        state.withLock { $0.loop?.cancel() }
        task.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }

    public func send(_ frame: Data) {
        task.send(.data(frame)) { _ in
            // Failures surface through the receive loop's close.
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        finish(code: 1000, reason: nil)
    }

    public func close(code: Int, reason: String?) {
        let wsCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: wsCode, reason: reason.flatMap { $0.data(using: .utf8) })
        finish(code: code, reason: reason)
    }

    fileprivate func markOpened() {
        let first = state.withLock { s -> Bool in
            guard !s.opened, !s.finished else { return false }
            s.opened = true
            return true
        }
        if first { continuation.yield(.opened) }
    }

    fileprivate func deliver(_ data: Data) {
        markOpened()
        continuation.yield(.message(data))
    }

    fileprivate func finish(code: Int?, reason: String?) {
        let first = state.withLock { s -> Bool in
            guard !s.finished else { return false }
            s.finished = true
            s.loop?.cancel()
            return true
        }
        guard first else { return }
        continuation.yield(.closed(code: code, reason: reason))
        continuation.finish()
    }
}

/// Production connector against a `LumiAPIClient` account.
public final class WebSocketConnector: SyncConnector {
    private let client: LumiAPIClient
    private let session: URLSession
    /// Set once the server answered 404 on the ticket endpoint (older
    /// server): skip straight to `?token=` afterwards.
    private let ticketUnsupported = Mutex(false)

    public init(client: LumiAPIClient, session: URLSession = .shared) {
        self.client = client
        self.session = session
    }

    public func connect(vaultID: UUID, noteID: String) async throws(SyncConnectError) -> any SyncTransport {
        guard let baseURL = await client.baseURL,
              let token = await client.token, !token.isEmpty
        else { throw .notConfigured }
        var auth = SyncAuth.token(token)
        var epoch: String?
        if !ticketUnsupported.withLock({ $0 }) {
            do {
                let t = try await client.createWSTicket(vaultID: vaultID, noteID: noteID)
                auth = .ticket(t.ticket)
                epoch = t.crdtEpoch
            } catch {
                switch error {
                case .server(404, _, _), .invalidResponse(404):
                    ticketUnsupported.withLock { $0 = true }
                case .unauthorized, .server(401, _, _):
                    throw .unauthorized
                case .server(403, _, _):
                    throw .forbidden
                case .network(let m):
                    throw .transient(m)
                default:
                    // Unknown failure on an optional endpoint: fall back
                    // to the token rather than stall the editor.
                    break
                }
            }
        }
        guard let url = SyncURL.make(baseURL: baseURL, vaultID: vaultID, noteID: noteID, auth: auth) else {
            throw .notConfigured
        }
        let usedTicket: Bool
        if case .ticket = auth { usedTicket = true } else { usedTicket = false }
        return WebSocketTransport(url: url, session: session, crdtEpoch: epoch, usedTicket: usedTicket)
    }

    public func noteLineage(vaultID: UUID, noteID: String) async -> NoteLineageProbe {
        do {
            let note = try await client.getNote(vaultID: vaultID, noteID: noteID)
            let epoch = ReplicaLineage.normalized(note.crdtEpoch)
            if note.createdAt == nil && epoch == nil { return .unsupported }
            return .note(createdAt: note.createdAt, crdtEpoch: epoch)
        } catch {
            switch error {
            case .unauthorized, .server(401, _, _): return .unauthorized
            case .server(403, _, _): return .forbidden
            case .server(404, _, _), .invalidResponse(404): return .notFound
            case .network(let m): return .unavailable(m)
            default: return .unavailable("\(error)")
            }
        }
    }

    public func probeAuth() async -> AuthProbeResult {
        do {
            _ = try await client.currentUser()
            return .ok
        } catch {
            switch error {
            case .unauthorized, .server(401, _, _): return .unauthorized
            default: return .unknown
            }
        }
    }
}

/// How the WebSocket upgrade authenticates.
public enum SyncAuth: Sendable, Equatable {
    /// Single-use, 30 s ticket from `POST …/ws-ticket` (`?ticket=`).
    case ticket(String)
    /// Legacy long-lived token (`?token=`), servers without tickets.
    case token(String)
}

public enum SyncURL {
    /// `ws(s)://host[/base]/api/vaults/:vault/notes/:id/sync?ticket=|token=`.
    public static func make(baseURL: URL, vaultID: UUID, noteID: String, auth: SyncAuth) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        let slug = noteID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? noteID
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + "/api/vaults/\(vaultID.uuidString.lowercased())/notes/\(slug)/sync"
        switch auth {
        case .ticket(let t): components.queryItems = [URLQueryItem(name: "ticket", value: t)]
        case .token(let t): components.queryItems = [URLQueryItem(name: "token", value: t)]
        }
        return components.url
    }
}

/// Reconnect backoff (CRDT-CLIENT-PROTOCOL §5): exponential from 100 ms,
/// capped at 2.5 s (y-websocket's curve), ±20 % jitter.
public enum SyncBackoff {
    public static let base: Double = 0.1
    public static let cap: Double = 2.5

    public static func delay(attempt: Int, jitter: Double = Double.random(in: -0.2...0.2)) -> Double {
        let n = max(1, attempt)
        let raw = min(cap, base * pow(2, Double(min(n - 1, 16))))
        return max(0, raw + raw * jitter)
    }
}
