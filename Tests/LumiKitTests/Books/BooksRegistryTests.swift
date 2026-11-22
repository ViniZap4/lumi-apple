import Foundation
import Testing
@testable import LumiKit

@MainActor
@Suite("BooksRegistry — file-backed registry, active book, migration")
struct BooksRegistryTests {
    private func make(_ dir: URL = tempDir(), defaults: UserDefaults = freshDefaults()) -> BooksRegistry {
        BooksRegistry(fileURL: dir.appendingPathComponent("books.yaml"), defaults: defaults,
                      bookmarks: InMemoryBookmarkStore(), now: { ts("2026-11-22T12:00:00Z") })
    }

    @Test("rewriting the shared fixture preserves bytes, including the TUI-only active field")
    func preservesFixture() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("books.yaml")
        let fixture = try Fixtures.data("books/books.v1.yaml")
        try fixture.write(to: file)
        let reg = make(dir)
        reg.reload()
        #expect(reg.books.count == 5)
        // A no-op mutation forces a rewrite through the encoder.
        #expect(reg.mutate { _ in })
        #expect(try Data(contentsOf: file) == fixture)
    }

    @Test("active book persists per device and falls back to the lowest sort")
    func activeFallback() {
        let defaults = freshDefaults()
        let dir = tempDir()
        let reg = make(dir, defaults: defaults)
        let a = reg.addLocal(name: "A", path: nil, bookmark: nil)!
        let b = reg.addLocal(name: "B", path: nil, bookmark: nil)!
        #expect(reg.activeBook?.id == a.id)
        reg.setActive(b.id)
        #expect(defaults.string(forKey: BooksRegistry.activeBookKey) == b.id)
        let again = make(dir, defaults: defaults)
        again.reload()
        #expect(again.activeBook?.id == b.id)
        again.remove(b.id)
        #expect(again.activeBook?.id == a.id)
    }

    @Test("mutations merge with a concurrent TUI write instead of clobbering it")
    func mergesExternalWrite() throws {
        let dir = tempDir()
        let reg = make(dir)
        let mine = reg.addLocal(name: "Mine", path: nil, bookmark: nil)!
        // TUI appends a row behind our back.
        var doc = try BooksFile.decode(String(contentsOf: reg.fileURL, encoding: .utf8))
        doc.books.append(Book(id: "tui-row", name: "TUI", kind: .local, path: "~/tui", sort: 20, addedAt: ts("2026-11-22T00:00:00Z")))
        doc.active = "tui-row"
        try BooksFile.encode(doc).write(to: reg.fileURL, atomically: true, encoding: .utf8)
        reg.rename(mine.id, to: "Renamed")
        let after = try BooksFile.decode(String(contentsOf: reg.fileURL, encoding: .utf8))
        #expect(after.books.map(\.name) == ["Renamed", "TUI"])
        #expect(after.active == "tui-row")
    }

    @Test("unlink: with a folder → local; without → removed and dismissed")
    func unlink() {
        let reg = make()
        let acct = AccountKey(serverURL: "https://lumi.work.com", username: "alice")
        let withPath = reg.addBound(name: "P", account: acct, vaultID: UUID(), path: "/tmp/p")!
        let remote = reg.addBound(name: "R", account: acct, vaultID: UUID())!
        #expect(reg.unlink(withPath.id))
        #expect(reg.book(withPath.id)?.kind == .local && reg.book(withPath.id)?.vaultID == nil)
        #expect(reg.unlink(remote.id))
        #expect(reg.book(remote.id) == nil)
        #expect(reg.dismissedVaultIDs.contains(remote.vaultID!))
    }

    @Test("reorder assigns steps of 10 in the given order")
    func reorder() {
        let reg = make()
        let a = reg.addLocal(name: "A", path: nil, bookmark: nil)!
        let b = reg.addLocal(name: "B", path: nil, bookmark: nil)!
        let c = reg.addLocal(name: "C", path: nil, bookmark: nil)!
        reg.reorder([c.id, a.id, b.id])
        #expect(reg.books.map(\.name) == ["C", "A", "B"])
        #expect(reg.books.map(\.sort) == [10, 20, 30])
    }

    @Test("newer file version makes the registry read-only")
    func readOnly() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("books.yaml")
        let v2 = "version: 2\nactive: null\nbooks: []\n"
        try v2.write(to: file, atomically: true, encoding: .utf8)
        let reg = make(dir)
        reg.reload()
        #expect(reg.readOnlyReason != nil)
        #expect(reg.addLocal(name: "x", path: nil, bookmark: nil) == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == v2)
    }

    @Test("migration: VaultRecord + vaults.yaml → books.yaml, bookmarks to side store, vaults.yaml untouched")
    func migration() throws {
        let dir = tempDir()
        let vaultsYAML = dir.appendingPathComponent("vaults.yaml")
        let tuiID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let localYAML = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let legacyText = """
        vaults:
          - id: \(tuiID.uuidString.lowercased())
            name: Team
            path: /srv/team
            server: https://lumi.work.com/
            account: alice
            added_at: 2026-05-14T12:00:00Z
            last_opened_at: 2026-05-14T12:05:00Z
          - id: \(localYAML.uuidString.lowercased())
            name: Scratch
            path: /tmp/scratch
            server: null
            account: null
            added_at: 2026-05-01T12:00:00Z
            last_opened_at: null
        """
        try legacyText.write(to: vaultsYAML, atomically: true, encoding: .utf8)
        let recLocal = LegacyVaultSnapshot(id: UUID(), name: "Notes", bookmark: Data([1, 2, 3]), resolvedPath: "/Users/x/Notes",
                                           serverEndpoint: nil, serverVaultSlug: nil, serverAccountID: nil,
                                           addedAt: ts("2026-01-01T00:00:00Z"), lastOpenedAt: ts("2026-11-01T00:00:00Z"))
        let recRemote = LegacyVaultSnapshot(id: UUID(), name: "Remote", bookmark: nil, resolvedPath: nil,
                                            serverEndpoint: "https://lumi.work.com", serverVaultSlug: "remote",
                                            serverAccountID: "alice", addedAt: ts("2026-01-02T00:00:00Z"), lastOpenedAt: nil)
        let bookmarks = InMemoryBookmarkStore()
        let reg = BooksRegistry(fileURL: dir.appendingPathComponent("books.yaml"), defaults: freshDefaults(),
                                bookmarks: bookmarks, now: { ts("2026-11-22T12:00:00Z") })
        let wrote = reg.importIfNeeded(records: [recRemote, recLocal], vaultsYAML: vaultsYAML,
                                       readVaultID: { $0 == "/srv/team" ? "8C5A1D9F-2E3B-4C4D-9E5F-6A7B8C9D0E1F" : nil })
        #expect(wrote)
        // VaultRecord rows first (Apple canonical), then vaults.yaml-only rows.
        #expect(reg.books.map(\.name) == ["Notes", "Remote", "Team", "Scratch"])
        #expect(reg.books.map(\.sort) == [10, 20, 30, 40])
        let notes = reg.books[0]
        #expect(notes.kind == .local && notes.id == recLocal.id.uuidString.lowercased())
        #expect(bookmarks.bookmark(for: notes.id) == Data([1, 2, 3]))
        let team = reg.books[2]
        #expect(team.kind == .bound && team.serverURL == "https://lumi.work.com" && team.account == "alice")
        #expect(team.vaultID == "8c5a1d9f-2e3b-4c4d-9e5f-6a7b8c9d0e1f" && team.path == "/srv/team")
        let remote = reg.books[1]
        #expect(remote.kind == .bound && remote.vaultID == nil)
        #expect(reg.pendingSlugs[remote.id] == "remote")
        #expect(reg.books[3].kind == .local)
        #expect(try String(contentsOf: vaultsYAML, encoding: .utf8) == legacyText, "vaults.yaml is read-only")
        // Second run is a no-op.
        #expect(!reg.importIfNeeded(records: [], vaultsYAML: vaultsYAML))
        #expect(reg.books.count == 4)
    }

    @Test(".lumi/vault.yaml server.vault_id reader")
    func vaultYAML() {
        let text = "id: local\nname: x\nserver:\n  url: https://lumi.work.com\n  vault_id: \"8c5a1d9f-2e3b-4c4d-9e5f-6a7b8c9d0e1f\"\n"
        #expect(BooksMigration.serverVaultID(fromVaultYAML: text) == "8c5a1d9f-2e3b-4c4d-9e5f-6a7b8c9d0e1f")
        #expect(BooksMigration.serverVaultID(fromVaultYAML: "vault_id: nope\nserver: null\n") == nil)
    }

    @Test("apply(reconcile) adds books once and returns federation notices only the first time")
    func applyReconcile() {
        let reg = make()
        let work = AccountKey(serverURL: "https://lumi.work.com", username: "alice")
        let friend = AccountKey(serverURL: "https://notes.friend.org", username: "alice")
        let v = RemoteVault(id: UUID(), slug: "s", name: "Shared", createdBy: UUID(), createdAt: nil,
                            federation: VaultFederation(role: "home", homeURL: nil, status: nil))
        let listings = [AccountListing(key: friend, accountAddedAt: ts("2025-01-01T00:00:00Z"), vaults: [v]),
                        AccountListing(key: work, accountAddedAt: ts("2026-01-01T00:00:00Z"), vaults: [v])]
        let r1 = BookReconciler.reconcile(books: reg.books, listings: listings, now: Date())
        #expect(reg.apply(r1).count == 1)
        #expect(reg.books.count == 1)
        let r2 = BookReconciler.reconcile(books: reg.books, listings: listings, now: Date())
        #expect(reg.apply(r2).isEmpty)
        #expect(reg.books.count == 1)
    }
}
