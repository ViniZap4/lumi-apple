import Foundation
import Observation

#if canImport(YSwift)

/// One live CRDT session for one open server note
/// (CRDT-CLIENT-PROTOCOL §2). Owns the note's only replica for as long
/// as the note is open: reconnects reuse it (§5), refetches merge into
/// it (V8), and it is dropped only by `destroy()`.
///
/// State machine (§2.1): `connecting → syncing → live`, `live ↔
/// offline` on socket drops (still editable), terminal on fatal closes.
/// The editor is read-only until the first SyncStep2.
///
/// Main-actor isolated: local edits from the editor and remote frames
/// from the socket are applied on one serial executor, so the editor
/// buffer and the replica never interleave (§3.2).
@Observable
@MainActor
public final class NoteSyncSession: CollaborativeDocument {
    public let vaultID: UUID
    public let noteID: String

    public private(set) var phase: EditorSnapshot.Phase = .closed
    /// True once the first SyncStep2 arrived. Never flips back.
    public private(set) var hasSynced = false
    /// Y.Text was empty right after the first sync (§2.2.5 legacy note).
    public private(set) var emptyAtSync = false
    public private(set) var peers: [PeerPresence] = []
    public private(set) var reconnectStatus: ReconnectStatus?
    public private(set) var termination: SessionTermination?
    /// Local edits made while not live; cleared once a reconnect
    /// handshake delivered them (§5: the doc is the queue).
    public private(set) var hasPendingLocalChanges = false
    /// Bumped on every text change (local or remote). Read-only views
    /// observe this through `text`.
    public private(set) var revision = 0
    /// Last transport-level problem worth surfacing ("cannot reach live
    /// editing"), nil when healthy.
    public private(set) var connectionNotice: String?

    @ObservationIgnored public var changeHandler: ((DocumentChange) -> Void)?
    /// Called once when the session concludes the token is dead.
    @ObservationIgnored public var onUnauthorized: (() -> Void)?

    @ObservationIgnored private let crdt: LumiCRDT
    @ObservationIgnored private let connector: any SyncConnector
    @ObservationIgnored private var awareness: AwarenessState
    @ObservationIgnored private var transport: (any SyncTransport)?
    @ObservationIgnored private var transportOpen = false
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var failedOpens = 0
    @ObservationIgnored private var destroyed = false
    @ObservationIgnored private var textCache: String?
    /// Consecutive never-opened attempts before probing auth (§5).
    @ObservationIgnored public var probeAfterFailures = 2
    /// Test seam: the reconnect delay for an attempt.
    @ObservationIgnored public var backoff: @Sendable (Int) -> Double = { SyncBackoff.delay(attempt: $0) }
    @ObservationIgnored public var tickInterval: Double = 3

    public init(
        vaultID: UUID,
        noteID: String,
        connector: any SyncConnector,
        user: AwarenessUser?,
        awarenessClientID: UInt64 = AwarenessState.randomClientID()
    ) {
        self.vaultID = vaultID
        self.noteID = noteID
        self.connector = connector
        self.crdt = LumiCRDT()
        self.awareness = AwarenessState(clientID: awarenessClientID)
        if let user {
            _ = awareness.setLocal(user.stateJSON())
        }
    }

    // MARK: - Lifecycle

    /// Start connecting. Idempotent.
    public func start() {
        guard !destroyed, connectTask == nil, transport == nil, termination == nil else { return }
        phase = hasSynced ? .offline : .connecting
        attempt += 1
        connectTask = Task { [weak self] in await self?.connect() }
        startTicking()
    }

