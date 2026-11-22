import Foundation
import Testing
@testable import LumiKit

private let work = AccountKey(serverURL: "https://lumi.work.com", username: "alice")
private let friend = AccountKey(serverURL: "https://notes.friend.org", username: "alice")
private let workBob = AccountKey(serverURL: "https://lumi.work.com", username: "bob")
private let vid = UUID(uuidString: "8c5a1d9f-2e3b-4c4d-9e5f-6a7b8c9d0e1f")!
private let now = ts("2026-11-22T12:00:00Z")

private func vault(_ id: UUID = vid, name: String = "Trabalho", slug: String = "trabalho", role: String? = nil) -> RemoteVault {
    RemoteVault(id: id, slug: slug, name: name, createdBy: UUID(), createdAt: nil,
                federation: role.map { VaultFederation(role: $0, homeURL: nil, status: "active") })
}

@Suite("Book dedupe across federated servers (SPEC-LIVROS §2.4)")
struct BookReconcilerTests {
    @Test("rule 2: a vault seen by one account becomes a bound book, id = vault_id")
    func singleSource() {
        let r = BookReconciler.reconcile(
            books: [],
            listings: [AccountListing(key: work, accountAddedAt: ts("2026-01-01T00:00:00Z"), vaults: [vault()])],
            now: now)
        #expect(r.books.count == 1)
        let b = r.books[0]
        #expect(b.id == vid.uuidString.lowercased() && b.vaultID == b.id)
        #expect(b.accountKey == work && b.kind == .bound && b.path == nil && b.sort == 10)
        #expect(r.notices.isEmpty && r.alternates.isEmpty)
    }

    @Test("rule 3: federated copy binds to the home server even if that account is newer")
    func prefersHome() {
        let r = BookReconciler.reconcile(
            books: [],
            listings: [
                AccountListing(key: friend, accountAddedAt: ts("2025-01-01T00:00:00Z"), vaults: [vault(role: "follower")]),
                AccountListing(key: work, accountAddedAt: ts("2026-06-01T00:00:00Z"), vaults: [vault(role: "home")])
            ],
            now: now)
        #expect(r.books.count == 1, "never two books for one vault_id")
        #expect(r.books[0].accountKey == work)
        #expect(r.alternates[r.books[0].id] == [friend])
        #expect(r.notices == [FederationNotice(bookID: r.books[0].id, syncsVia: work, alsoOn: [friend])])
    }

    @Test("rule 3: without a home among the accounts, the oldest account wins")
    func oldestAccount() {
        let r = BookReconciler.reconcile(
            books: [],
            listings: [
                AccountListing(key: work, accountAddedAt: ts("2026-06-01T00:00:00Z"), vaults: [vault(role: "follower")]),
                AccountListing(key: workBob, accountAddedAt: ts("2026-02-01T00:00:00Z"), vaults: [vault()])
            ],
            now: now)
        #expect(r.books.map(\.accountKey) == [workBob])
        #expect(r.alternates.values.first == [work])
    }

    @Test("rule 4: an existing binding is kept; other sources are alternates; name cache refreshes")
    func existingBindingKept() {
        let existing = Book(id: "local-id", name: "Old", kind: .bound, serverURL: friend.serverURL,
                            account: friend.username, vaultID: vid.uuidString.lowercased(), sort: 10, addedAt: now)
        let r = BookReconciler.reconcile(
            books: [existing],
            listings: [
                AccountListing(key: work, accountAddedAt: ts("2025-01-01T00:00:00Z"), vaults: [vault(name: "Novo", role: "home")]),
                AccountListing(key: friend, accountAddedAt: ts("2026-01-01T00:00:00Z"), vaults: [vault(name: "Novo", role: "follower")])
            ],
            now: now)
        #expect(r.books.count == 1)
        #expect(r.books[0].accountKey == friend, "home preference only applies to new books")
        #expect(r.books[0].name == "Novo")
        #expect(r.alternates["local-id"] == [work])
        #expect(r.added.isEmpty && r.notices.isEmpty)
    }

    @Test("bound book missing from its (successful) account listing is revoked; failed accounts are not")
    func revoked() {
        let a = Book(id: "a", name: "A", kind: .bound, serverURL: work.serverURL, account: work.username,
                     vaultID: UUID().uuidString.lowercased(), sort: 10, addedAt: now)
        let b = Book(id: "b", name: "B", kind: .bound, serverURL: friend.serverURL, account: friend.username,
                     vaultID: UUID().uuidString.lowercased(), sort: 20, addedAt: now)
        let r = BookReconciler.reconcile(
            books: [a, b], listings: [AccountListing(key: work, accountAddedAt: now, vaults: [])], now: now)
        #expect(r.revoked == ["a"])
        #expect(r.books.count == 2, "revoked books stay until the user removes them")
    }

    @Test("dismissed vaults are not re-added; local books are untouched")
    func dismissedAndLocal() {
        let local = Book(id: "l", name: "L", kind: .local, path: "~/l", sort: 10, addedAt: now)
        let r = BookReconciler.reconcile(
            books: [local],
            listings: [AccountListing(key: work, accountAddedAt: now, vaults: [vault()])],
            dismissedVaultIDs: [vid.uuidString.lowercased()], now: now)
        #expect(r.books == [local])
    }

    @Test("path-less duplicate bound rows collapse to one")
    func duplicatesCollapse() {
        let v = vid.uuidString.lowercased()
        let first = Book(id: "1", name: "A", kind: .bound, serverURL: work.serverURL, account: work.username, vaultID: v, sort: 10, addedAt: now)
        let dup = Book(id: "2", name: "A", kind: .bound, serverURL: friend.serverURL, account: friend.username, vaultID: v, sort: 20, addedAt: now)
        let r = BookReconciler.reconcile(books: [first, dup], listings: [], now: now)
        #expect(r.books.map(\.id) == ["1"])
    }

    @Test("VaultRecord migration: vault_id resolves by slug on first listing")
    func slugResolution() {
        let pending = Book(id: "rec", name: "Work", kind: .bound, serverURL: work.serverURL, account: "some-account-id",
                           vaultID: nil, sort: 10, addedAt: now)
        let r = BookReconciler.reconcile(
            books: [pending],
            listings: [AccountListing(key: work, accountAddedAt: now, vaults: [vault(slug: "work")])],
            pendingSlugs: ["rec": "work"], now: now)
        #expect(r.resolvedSlugs == ["rec"])
        #expect(r.books.count == 1, "resolved row absorbs the listing, no duplicate")
        #expect(r.books[0].vaultID == vid.uuidString.lowercased())
        #expect(r.books[0].account == "alice")
    }

    @Test("switcher order: local first, servers grouped by smallest sort; ⌃⌘ numbering follows it")
    func switcherOrder() {
        let books = [
            Book(id: "w2", name: "w2", kind: .bound, serverURL: work.serverURL, account: "alice", vaultID: "x", sort: 40, addedAt: now),
            Book(id: "f1", name: "f1", kind: .bound, serverURL: friend.serverURL, account: "alice", vaultID: "y", sort: 10, addedAt: now),
            Book(id: "l1", name: "l1", kind: .local, sort: 30, addedAt: now),
            Book(id: "w1", name: "w1", kind: .bound, serverURL: work.serverURL, account: "bob", vaultID: "z", sort: 20, addedAt: now)
        ]
        #expect(BookSwitcherOrder.groups(books).map(\.serverURL) == [nil, friend.serverURL, work.serverURL])
        #expect(BookSwitcherOrder.flattened(books).map(\.id) == ["l1", "f1", "w1", "w2"])
    }
}
