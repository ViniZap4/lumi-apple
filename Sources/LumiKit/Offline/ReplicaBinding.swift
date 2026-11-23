import Foundation

/// Persistence of one open note's replica (`NoteSyncSession`'s side of the
/// `ReplicaStore`). Incremental updates are buffered and appended to the
/// log after a short debounce; the log is compacted into a fresh snapshot
/// (`encodeStateAsUpdate`) when it grows, on the first sync and when the
/// session ends.
///
/// Rule (CRDT-CLIENT-PROTOCOL §5 / §11): nothing is persisted before the
/// first SyncStep2 of a fresh replica — a replica on disk always
/// originated from the server, so it is valid to restore and edit
/// offline, and is never rebuilt from text.
@MainActor
public final class ReplicaBinding {
    public let store: ReplicaStore
    public let key: ReplicaKey
    /// What was on disk when the binding was made (nil = fresh replica).
    public let restored: StoredReplica?
    public private(set) var meta: ReplicaMeta

    /// Debounce before buffered records hit the log.
    public var flushDelay: Double = 0.3
    /// Compact once the log passes this many bytes.
    public var compactThreshold = 256 << 10
    /// Supplies the full doc state for compaction (set by the session).
    public var stateProvider: (() -> Data)?

    private var buffer: [ReplicaLogRecord] = []
    private var flushTask: Task<Void, Never>?
    private var persisted: Bool
    private var closed = false

    public init(store: ReplicaStore, key: ReplicaKey, title: String? = nil, path: String? = nil) {
        self.store = store
        self.key = key
        let restored = store.load(key)
        self.restored = restored
        var meta = restored?.meta ?? ReplicaMeta(key: key)
        if let title, !title.isEmpty { meta.title = title }
        if let path, !path.isEmpty { meta.path = path }
        meta.lastAccess = Date()
        self.meta = meta
        self.persisted = restored != nil
    }

    /// True once a snapshot exists on disk.
    public var isPersisted: Bool { persisted }

    // MARK: Recording

    public func recordLocal(_ update: Data) {
        guard persisted, !update.isEmpty else { return }
        meta.dirty = true
        enqueue(.local(update))
    }

    public func recordRemote(_ update: Data) {
        guard persisted, !update.isEmpty else { return }
        enqueue(.remote(update))
    }

    public func recordState(dirty: Bool, knownServerSV: Data, noteCreatedAt: Date?, crdtEpoch: String? = nil) {
        let next = ReplicaState(dirty: dirty, knownServerSV: knownServerSV,
                                noteCreatedAt: noteCreatedAt ?? meta.noteCreatedAt,
                                crdtEpoch: crdtEpoch ?? meta.crdtEpoch)
        let cur = ReplicaState(dirty: meta.dirty, knownServerSV: meta.knownServerSV,
                               noteCreatedAt: meta.noteCreatedAt, crdtEpoch: meta.crdtEpoch)
        guard next != cur else { return }
        meta.dirty = next.dirty
        meta.knownServerSV = next.knownServerSV
        meta.noteCreatedAt = next.noteCreatedAt
        meta.crdtEpoch = next.crdtEpoch
        guard persisted else { return }
        enqueue(.state(next))
    }

    // MARK: Writing

    /// Write a compacted snapshot now (first sync, close, big log).
    public func checkpoint() {
        guard !closed, let state = stateProvider?() else { return }
        flushTask?.cancel()
        flushTask = nil
        buffer.removeAll()
        meta.lastAccess = Date()
        do {
            try store.save(meta, state: state)
            persisted = true
        } catch {
            // Disk full / protected data unavailable: keep running in
            // memory; the next checkpoint retries.
        }
    }

    /// Append buffered records; compact when the log grew too big.
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard persisted, !buffer.isEmpty else { return }
        let records = buffer
        buffer.removeAll()
        do {
            let size = try store.append(key, records)
            if size > compactThreshold { checkpoint() }
        } catch {
            checkpoint()
        }
    }

    /// Final flush + compaction; the binding is inert afterwards.
    public func close() {
        guard !closed else { return }
        if persisted { checkpoint() }
        closed = true
    }

    /// Drop the replica from disk (lineage changed, note deleted, purge).
    public func discard() {
        flushTask?.cancel()
        flushTask = nil
        buffer.removeAll()
        store.delete(key)
        persisted = false
        closed = true
    }

    private func enqueue(_ r: ReplicaLogRecord) {
        guard !closed else { return }
        buffer.append(r)
        guard flushTask == nil else { return }
        let delay = flushDelay
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flush()
        }
    }
}
