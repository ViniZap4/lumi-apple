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
///
/// **Offline replica** (§5 "if it persisted its doc locally… it MAY
/// restore that doc"; §11 Apple): with a `ReplicaBinding` the doc is
/// persisted after the first SyncStep2 and restored on the next open,
/// which starts editable in `offline` before any network. On connect the
/// session runs the lineage guard (`ReplicaLineage`) before sending
/// anything: the server's `crdt_epoch` (note lookup before dialing, then
/// the ws-ticket of each connection) decides when both sides know one;
/// otherwise `created_at` + the server SyncStep1's state-vector dominance.
/// A replica from another lineage is never merged (`.lineageChanged` +
/// `ReplicaConflict`, socket closed with client-side 4409). The epoch is
/// also checked on every reconnect of a live session, so an in-memory
/// doc is never merged into a note recreated while we were offline.
///
/// **Pending** (`hasPendingLocalChanges`): set by every local update,
/// persisted with the replica, cleared by an acknowledged round-trip —
/// after sending updates the session sends a SyncStep1 *probe*; the
/// server handles frames in order and persists each update before
/// reading the next frame, so the probe's SyncStep2 reply proves every
/// update sent before it reached the server.
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
    /// Local edits the server has not acknowledged yet (SPEC-LIVROS
    /// "Pendente"). Survives relaunch through the replica. §5: the doc is
    /// the queue — this is only the flag.
    public private(set) var hasPendingLocalChanges = false
    /// The session started from a persisted replica (editable offline
    /// before any server contact).
    public private(set) var restoredFromReplica = false
    /// Set when the persisted replica could not be merged (lineage
    /// changed, note deleted while edits were pending).
    public private(set) var replicaConflict: ReplicaConflict?
    /// Bumped on every text change (local or remote). Read-only views
    /// observe this through `text`.
    public private(set) var revision = 0
    /// Last transport-level problem worth surfacing ("cannot reach live
    /// editing"), nil when healthy.
    public private(set) var connectionNotice: String?

    @ObservationIgnored public var changeHandler: ((DocumentChange) -> Void)?
    /// Called once when the session concludes the token is dead.
    @ObservationIgnored public var onUnauthorized: (() -> Void)?
    /// Called once when the replica could not be merged. The host saves
    /// the text as a recoverable copy and, for `.lineageChanged`,
    /// replaces this session with a fresh one.
    @ObservationIgnored public var onReplicaConflict: ((ReplicaConflict) -> Void)?

    @ObservationIgnored private let crdt: LumiCRDT
    @ObservationIgnored public let replica: ReplicaBinding?
    /// False while a restored replica's lineage is unproven.
    @ObservationIgnored private var lineageVerified = true
    @ObservationIgnored private var stampChecked = false
    @ObservationIgnored private var knownServerSV = StateVector()
    @ObservationIgnored private var noteCreatedAt: Date?
    /// Server lineage (`crdt_epoch`) this replica belongs to; nil until
    /// learnt (pre-epoch server / replica persisted before the upgrade).
    @ObservationIgnored public private(set) var crdtEpoch: String?
    /// Epoch of the current connection's ticket, adopted once the
    /// lineage is verified.
    @ObservationIgnored private var pendingEpoch: String?
    /// The current/last connection authenticated with a ws-ticket.
    @ObservationIgnored private var lastUsedTicket = false
    /// One re-mint after a 4401 on a ticket connection (stale ticket).
    @ObservationIgnored private var ticketRetried = false
    @ObservationIgnored private var localSeq = 0
    @ObservationIgnored private var ackedSeq = 0
    /// Outstanding SyncStep1 probes on the current socket, in send order.
    @ObservationIgnored private var probes: [(seq: Int, sv: StateVector)] = []
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// Debounce between a local edit and its acknowledgement probe.
    @ObservationIgnored public var probeDelay: Double = 0.3
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
        awarenessClientID: UInt64 = AwarenessState.randomClientID(),
        replica: ReplicaBinding? = nil
    ) {
        self.vaultID = vaultID
        self.noteID = noteID
        self.connector = connector
        self.crdt = LumiCRDT()
        self.replica = replica
        self.awareness = AwarenessState(clientID: awarenessClientID)
        if let user {
            _ = awareness.setLocal(user.stateJSON())
        }
        if let replica {
            let crdt = self.crdt
            replica.stateProvider = { crdt.encodeStateAsUpdate() }
            if let stored = replica.restored { restore(stored) }
        }
    }

    /// Load a persisted replica into the (fresh) doc. It originated from
    /// the server, so it is a valid replica: editable at once, offline.
    private func restore(_ stored: StoredReplica) {
        do {
            for u in stored.updates { try crdt.applyRemote(update: u) }
        } catch {
            replica?.discard()
            return
        }
        hasSynced = true
        restoredFromReplica = true
        lineageVerified = false
        knownServerSV = (try? StateVector(decoding: stored.meta.knownServerSV)) ?? StateVector()
        noteCreatedAt = stored.meta.noteCreatedAt
        crdtEpoch = ReplicaLineage.normalized(stored.meta.crdtEpoch)
        hasPendingLocalChanges = stored.meta.dirty
        // A pending flag from disk counts as one unacknowledged edit.
        localSeq = stored.meta.dirty ? 1 : 0
        phase = .offline
    }

    // MARK: - Lifecycle

    /// Start connecting. Idempotent.
    public func start() {
        guard !destroyed, connectTask == nil, transport == nil, termination == nil else { return }
        phase = hasSynced ? .offline : .connecting
        // Compact once on open: restored replicas get a fresh LRU stamp.
        if restoredFromReplica { replica?.checkpoint() }
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
        probeTask?.cancel()
        probeTask = nil
        if replicaConflict == nil { replica?.close() }
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
            && termination != .lineageChanged
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
        noteLocalUpdate(result.update)
    }

    /// Bookkeeping for every update this replica authored.
    private func noteLocalUpdate(_ update: Data) {
        localSeq += 1
        hasPendingLocalChanges = true
        replica?.recordLocal(update)
        persistState()
        sendSyncUpdate(update)
        scheduleProbe()
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
        if !change.update.isEmpty { noteLocalUpdate(change.update) }
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
        noteLocalUpdate(update)
        return true
    }

    /// Pull-to-refresh (§5): merge the REST snapshot's full `state` into
    /// the kept replica. Never replaces the doc (V8).
    public func mergeSnapshotState(_ state: Data, crdtEpoch serverEpoch: String? = nil) {
        // A restored replica merges nothing until the lineage guard
        // passed on the socket: the REST state may be another lineage.
        guard !destroyed, hasSynced, lineageVerified, !state.isEmpty else { return }
        // A snapshot of another lineage is never merged (the socket's
        // epoch check reports the conflict).
        guard ReplicaLineage.compareEpoch(replica: crdtEpoch, server: serverEpoch) != .changed else { return }
        applyRemoteUpdate(state)
    }

    // MARK: - Connection

    private func connect() async {
        // Lineage stamp before any frame of a persisted replica is sent.
        if replica != nil, !stampChecked {
            switch await connector.noteLineage(vaultID: vaultID, noteID: noteID) {
            case .note(let stamp, let epoch):
                guard !destroyed, !Task.isCancelled else { return }
                var mismatch = false
                switch ReplicaLineage.compareEpoch(replica: crdtEpoch, server: epoch) {
                case .changed:
                    mismatch = true
                case .same:
                    // Epoch decides alone: no state-vector check needed.
                    lineageVerified = true
                case .unknown:
                    if !lineageVerified, let mine = noteCreatedAt, let stamp,
                       !ReplicaLineage.sameStamp(mine, stamp) {
                        mismatch = true
                    }
                }
                if mismatch {
                    connectTask = nil
                    replicaMismatch(.lineageChanged)
                    return
                }
                if let stamp { noteCreatedAt = stamp }
                stampChecked = true
                persistState()
            case .notFound:
                guard !destroyed, !Task.isCancelled else { return }
                connectTask = nil
                noteGone()
                return
            case .unauthorized:
                guard !destroyed, !Task.isCancelled else { return }
                connectTask = nil
                terminate(.unauthorized)
                return
            case .forbidden:
                guard !destroyed, !Task.isCancelled else { return }
                connectTask = nil
                terminate(.forbidden)
                return
            case .unavailable:
                guard !destroyed, !Task.isCancelled else { return }
                connectTask = nil
                await handleDrop(code: nil, opened: false)
                return
            case .unsupported:
                stampChecked = true
            }
        }
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
        lastUsedTicket = transport.usedTicket
        // The ticket names the lineage of the doc this socket joins.
        let ticketEpoch = ReplicaLineage.normalized(transport.crdtEpoch)
        switch ReplicaLineage.compareEpoch(replica: crdtEpoch, server: ticketEpoch) {
        case .changed:
            connectTask = nil
            transport.close(code: ReplicaLineage.closeLineageChanged, reason: "lineage changed")
            replicaMismatch(.lineageChanged)
            return
        case .same:
            lineageVerified = true
        case .unknown:
            break
        }
        pendingEpoch = ticketEpoch
        if lineageVerified { adoptPendingEpoch() }
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
        probes.removeAll()
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
        // Our Step1 waits for the server's (always the first frame on
        // join): a restored replica must pass the lineage guard before
        // the server learns anything about it. Awareness is ephemeral and
        // carries no document state.
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
        case 4401:
            // A ticket connection may just have presented a stale ticket
            // (lineage changed between mint and redeem): re-mint once. A
            // dead session then fails at the ticket endpoint (401).
            if lastUsedTicket && !ticketRetried {
                ticketRetried = true
            } else {
                terminate(.unauthorized)
                return
            }
        case 4403: terminate(.forbidden); return
        case 4404: noteGone(); return
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

    /// 4404 / lineage probe 404: the note is gone. Pending edits become a
    /// recoverable copy; the replica is dropped either way.
    private func noteGone() {
        // Drop the files before telling the host, which may open a new
        // session for the same key right away.
        replica?.discard()
        if hasPendingLocalChanges { reportConflict(.noteDeleted) }
        terminate(.notFound)
    }

    /// The persisted replica belongs to another lineage: never merge.
    private func replicaMismatch(_ reason: ReplicaConflict.Reason) {
        transport?.close(code: ReplicaLineage.closeLineageChanged, reason: "lineage changed")
        transport = nil
        transportOpen = false
        probes.removeAll()
        replica?.discard()
        terminate(.lineageChanged)
        reportConflict(reason)
    }

    private func reportConflict(_ reason: ReplicaConflict.Reason) {
        guard replicaConflict == nil else { return }
        let conflict = ReplicaConflict(
            reason: reason, vaultID: vaultID, noteID: noteID, text: crdt.text,
            hadPendingChanges: hasPendingLocalChanges,
            title: replica?.meta.title, path: replica?.meta.path)
        replicaConflict = conflict
        onReplicaConflict?(conflict)
    }

    private func terminate(_ reason: SessionTermination) {
        termination = reason
        transport?.close()
        transport = nil
        transportOpen = false
        connectTask = nil
        reconnectStatus = nil
        phase = hasSynced && reason != .notFound && reason != .lineageChanged ? .offline : .closed
        if reason == .unauthorized { onUnauthorized?() }
    }

    // MARK: - Frames

    private func handleFrame(_ frame: Data, from transport: any SyncTransport) {
        guard let msg = try? YProtocol.decode(frame) else { return }
        switch msg.type {
        case YProtocol.messageSync:
            switch msg.syncSub {
            case YProtocol.syncStep1:
                let serverSV = try? StateVector(decoding: msg.body)
                ticketRetried = false
                if !lineageVerified {
                    guard let serverSV else {
                        transport.close() // malformed: retry the join
                        return
                    }
                    guard ReplicaLineage.sameLineage(serverSV: serverSV, acknowledged: knownServerSV) else {
                        replicaMismatch(.lineageChanged)
                        return
                    }
                    lineageVerified = true
                    adoptPendingEpoch()
                }
                if let serverSV {
                    knownServerSV = knownServerSV.merged(with: serverSV)
                    persistState()
                }
                // Server asks what we have that it lacks — including
                // every offline edit (V11). Empty doc → `[0,0]`.
                if let diff = try? crdt.encodeDiff(againstStateVector: msg.body) {
                    transport.send(YProtocol.encodeSyncStep2(update: diff))
                }
                // Then our Step1: the server's Step2 reply both fills us
                // in and acknowledges the Step2 we just sent.
                sendProbe()
            case YProtocol.syncStep2:
                guard lineageVerified else { return }
                applyRemoteUpdate(msg.body)
                acknowledgeProbe()
                if !hasSynced {
                    hasSynced = true
                    emptyAtSync = crdt.length == 0
                    // First sync: the replica now originates from the
                    // server and may be persisted.
                    replica?.checkpoint()
                }
                phase = .live
            case YProtocol.syncUpdate:
                guard lineageVerified else { return }
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
        guard let edits = try? crdt.applyRemote(update: update) else { return }
        if hasSynced { replica?.recordRemote(update) }
        guard !edits.isEmpty else { return }
        changed()
        changeHandler?(.remote(edits))
    }

    // MARK: - Acknowledgement probes

    private func scheduleProbe() {
        guard transportOpen, lineageVerified, probeTask == nil else { return }
        let delay = probeDelay
        probeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.probeTask = nil
            self.sendProbe()
        }
    }

    /// SyncStep1 whose Step2 reply acknowledges everything sent before it.
    private func sendProbe() {
        guard transportOpen, let transport, lineageVerified else { return }
        let sv = crdt.stateVector()
        probes.append((localSeq, (try? StateVector(decoding: sv)) ?? StateVector()))
        transport.send(YProtocol.encodeSyncStep1(stateVector: sv))
    }

    private func acknowledgeProbe() {
        guard !probes.isEmpty else { return }
        let probe = probes.removeFirst()
        ackedSeq = max(ackedSeq, probe.seq)
        knownServerSV = knownServerSV.merged(with: probe.sv)
        hasPendingLocalChanges = localSeq > ackedSeq
        persistState()
    }

    /// Record the current connection's epoch once the lineage is proven
    /// (fresh sessions at once; restored pre-epoch replicas after the
    /// fallback check), so later checks are exact.
    private func adoptPendingEpoch() {
        guard crdtEpoch == nil, let e = pendingEpoch else { return }
        crdtEpoch = e
        persistState()
    }

    private func persistState() {
        replica?.recordState(dirty: hasPendingLocalChanges, knownServerSV: knownServerSV.encoded(),
                             noteCreatedAt: noteCreatedAt, crdtEpoch: crdtEpoch)
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
