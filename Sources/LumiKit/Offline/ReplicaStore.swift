import Foundation
import CryptoKit
import Synchronization

/// Identity of one persisted note replica: `(server_url, account,
/// vault_id, note_id)`. Two accounts on the same server never share a
/// replica, and neither do two vaults (a re-created vault has a new id).
public struct ReplicaKey: Sendable, Hashable, Codable, CustomStringConvertible {
    public let serverURL: String
    public let username: String
    public let vaultID: UUID
    public let noteID: String

    public init(account: AccountKey, vaultID: UUID, noteID: String) {
        self.serverURL = account.serverURL
        self.username = account.username
        self.vaultID = vaultID
        self.noteID = noteID
    }

    public var account: AccountKey { AccountKey(serverURL: serverURL, username: username) }

    public var description: String { "\(account)/\(vaultID.uuidString.lowercased())/\(noteID)" }
}

/// Persisted facts about a replica, next to its Yjs state.
public struct ReplicaMeta: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var serverURL: String
    public var username: String
    public var vaultID: UUID
    public var noteID: String
    /// Last known title / path, for the conflict copy and the recovery list.
    public var title: String?
    public var path: String?
    /// Lineage stamp: the server's `notes.created_at` for this id when the
    /// replica was first synced. A delete + recreate gets a new one.
    public var noteCreatedAt: Date?
    /// Server CRDT lineage (`crdt_epoch`) this replica was synced under;
    /// nil for replicas persisted before the server exposed it.
    public var crdtEpoch: String?
    /// lib0-v1 state vector the server provably holds (its SyncStep1 at
    /// join, plus every state acknowledged by a probe round-trip). Inside
    /// one lineage the server's vector only grows (`ReplicaLineage`).
    public var knownServerSV: Data
    /// Local edits not yet acknowledged by the server ("Pendente").
    public var dirty: Bool
    /// LRU clock.
    public var lastAccess: Date

    public init(key: ReplicaKey, title: String? = nil, path: String? = nil, noteCreatedAt: Date? = nil,
                crdtEpoch: String? = nil,
                knownServerSV: Data = Data(), dirty: Bool = false, lastAccess: Date = Date()) {
        self.version = Self.currentVersion
        self.serverURL = key.serverURL
        self.username = key.username
        self.vaultID = key.vaultID
        self.noteID = key.noteID
        self.title = title
        self.path = path
        self.noteCreatedAt = noteCreatedAt
        self.crdtEpoch = crdtEpoch
        self.knownServerSV = knownServerSV
        self.dirty = dirty
        self.lastAccess = lastAccess
    }

    public var key: ReplicaKey {
        ReplicaKey(account: AccountKey(serverURL: serverURL, username: username), vaultID: vaultID, noteID: noteID)
    }
}

/// One incremental record of the replica log (`<note>.log`).
public enum ReplicaLogRecord: Sendable, Equatable {
    /// A local (editor / undo / init) update — marks the replica dirty.
    case local(Data)
    /// An update received from the server.
    case remote(Data)
    /// Pending flag / acknowledged server vector / lineage stamp changed.
    case state(ReplicaState)

    var kind: UInt8 {
        switch self {
        case .local: return 1
        case .remote: return 2
        case .state: return 3
        }
    }
}

/// The mutable part of `ReplicaMeta` that changes between compactions.
public struct ReplicaState: Codable, Sendable, Equatable {
    public var dirty: Bool
    public var knownServerSV: Data
    public var noteCreatedAt: Date?
    /// Optional for logs written before the field existed.
    public var crdtEpoch: String?

    public init(dirty: Bool, knownServerSV: Data, noteCreatedAt: Date?, crdtEpoch: String? = nil) {
        self.dirty = dirty
        self.knownServerSV = knownServerSV
        self.noteCreatedAt = noteCreatedAt
        self.crdtEpoch = crdtEpoch
    }
}

