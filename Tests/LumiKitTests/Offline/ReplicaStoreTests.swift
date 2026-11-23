import Testing
import Foundation
@testable import LumiKit

func tempReplicaRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("lumi-replicas-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

let accountA = AccountKey(serverURL: "https://lumi.example.com", username: "ana")
let accountB = AccountKey(serverURL: "https://lumi.example.com", username: "bia")

@Suite("ReplicaStore — format, log replay, eviction, purge")
struct ReplicaStoreTests {
    let vault = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    @Test("state vector codec round-trips and dominance is component-wise")
    func stateVector() throws {
        let sv = StateVector([7: 3, 1 << 40: 12])
        let decoded = try StateVector(decoding: sv.encoded())
        #expect(decoded == sv)
        #expect(try StateVector(decoding: Data([0])).isEmpty)
        #expect(decoded.dominates(StateVector([7: 2])))
        #expect(!decoded.dominates(StateVector([7: 4])))
        #expect(!decoded.dominates(StateVector([99: 1])))
        #expect(decoded.dominates(StateVector()))
        #expect(StateVector([1: 2]).merged(with: StateVector([1: 5, 2: 1])) == StateVector([1: 5, 2: 1]))
    }

    @Test("snapshot + log replay: updates in order, dirty from local records, state records win")
    func roundTrip() throws {
        let store = ReplicaStore(root: tempReplicaRoot())
        let key = ReplicaKey(account: accountA, vaultID: vault, noteID: "plan")
        #expect(store.load(key) == nil)
        // Appending before a snapshot exists is a no-op.
        #expect(try store.append(key, [.local(Data([9]))]) == 0)

        var meta = ReplicaMeta(key: key, title: "Plan", noteCreatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        meta.knownServerSV = StateVector([5: 11]).encoded()
        try store.save(meta, state: Data([1, 2, 3]))
        var loaded = try #require(store.load(key))
        #expect(loaded.updates == [Data([1, 2, 3])])
        #expect(!loaded.meta.dirty)
        #expect(loaded.meta.title == "Plan")

        try store.append(key, [.remote(Data([4])), .local(Data([5]))])
        loaded = try #require(store.load(key))
        #expect(loaded.updates == [Data([1, 2, 3]), Data([4]), Data([5])])
        #expect(loaded.meta.dirty)

        let acked = StateVector([5: 11, 8: 2]).encoded()
        try store.append(key, [.state(ReplicaState(dirty: false, knownServerSV: acked, noteCreatedAt: nil))])
        loaded = try #require(store.load(key))
        #expect(!loaded.meta.dirty)
        #expect(loaded.meta.knownServerSV == acked)
        #expect(loaded.meta.noteCreatedAt == Date(timeIntervalSince1970: 1_700_000_000))

        // A torn tail record (crash mid-append) is ignored.
        let log = store.logURL(key)
        let h = try FileHandle(forWritingTo: log)
        try h.seekToEnd()
        try h.write(contentsOf: Data([1, 0, 0, 0, 99, 1, 2]))
        try h.close()
        loaded = try #require(store.load(key))
        #expect(loaded.updates.count == 3)
        #expect(!loaded.meta.dirty)

        // Compaction drops the log.
        try store.save(loaded.meta, state: Data([7]))
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(store.load(key)?.updates == [Data([7])])
        try? FileManager.default.removeItem(at: store.root)
    }

    @Test("a corrupt replica file is dropped, never half-read")
    func corrupt() throws {
        let store = ReplicaStore(root: tempReplicaRoot())
        let key = ReplicaKey(account: accountA, vaultID: vault, noteID: "x")
        try store.save(ReplicaMeta(key: key), state: Data([1]))
        try Data("garbage".utf8).write(to: store.replicaURL(key))
        #expect(store.load(key) == nil)
        #expect(!store.exists(key))
        try? FileManager.default.removeItem(at: store.root)
    }

    @Test("root is excluded from backups; keys never leak note ids or usernames into paths")
    func layout() throws {
        let store = ReplicaStore(root: tempReplicaRoot())
        let key = ReplicaKey(account: accountA, vaultID: vault, noteID: "secret plans")
        try store.save(ReplicaMeta(key: key), state: Data([1]))
        let values = try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let path = store.replicaURL(key).path
        #expect(!path.contains("secret"))
        #expect(!path.contains("ana"))
        try? FileManager.default.removeItem(at: store.root)
    }

    @Test("LRU eviction respects the cap and never drops dirty or protected replicas")
    func eviction() throws {
        let store = ReplicaStore(root: tempReplicaRoot(), maxBytes: 2_500)
        let blob = Data(repeating: 7, count: 1_000)
        func key(_ n: String) -> ReplicaKey { ReplicaKey(account: accountA, vaultID: vault, noteID: n) }
        let base = Date(timeIntervalSince1970: 1_000)
        // Oldest first: dirty, protected, then two clean ones.
        try store.save(ReplicaMeta(key: key("dirty"), dirty: true, lastAccess: base), state: blob)
        try store.save(ReplicaMeta(key: key("open"), lastAccess: base.addingTimeInterval(1)), state: blob)
        try store.save(ReplicaMeta(key: key("old"), lastAccess: base.addingTimeInterval(2)), state: blob)
        try store.save(ReplicaMeta(key: key("new"), lastAccess: base.addingTimeInterval(3)), state: blob)
        // A clean replica that turned dirty through its log counts as dirty.
        try store.save(ReplicaMeta(key: key("logdirty"), lastAccess: base.addingTimeInterval(0.5)), state: blob)
        try store.append(key("logdirty"), [.local(Data([1]))])

        let evicted = store.evict(protecting: [key("open")])
        #expect(Set(evicted.map(\.noteID)) == ["old", "new"])
        #expect(store.exists(key("dirty")))
        #expect(store.exists(key("logdirty")))
        #expect(store.exists(key("open")))
        #expect(store.pending().map(\.key.noteID).sorted() == ["dirty", "logdirty"])
        try? FileManager.default.removeItem(at: store.root)
    }

    @Test("purge (account removal) wipes replicas + listing; pending text is kept export-only")
    func purge() throws {
        let store = ReplicaStore(root: tempReplicaRoot())
        let kA1 = ReplicaKey(account: accountA, vaultID: vault, noteID: "a1")
        let kA2 = ReplicaKey(account: accountA, vaultID: UUID(), noteID: "a2")
        let kB = ReplicaKey(account: accountB, vaultID: vault, noteID: "b")
        try store.save(ReplicaMeta(key: kA1, title: "Draft", dirty: true), state: Data([1]))
        try store.save(ReplicaMeta(key: kA2), state: Data([2]))
        try store.save(ReplicaMeta(key: kB, dirty: true), state: Data([3]))
        store.saveListing(BookListingCache(notes: [], capabilities: ["note.*"]), account: accountA, vaultID: vault)

        let recovered = store.purge(account: accountA, reason: .accountRemoved) { updates in
            "text of \(updates.count) update(s)"
        }
        #expect(recovered.count == 1)
        #expect(recovered.first?.title == "Draft")
        #expect(recovered.first?.uploadable == false)
        #expect(recovered.first?.reason == .accountRemoved)
        #expect(!store.exists(kA1))
        #expect(!store.exists(kA2))
        #expect(store.loadListing(account: accountA, vaultID: vault) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.accountDir(accountA).path))
        #expect(store.exists(kB))
        #expect(store.recovered(account: accountA).count == 1)
        #expect(store.recovered(account: accountB).isEmpty)

        let dir = store.root.appendingPathComponent("export")
        let urls = try ReplicaStore.export(recovered, to: dir)
        #expect(urls.count == 1)
        #expect(urls.first?.lastPathComponent == "Draft (conflito offline).md")
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "text of 1 update(s)")
        store.deleteRecovered(recovered[0].id)
        #expect(store.recovered().isEmpty)
        try? FileManager.default.removeItem(at: store.root)
    }

    @Test("purge of one book leaves the account's other books")
    func purgeBook() throws {
        let store = ReplicaStore(root: tempReplicaRoot())
        let other = UUID()
        let k1 = ReplicaKey(account: accountA, vaultID: vault, noteID: "n")
        let k2 = ReplicaKey(account: accountA, vaultID: other, noteID: "n")
        try store.save(ReplicaMeta(key: k1), state: Data([1]))
        try store.save(ReplicaMeta(key: k2), state: Data([1]))
        store.purge(account: accountA, vaultID: vault, reason: .accessRevoked) { _ in nil }
        #expect(!store.exists(k1))
        #expect(store.exists(k2))
        try? FileManager.default.removeItem(at: store.root)
    }

    @Test("listing cache round-trips notes and our capabilities")
    func listing() throws {
        let store = ReplicaStore(root: tempReplicaRoot())
        let note = RemoteNote(id: "a", vaultID: vault, path: "dir/a.md", title: "A",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: nil)
        store.saveListing(BookListingCache(notes: [note], capabilities: ["note.edit"]), account: accountA, vaultID: vault)
        let cache = try #require(store.loadListing(account: accountA, vaultID: vault))
        #expect(cache.notes == [note])
        #expect(cache.capabilities == ["note.edit"])
        #expect(store.loadListing(account: accountB, vaultID: vault) == nil)
        try? FileManager.default.removeItem(at: store.root)
    }
}