    /// Tear down: announce leaving, close the socket, drop the replica
    /// (provider first, then the doc — §2.2.1). Not restartable.
    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        if transportOpen, let transport {
            transport.send(YProtocol.encodeAwareness(awareness.setLocal(nil)))
        }
        connectTask?.cancel()
        connectTask = nil
        tickTask?.cancel()
        tickTask = nil
        transport?.close()
        transport = nil
        transportOpen = false
        changeHandler = nil
        phase = .closed
        reconnectStatus = nil
        peers = []
    }

    public var isDestroyed: Bool { destroyed }

    // MARK: - CollaborativeDocument

    public var text: String {
        _ = revision
        if let textCache { return textCache }
        let t = crdt.text
        textCache = t
        return t
    }

    public var isEditable: Bool {
        hasSynced && !destroyed && termination != .forbidden && termination != .notFound
    }

    public func applyLocal(_ edits: [TextEdit]) {
        guard isEditable else { return }
        let result = crdt.applyLocal(edits)
        if !result.applied {
            changed()
            changeHandler?(.resync(crdt.text))
        }
        guard !result.update.isEmpty else { return }
        changed()
        if !(transportOpen && phase == .live) { hasPendingLocalChanges = true }
        sendSyncUpdate(result.update)
    }

    @discardableResult
    public func undo() -> Bool {
        guard isEditable, let change = crdt.undo() else { return false }
        deliverUndo(change)
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard isEditable, let change = crdt.redo() else { return false }
        deliverUndo(change)
        return true
    }

    public func breakUndoGroup() {
        crdt.breakUndoGroup()
    }

    private func deliverUndo(_ change: ReplicaChange) {
        if !change.edits.isEmpty {
            changed()
            changeHandler?(.undo(change.edits))
        }
        if !change.update.isEmpty { sendSyncUpdate(change.update) }
    }

    // MARK: - Explicit actions

    /// Legacy uninitialised note (§2.2.5): "Load file contents". Only
    /// when live and the replica is empty.
    @discardableResult
    public func initialiseFromFile(_ body: String) -> Bool {
        guard hasSynced, phase == .live, crdt.length == 0,
              let update = crdt.initialiseFromFile(body)
        else { return false }
        emptyAtSync = false
        changed()
        changeHandler?(.remote([TextEdit(location: 0, length: 0, replacement: body)]))
        sendSyncUpdate(update)
        return true
    }

    /// Pull-to-refresh (§5): merge the REST snapshot's full `state` into
    /// the kept replica. Never replaces the doc (V8).
    public func mergeSnapshotState(_ state: Data) {
        guard !destroyed, hasSynced, !state.isEmpty else { return }
        applyRemoteUpdate(state)
    }

    // MARK: - Connection

    private func connect() async {
        let transport: any SyncTransport
        do {
            transport = try await connector.connect(vaultID: vaultID, noteID: noteID)
        } catch {
            guard !destroyed, !Task.isCancelled else { return }
            connectTask = nil
            switch error {
            case .unauthorized: terminate(.unauthorized)
            case .forbidden: terminate(.forbidden)
            case .notConfigured: terminate(.notConfigured)
            case .transient: await handleDrop(code: nil, opened: false)
            }
            return
        }
        guard !destroyed, !Task.isCancelled else {
            transport.close()
            return
        }
        self.transport = transport
        var opened = false
        var closeCode: Int?
        for await event in transport.events {
            guard !destroyed, self.transport === transport else { break }
            switch event {
            case .opened:
                opened = true
                didOpen(transport)
            case .message(let frame):
                if !opened {
                    opened = true
                    didOpen(transport)
                }
                handleFrame(frame, from: transport)
            case .closed(let code, _):
                closeCode = code
            }
        }
        guard !destroyed, self.transport === transport else { return }
        self.transport = nil
        transportOpen = false
        connectTask = nil
        await handleDrop(code: closeCode, opened: opened)
    }

    private func didOpen(_ transport: any SyncTransport) {
        transportOpen = true
        failedOpens = 0
        attempt = 0
        reconnectStatus = nil
        connectionNotice = nil
        if !hasSynced { phase = .syncing }
        // y-websocket handshake: Step1(local sv), local awareness, query.
        transport.send(YProtocol.encodeSyncStep1(stateVector: crdt.stateVector()))
        if awareness.localJSON != nil {
            transport.send(YProtocol.encodeAwareness(awareness.localUpdate()))
        }
        transport.send(YProtocol.encodeQueryAwareness())
    }

    private func handleDrop(code: Int?, opened: Bool) async {
        guard !destroyed else { return }
        awareness.clearRemotes()
        peers = []
        switch code {
        case 4401: terminate(.unauthorized); return
        case 4403: terminate(.forbidden); return
        case 4404: terminate(.notFound); return
        case 1008: terminate(.policy); return
        default: break
        }
        phase = hasSynced ? .offline : .connecting
        if !opened {
            failedOpens += 1
            if failedOpens >= probeAfterFailures {
                failedOpens = 0
                switch await connector.probeAuth() {
                case .unauthorized:
                    terminate(.unauthorized)
                    return
                case .ok:
                    connectionNotice = "cannot reach live editing — retrying"
                case .unknown:
                    break
                }
                guard !destroyed else { return }
            }
        }
        attempt += 1
        let delay = backoff(attempt)
        reconnectStatus = ReconnectStatus(attempt: attempt, delaySeconds: delay, scheduledAt: Date())
        connectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.destroyed else { return }
            await self.connect()
        }
    }

    private func terminate(_ reason: SessionTermination) {
        termination = reason
        transport?.close()
        transport = nil
        transportOpen = false
        connectTask = nil
        reconnectStatus = nil
        phase = hasSynced && reason != .notFound ? .offline : .closed
        if reason == .unauthorized { onUnauthorized?() }
    }

    // MARK: - Frames

    private func handleFrame(_ frame: Data, from transport: any SyncTransport) {
        guard let msg = try? YProtocol.decode(frame) else { return }
        switch msg.type {
        case YProtocol.messageSync:
            switch msg.syncSub {
            case YProtocol.syncStep1:
                // Server asks what we have that it lacks — including
                // every offline edit (V11). Empty doc → `[0,0]`.
                if let diff = try? crdt.encodeDiff(againstStateVector: msg.body) {
                    transport.send(YProtocol.encodeSyncStep2(update: diff))
                }
            case YProtocol.syncStep2:
                applyRemoteUpdate(msg.body)
                if !hasSynced {
                    hasSynced = true
                    emptyAtSync = crdt.length == 0
                }
                hasPendingLocalChanges = false
                phase = .live
            case YProtocol.syncUpdate:
                applyRemoteUpdate(msg.body)
            default:
                break
            }
        case YProtocol.messageAwareness:
            let (changed, reply) = awareness.apply(msg.body)
            if let reply { transport.send(YProtocol.encodeAwareness(reply)) }
            if changed { peers = awareness.peers }
        case YProtocol.messageQueryAwareness:
            transport.send(YProtocol.encodeAwareness(awareness.fullUpdate()))
        case YProtocol.messageAuth:
            if msg.syncSub == YProtocol.authPermissionDenied { terminate(.forbidden) }
        default:
            break
        }
    }

    private func applyRemoteUpdate(_ update: Data) {
        guard let edits = try? crdt.applyRemote(update: update), !edits.isEmpty else { return }
        changed()
        changeHandler?(.remote(edits))
    }

    private func sendSyncUpdate(_ update: Data) {
        guard transportOpen, let transport else { return }
        transport.send(YProtocol.encodeSyncUpdate(update: update))
    }

    private func changed() {
        textCache = nil
        revision &+= 1
    }

    // MARK: - Awareness ticking

    private func startTicking() {
        guard tickTask == nil else { return }
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !self.destroyed else { return }
                self.tick(now: Date())
            }
        }
    }

    /// Renew our awareness state and expire silent peers. Internal for
    /// tests.
    func tick(now: Date) {
        let (renewal, changed) = awareness.tick(now: now)
        if let renewal, transportOpen, let transport {
            transport.send(YProtocol.encodeAwareness(renewal))
        }
        if changed { peers = awareness.peers }
    }

    /// The awareness clientID this session announces (tests / debugging).
    public var awarenessClientID: UInt64 { awareness.clientID }
}

#endif