/// A replica read back from disk: the compacted state first, then the
/// log's updates in order. Applying them all (CRDT merges are idempotent
/// and commutative) rebuilds the doc.
public struct StoredReplica: Sendable {
    public var meta: ReplicaMeta
    public var updates: [Data]
    public var byteSize: Int
}

/// Directory-scan result used for eviction and the pending list.
public struct ReplicaSummary: Sendable, Equatable {
    public var key: ReplicaKey
    public var meta: ReplicaMeta
    public var byteSize: Int
}

/// Text salvaged from a replica that could not be merged: lineage changed,
/// note deleted on the server, or access/account gone while edits were
/// pending. Never a CRDT state — just text, which the user can upload as a
/// new note ("<title> (conflito offline)") or export.
public struct RecoveredNote: Codable, Sendable, Identifiable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case lineageChanged = "lineage_changed"
        case noteDeleted = "note_deleted"
        case accessRevoked = "access_revoked"
        case sessionEnded = "session_ended"
        case accountRemoved = "account_removed"
    }

    public var id: UUID
    public var serverURL: String
    public var username: String
    public var vaultID: UUID
    public var noteID: String
    public var title: String
    public var path: String?
    public var text: String
    public var reason: Reason
    public var createdAt: Date
    /// True when the copy can still be uploaded to the same book (lineage
    /// changed / note deleted); false when access is gone (export only).
    public var uploadable: Bool

    public init(id: UUID = UUID(), key: ReplicaKey, title: String?, path: String?, text: String,
                reason: Reason, createdAt: Date = Date(), uploadable: Bool) {
        self.id = id
        self.serverURL = key.serverURL
        self.username = key.username
        self.vaultID = key.vaultID
        self.noteID = key.noteID
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = t.isEmpty ? key.noteID : t
        self.path = path
        self.text = text
        self.reason = reason
        self.createdAt = createdAt
        self.uploadable = uploadable
    }

    public var account: AccountKey { AccountKey(serverURL: serverURL, username: username) }

    /// Title of the note the copy is uploaded as.
    public var conflictTitle: String { "\(title) (conflito offline)" }
}

/// Last-known note list of a book, for the explorer while offline.
public struct BookListingCache: Codable, Sendable, Equatable {
    public var notes: [RemoteNote]
    /// The signed-in member's capabilities in the vault (only our own row
    /// is kept — other members' data stays on the server).
    public var capabilities: [String]?
    public var fetchedAt: Date

    public init(notes: [RemoteNote], capabilities: [String]?, fetchedAt: Date = Date()) {
        self.notes = notes
        self.capabilities = capabilities
        self.fetchedAt = fetchedAt
    }
}

/// On-disk store of per-note Yjs replicas (offline editing of server
/// books), the book listing caches and the recovered-text records.
///
/// Layout under `root` (default `Application Support/lumi/replicas`):
///
///     a-<sha256(server#account)[0..32]>/
///         <vault-uuid>/
///             <sha256(note_id)[0..40]>.replica   header + compacted state
///             <sha256(note_id)[0..40]>.log       incremental records
///             listing.json                        BookListingCache
///     recovered/<uuid>.json                       RecoveredNote
///
/// `.replica` = `"LRP1"` · u32be(metaLen) · meta JSON · lib0-v1 update
/// (`encodeStateAsUpdate`). `.log` = repeated `u8 kind · u32be len ·
/// payload` (1 local update, 2 remote update, 3 `ReplicaState` JSON); a
/// torn tail record is ignored, so appends need no fsync dance. Writes of
/// whole files are atomic. iOS: files are protected
/// `completeUntilFirstUserAuthentication`; the root is excluded from
/// backups (both platforms).
///
/// Synchronous I/O behind one lock: replicas are small (tens of KB) and
/// writes are debounced by `ReplicaBinding`.
public final class ReplicaStore: Sendable {
    public let root: URL
    /// Soft cap for the sum of all replicas; LRU eviction skips dirty ones.
    public let maxBytes: Int
    private let lock = Mutex(false) // value = root prepared

    static let magic = Data("LRP1".utf8)

