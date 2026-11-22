import Foundation
import Testing
@testable import LumiKit

@MainActor
@Suite("BooksSyncEngine — reconcile on hello, catch-up on vault.head, session end")
struct BooksSyncEngineTests {
    private let vid = "8c5a1d9f-2e3b-4c4d-9e5f-6a7b8c9d0e1f"

    private func setup(feed: [FakeFeedProtocol.Reply]) throws -> (BooksSyncEngine, AccountKey, String) {
        let host = "eng-\(UUID().uuidString.prefix(8).lowercased()).test"
        let server = "https://\(host)"
        let vid = self.vid
        HostRoutedURLProtocol.route(host: host) { req in
            let path = req.url?.path ?? ""
            if path == "/api/vaults" {
                return (200, Data(#"{"vaults":[{"id":"\#(vid)","slug":"w","name":"Work","created_by":"\#(UUID().uuidString)","head":5,"can_edit":true}]}"#.utf8))
            }
            if path.hasSuffix("/changes") {
                let after = req.url?.query?.contains("after=5") == true ? 6 : 5
                return (200, Data(#"{"notes":[],"deleted":[],"head":\#(after),"more":false}"#.utf8))
            }
            return (404, Data())
        }
        FakeFeedProtocol.script(host: host, feed)
        let defaults = freshDefaults()
        let tokens = InMemoryTokenStore(["\(server)#alice": "tok"])
        let acc = Account(serverURL: server, username: "alice", userID: "1", displayName: "A", addedAt: Date())
        defaults.set(try JSONEncoder.accounts.encode([acc]), forKey: AccountsStore.defaultsKey)
        let accounts = AccountsStore(defaults: defaults, tokens: tokens, urlSession: HostRoutedURLProtocol.session)
        accounts.load()
        let registry = BooksRegistry(fileURL: tempDir().appendingPathComponent("books.yaml"), defaults: defaults,
                                     bookmarks: InMemoryBookmarkStore())
        var cfg = FeedConnection.Config()
        cfg.watchdogInterval = .milliseconds(50)
        cfg.sleep = { d in try await Task.sleep(for: min(d, .seconds(30))) }
        let engine = BooksSyncEngine(accounts: accounts, registry: registry, defaults: defaults,
                                     feedSession: FakeFeedProtocol.session, feedConfig: cfg)
        return (engine, acc.key, host)
    }

    private func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<200 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("hello → book added and up to date; vault.head → catch-up to the new head")
    func helloAndHead() async throws {
        let hello = "event: hello\ndata: {\"protocol\":1,\"vaults\":[{\"vault_id\":\"\(vid)\",\"seq\":5,\"role\":\"Editor\",\"can_edit\":true}]}\n\n"
        let head = "event: vault.head\ndata: {\"vault_id\":\"\(vid)\",\"seq\":6}\n\n"
        let (engine, key, _) = try setup(feed: [FakeFeedProtocol.Reply(chunks: [Data(hello.utf8)], hold: true)])
        await engine.syncAccounts()
        let book = try #require(engine.registry.book(vaultID: vid))
        #expect(book.accountKey == key)
        await waitUntil { engine.feedState[key] == .open && engine.cursor(book.id) == 5 }
        #expect(engine.status(for: book) == .upToDate)
        await engine.handle(.event(FeedEvent.decode(SSEEvent(event: "vault.head", data: String(head.split(separator: "\n")[1].dropFirst(6))))!), from: key)
        #expect(engine.cursor(book.id) == 6)
        #expect(engine.status(for: book) == .upToDate)
        await engine.stopAll()
    }

    @Test("events for a vault bound through another account are ignored (alternate)")
    func ignoresAlternate() async throws {
        let (engine, key, _) = try setup(feed: [])
        await engine.syncAccounts()
        await engine.stopAll()
        let book = try #require(engine.registry.book(vaultID: vid))
        let other = AccountKey(serverURL: "https://other.test", username: "alice")
        await engine.handle(.event(.vaultRevoked(vaultID: vid, reason: "removed")), from: other)
        #expect(!engine.revoked.contains(book.id))
        await engine.handle(.event(.vaultRevoked(vaultID: vid, reason: "removed")), from: key)
        #expect(engine.revoked.contains(book.id))
        #expect(engine.status(for: book) == .error(reason: "you no longer have access to this book"))
    }

    @Test("session.ended → account needs sign-in, book shows Sign in")
    func sessionEnded() async throws {
        let (engine, key, _) = try setup(feed: [FakeFeedProtocol.Reply(chunks: [try Fixtures.data("feed/stream.session-ended.sse")])])
        await engine.syncAccounts()
        await waitUntil { engine.feedState[key] == .authDead }
        let book = try #require(engine.registry.book(vaultID: vid))
        #expect(!engine.accounts.state(key).isSignedIn)
        if case .needsSignIn = engine.status(for: book) {} else { Issue.record("expected needsSignIn, got \(engine.status(for: book))") }
        await engine.stopAll()
    }
}