    public init(root: URL, maxBytes: Int = 256 << 20) {
        self.root = root
        self.maxBytes = maxBytes
    }

    /// `Application Support/lumi/replicas`.
    public static func defaultRoot() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("lumi", isDirectory: true)
            .appendingPathComponent("replicas", isDirectory: true)
    }

    public static let shared = ReplicaStore(root: defaultRoot())

    // MARK: Paths

    static func hex(_ s: String, _ n: Int) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(n).description
    }

    func accountDir(_ account: AccountKey) -> URL {
        root.appendingPathComponent("a-" + Self.hex(account.keychainAccount, 32), isDirectory: true)
    }

    func vaultDir(_ account: AccountKey, _ vaultID: UUID) -> URL {
        accountDir(account).appendingPathComponent(vaultID.uuidString.lowercased(), isDirectory: true)
    }

    func replicaURL(_ key: ReplicaKey) -> URL {
        vaultDir(key.account, key.vaultID).appendingPathComponent(Self.hex(key.noteID, 40) + ".replica")
    }

    func logURL(_ key: ReplicaKey) -> URL {
        vaultDir(key.account, key.vaultID).appendingPathComponent(Self.hex(key.noteID, 40) + ".log")
    }

    var recoveredDir: URL { root.appendingPathComponent("recovered", isDirectory: true) }

    // MARK: Replicas

    /// Write the compacted replica atomically and drop the log it absorbed.
    public func save(_ meta: ReplicaMeta, state: Data) throws {
        try locked {
            let key = meta.key
            try ensureDir(vaultDir(key.account, key.vaultID))
            let metaJSON = try Self.encoder.encode(meta)
            var out = Self.magic
            out.append(Self.u32(UInt32(metaJSON.count)))
            out.append(metaJSON)
            out.append(state)
            try writeAtomically(out, to: replicaURL(key))
            try? FileManager.default.removeItem(at: logURL(key))
        }
    }

    /// Append log records. Returns the log's size afterwards. No-op when
    /// the replica itself does not exist (nothing to append to).
    @discardableResult
    public func append(_ key: ReplicaKey, _ records: [ReplicaLogRecord]) throws -> Int {
        try locked {
            guard !records.isEmpty else { return logSize(key) }
            let fm = FileManager.default
            guard fm.fileExists(atPath: replicaURL(key).path) else { return 0 }
            var blob = Data()
            for r in records {
                let payload: Data
                switch r {
                case .local(let d), .remote(let d): payload = d
                case .state(let s): payload = try Self.encoder.encode(s)
                }
                blob.append(r.kind)
                blob.append(Self.u32(UInt32(payload.count)))
                blob.append(payload)
            }
            let url = logURL(key)
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: blob, attributes: Self.fileAttributes) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            } else {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: blob)
            }
            return logSize(key)
        }
    }

    /// Read a replica back. nil when absent or unreadable (a corrupt
    /// replica is deleted: it is a cache of server state, never the only
    /// copy of anything except pending edits, which a corrupt file has
    /// lost already).
    public func load(_ key: ReplicaKey) -> StoredReplica? {
        locked { loadLocked(key) }
    }

    public func exists(_ key: ReplicaKey) -> Bool {
        locked { FileManager.default.fileExists(atPath: replicaURL(key).path) }
    }

    public func delete(_ key: ReplicaKey) {
        locked {
            try? FileManager.default.removeItem(at: replicaURL(key))
            try? FileManager.default.removeItem(at: logURL(key))
        }
    }

    /// Every replica on disk (header + log scanned, state not decoded).
    public func summaries() -> [ReplicaSummary] {
        locked { summariesLocked() }
    }

    /// Replicas with unsent local edits, optionally narrowed.
    public func pending(account: AccountKey? = nil, vaultID: UUID? = nil) -> [ReplicaSummary] {
        summaries().filter {
            $0.meta.dirty
                && (account == nil || $0.key.account == account)
                && (vaultID == nil || $0.key.vaultID == vaultID)
        }
    }

    public var totalBytes: Int { summaries().reduce(0) { $0 + $1.byteSize } }

    /// LRU eviction down to `maxBytes`. Never evicts a dirty replica or
    /// one in `protecting` (open notes). Returns the evicted keys.
    @discardableResult
    public func evict(protecting: Set<ReplicaKey> = []) -> [ReplicaKey] {
        locked {
            var all = summariesLocked()
            var total = all.reduce(0) { $0 + $1.byteSize }
            guard total > maxBytes else { return [] }
            all.sort { $0.meta.lastAccess < $1.meta.lastAccess }
            var evicted: [ReplicaKey] = []
            for s in all where total > maxBytes {
                guard !s.meta.dirty, !protecting.contains(s.key) else { continue }
                try? FileManager.default.removeItem(at: replicaURL(s.key))
                try? FileManager.default.removeItem(at: logURL(s.key))
                total -= s.byteSize
                evicted.append(s.key)
            }
            return evicted
        }
    }

    /// LGPD wipe of an account (or one of its books). Pending replicas are
    /// first turned into `RecoveredNote`s (text only, `uploadable: false`)
    /// via `materialize` so the user can export them; everything else —
    /// replicas, logs, listing caches — is deleted. Returns the recovered
    /// records it created.
    @discardableResult
    public func purge(account: AccountKey, vaultID: UUID? = nil, reason: RecoveredNote.Reason,
                      materialize: ([Data]) -> String?) -> [RecoveredNote] {
        locked {
            var recovered: [RecoveredNote] = []
            for s in summariesLocked() where s.key.account == account && (vaultID == nil || s.key.vaultID == vaultID) {
                guard s.meta.dirty, let stored = loadLocked(s.key), let text = materialize(stored.updates) else { continue }
                let rec = RecoveredNote(key: s.key, title: s.meta.title, path: s.meta.path, text: text,
                                        reason: reason, uploadable: false)
                if (try? saveRecoveredLocked(rec)) != nil { recovered.append(rec) }
            }
            let dir = vaultID.map { vaultDir(account, $0) } ?? accountDir(account)
            try? FileManager.default.removeItem(at: dir)
            return recovered
        }
    }

    // MARK: Listing cache

    public func saveListing(_ listing: BookListingCache, account: AccountKey, vaultID: UUID) {
        locked {
            let dir = vaultDir(account, vaultID)
            guard (try? ensureDir(dir)) != nil, let data = try? Self.encoder.encode(listing) else { return }
            try? writeAtomically(data, to: dir.appendingPathComponent("listing.json"))
        }
    }

    public func loadListing(account: AccountKey, vaultID: UUID) -> BookListingCache? {
        locked {
            let url = vaultDir(account, vaultID).appendingPathComponent("listing.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decoder.decode(BookListingCache.self, from: data)
        }
    }

    // MARK: Recovered texts

    public func saveRecovered(_ note: RecoveredNote) throws {
        try locked { try saveRecoveredLocked(note) }
    }

    public func recovered(account: AccountKey? = nil, vaultID: UUID? = nil) -> [RecoveredNote] {
        locked {
            let urls = (try? FileManager.default.contentsOfDirectory(at: recoveredDir, includingPropertiesForKeys: nil)) ?? []
            return urls.filter { $0.pathExtension == "json" }
                .compactMap { try? Self.decoder.decode(RecoveredNote.self, from: Data(contentsOf: $0)) }
                .filter { (account == nil || $0.account == account) && (vaultID == nil || $0.vaultID == vaultID) }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func deleteRecovered(_ id: UUID) {
        locked {
            try? FileManager.default.removeItem(at: recoveredDir.appendingPathComponent(id.uuidString.lowercased() + ".json"))
        }
    }

    /// Write recovered texts as `.md` files into `directory` (created if
    /// needed) and return their URLs. Records are not deleted here.
    public static func export(_ notes: [RecoveredNote], to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for n in notes {
            let safe = n.conflictTitle.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }
            var url = directory.appendingPathComponent(String(safe) + ".md")
            var i = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = directory.appendingPathComponent("\(String(safe)) \(i).md")
                i += 1
            }
            try Data(n.text.utf8).write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    // MARK: Internals

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock { prepared in
            if !prepared {
                prepareRoot()
                prepared = true
            }
            return try body()
        }
    }

    private func prepareRoot() {
        try? ensureDir(root)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: Self.fileAttributes)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: Self.writeOptions)
    }

    private func saveRecoveredLocked(_ note: RecoveredNote) throws {
        try ensureDir(recoveredDir)
        try writeAtomically(try Self.encoder.encode(note),
                            to: recoveredDir.appendingPathComponent(note.id.uuidString.lowercased() + ".json"))
    }

    private func logSize(_ key: ReplicaKey) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: logURL(key).path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func loadLocked(_ key: ReplicaKey) -> StoredReplica? {
        guard let blob = try? Data(contentsOf: replicaURL(key)) else { return nil }
        guard let (meta, state) = Self.parseReplica(blob), meta.key == key else {
            try? FileManager.default.removeItem(at: replicaURL(key))
            try? FileManager.default.removeItem(at: logURL(key))
            return nil
        }
        var result = StoredReplica(meta: meta, updates: state.isEmpty ? [] : [state], byteSize: blob.count)
        if let log = try? Data(contentsOf: logURL(key)) {
            result.byteSize += log.count
            Self.replayLog(log, into: &result)
        }
        return result
    }

    private func summariesLocked() -> [ReplicaSummary] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [ReplicaSummary] = []
        for case let url as URL in walker where url.pathExtension == "replica" {
            guard let blob = try? Data(contentsOf: url), let (meta, _) = Self.parseReplica(blob) else { continue }
            var stored = StoredReplica(meta: meta, updates: [], byteSize: blob.count)
            if let log = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("log")) {
                stored.byteSize += log.count
                Self.replayLog(log, into: &stored, keepUpdates: false)
            }
            out.append(ReplicaSummary(key: meta.key, meta: stored.meta, byteSize: stored.byteSize))
        }
        return out
    }

    static func parseReplica(_ blob: Data) -> (ReplicaMeta, Data)? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 8, Data(bytes[0..<4]) == magic else { return nil }
        let len = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        guard 8 + len <= bytes.count,
              let meta = try? decoder.decode(ReplicaMeta.self, from: Data(bytes[8..<(8 + len)])),
              meta.version == ReplicaMeta.currentVersion
        else { return nil }
        return (meta, Data(bytes[(8 + len)...]))
    }

    static func replayLog(_ log: Data, into stored: inout StoredReplica, keepUpdates: Bool = true) {
        let bytes = [UInt8](log)
        var i = 0
        while i + 5 <= bytes.count {
            let kind = bytes[i]
            let len = Int(bytes[i + 1]) << 24 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 8 | Int(bytes[i + 4])
            let start = i + 5
            guard start + len <= bytes.count else { break } // torn tail
            let payload = Data(bytes[start..<(start + len)])
            switch kind {
            case 1:
                stored.meta.dirty = true
                if keepUpdates { stored.updates.append(payload) }
            case 2:
                if keepUpdates { stored.updates.append(payload) }
            case 3:
                if let s = try? decoder.decode(ReplicaState.self, from: payload) {
                    stored.meta.dirty = s.dirty
                    stored.meta.knownServerSV = s.knownServerSV
                    stored.meta.noteCreatedAt = s.noteCreatedAt ?? stored.meta.noteCreatedAt
                    stored.meta.crdtEpoch = s.crdtEpoch ?? stored.meta.crdtEpoch
                }
            default:
                break
            }
            i = start + len
        }
    }

    static func u32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    #if os(macOS)
    static let writeOptions: Data.WritingOptions = [.atomic]
    static var fileAttributes: [FileAttributeKey: Any]? { nil }
    #else
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    static var fileAttributes: [FileAttributeKey: Any]? { [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication] }
    #endif
}
