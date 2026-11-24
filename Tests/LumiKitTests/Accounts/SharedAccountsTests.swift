import Foundation
import Testing
@testable import LumiKit

/// Records every request a host receives (path + body).
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, String)] = []
    func add(_ path: String, _ body: String) { lock.lock(); items.append((path, body)); lock.unlock() }
    var all: [(String, String)] { lock.lock(); defer { lock.unlock() }; return items }
}

private func bodyString(_ req: URLRequest) -> String {
    if let d = req.httpBody { return String(decoding: d, as: UTF8.self) }
    guard let s = req.httpBodyStream else { return "" }
    s.open(); defer { s.close() }
    var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
    while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
    return String(decoding: data, as: UTF8.self)
}

private func routedHost(_ rec: Recorder) -> String {
    let host = "shared-\(UUID().uuidString.prefix(8).lowercased()).test"
    HostRoutedURLProtocol.route(host: host) { req in
        let path = req.url?.path ?? ""
        rec.add(path, bodyString(req))
        if path == "/api/auth/login" {
            return (200, Data(#"{"token":"tok-app","expires_at":"2026-12-22T00:00:00Z","user":{"id":"0192f7a1-3b4c-7d5e-8f60-718293a4b5c6","username":"alice","display_name":"Alice"}}"#.utf8))
        }
        return (204, Data())
    }
    return host
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ d: Date) { value = d }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Simulates the TUI writing the shared file (separate registry instance).
private func tuiWrite(_ url: URL, _ body: (inout [Account]) -> Void) throws {
    try AccountsRegistryFile(fileURL: url).mutate(body)
}

@MainActor
@Suite("Shared account registry with the TUI (SPEC-LIVROS §8.5/§8.6)")
struct SharedAccountsTests {
    @Test("sign in writes the shared row (no token in the file) and keeps TUI fields")
    func signInWritesRow() async throws {
        let rec = Recorder(), host = routedHost(rec)
        let url = tempAccountsURL()
        let server = "https://\(host)"
        try tuiWrite(url) { $0.append(Account(serverURL: server, username: "alice", userID: "", displayName: "",
                                              addedAt: ts("2026-11-01T00:00:00Z"), webOrigin: "https://web.test")) }
        let tokens = InMemoryTokenStore()
        let store = AccountsStore(fileURL: url, defaults: freshDefaults(), tokens: tokens, urlSession: HostRoutedURLProtocol.session)
        store.load()
        #expect(store.state(AccountKey(serverURL: server, username: "alice")) != .signedIn)
        try await store.signIn(serverURL: server, username: "alice", password: "pw")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("tok-app"))
        let row = try #require(AccountsRegistryFile(fileURL: url).read().document?.accounts.first)
        #expect(row.webOrigin == "https://web.test")
        #expect(row.addedAt == ts("2026-11-01T00:00:00Z"))
        #expect(row.displayName == "Alice")
        #expect(row.expiresAt == ts("2026-12-22T00:00:00Z"))
        #expect(tokens.token(account: "\(server)#alice") == "tok-app")
    }

    @Test("an account added by the TUI appears on reload as needs-sign-in")
    func tuiAddsAccount() throws {
        let url = tempAccountsURL()
        let store = AccountsStore(fileURL: url, defaults: freshDefaults(), tokens: InMemoryTokenStore())
        store.load()
        #expect(store.accounts.isEmpty)
        try tuiWrite(url) { $0.append(Account(serverURL: "https://x.test", username: "Bob", userID: "", displayName: "",
                                              addedAt: ts("2026-11-01T00:00:00Z"))) }
        store.reload()
        let key = AccountKey(serverURL: "https://x.test", username: "bob")
        #expect(store.accounts.map(\.key) == [key])
        #expect(!store.state(key).isSignedIn)
    }

    @Test("TUI removing the row drops the app's token and revokes it")
    func tuiRemovesAccount() async throws {
        let rec = Recorder(), host = routedHost(rec)
        let url = tempAccountsURL(), server = "https://\(host)"
        let tokens = InMemoryTokenStore()
        let store = AccountsStore(fileURL: url, defaults: freshDefaults(), tokens: tokens, urlSession: HostRoutedURLProtocol.session)
        store.load()
        try await store.signIn(serverURL: server, username: "alice", password: "pw")
        try tuiWrite(url) { $0.removeAll() }
        store.reload()
        #expect(store.accounts.isEmpty)
        #expect(tokens.token(account: "\(server)#alice") == nil)
        for t in store.pendingRevocations { await t.value }
        #expect(rec.all.contains { $0.0 == "/api/auth/logout" })
    }

    @Test("TUI 'sair neste Mac' (signed_out_at newer than our session) drops our token; an older one doesn't")
    func signedOutElsewhere() async throws {
        let rec = Recorder(), host = routedHost(rec)
        let url = tempAccountsURL(), server = "https://\(host)"
        let tokens = InMemoryTokenStore()
        let clock = TestClock(ts("2026-11-24T10:00:00Z"))
        let store = AccountsStore(fileURL: url, defaults: freshDefaults(), tokens: tokens,
                                  urlSession: HostRoutedURLProtocol.session, now: { clock.now })
        store.load()
        try await store.signIn(serverURL: server, username: "alice", password: "pw")
        let key = AccountKey(serverURL: server, username: "alice")
        // Older stamp: our session is newer → kept.
        try tuiWrite(url) { $0[0].signedOutAt = ts("2026-11-24T09:00:00Z") }
        store.reload()
        #expect(store.state(key).isSignedIn)
        clock.now = ts("2026-11-24T11:00:00Z")
        try tuiWrite(url) { $0[0].signedOutAt = ts("2026-11-24T10:30:00Z") }
        store.reload()
        #expect(!store.state(key).isSignedIn)
        #expect(tokens.token(account: key.keychainAccount) == nil)
        #expect(store.accounts.count == 1, "the row stays")
    }

    @Test("sign out everywhere on this Mac: scope=device, token gone, signed_out_at stamped")
    func signOutEverywhere() async throws {
        let rec = Recorder(), host = routedHost(rec)
        let url = tempAccountsURL(), server = "https://\(host)"
        let tokens = InMemoryTokenStore()
        let store = AccountsStore(fileURL: url, defaults: freshDefaults(), tokens: tokens,
                                  urlSession: HostRoutedURLProtocol.session, now: { ts("2026-11-24T12:00:00Z") })
        store.load()
        try await store.signIn(serverURL: server, username: "alice", password: "pw")
        let key = AccountKey(serverURL: server, username: "alice")
        await store.signOutEverywhereOnThisMac(key)
        #expect(rec.all.contains { $0.0 == "/api/auth/logout" && $0.1.contains(#""scope":"device""#) })
        #expect(tokens.token(account: key.keychainAccount) == nil)
        #expect(AccountsRegistryFile(fileURL: url).read().document?.accounts.first?.signedOutAt == ts("2026-11-24T12:00:00Z"))
        #expect(!store.isLinkOptedOut(key), "the app may link again once the TUI signs in")
    }

    @Test("sign out of this app only: no scope, row kept, link opt-out set; sign-in clears it")
    func signOutAppOnly() async throws {
        let rec = Recorder(), host = routedHost(rec)
        let url = tempAccountsURL(), server = "https://\(host)"
        let store = AccountsStore(fileURL: url, defaults: freshDefaults(), tokens: InMemoryTokenStore(),
                                  urlSession: HostRoutedURLProtocol.session)
        store.load()
        try await store.signIn(serverURL: server, username: "alice", password: "pw")
        let key = AccountKey(serverURL: server, username: "alice")
        await store.signOut(key)
        let logout = try #require(rec.all.first { $0.0 == "/api/auth/logout" })
        #expect(!logout.1.contains("scope"))
        #expect(store.isLinkOptedOut(key))
        #expect(AccountsRegistryFile(fileURL: url).read().document?.accounts.first?.signedOutAt == nil)
        try await store.signIn(serverURL: server, username: "alice", password: "pw")
        #expect(!store.isLinkOptedOut(key))
    }

    @Test("remove: scope=device and the shared row disappears")
    func removeAccount() async throws {
        let rec = Recorder(), host = routedHost(rec)
        let url = tempAccountsURL(), server = "https://\(host)"
        let store = AccountsStore(fileURL: url, defaults: freshDefaults(), tokens: InMemoryTokenStore(),
                                  urlSession: HostRoutedURLProtocol.session)
        store.load()
        try await store.signIn(serverURL: server, username: "alice", password: "pw")
        await store.remove(AccountKey(serverURL: server, username: "alice"))
        #expect(rec.all.contains { $0.1.contains(#""scope":"device""#) })
        #expect(AccountsRegistryFile(fileURL: url).read().document?.accounts.isEmpty == true)
    }

    @Test("UserDefaults lumi.accounts.v1 migrates into the shared file, merged with TUI rows")
    func migratesDefaultsList() throws {
        let url = tempAccountsURL()
        try tuiWrite(url) { $0.append(Account(serverURL: "https://tui.test", username: "t", userID: "", displayName: "",
                                              addedAt: ts("2026-10-01T00:00:00Z"))) }
        let defaults = freshDefaults()
        let rows = [Account(serverURL: "https://app.test", username: "a", userID: "1", displayName: "A",
                            addedAt: ts("2026-11-01T00:00:00Z"))]
        defaults.set(try JSONEncoder.accounts.encode(rows), forKey: AccountsStore.defaultsKey)
        let tokens = InMemoryTokenStore(["https://app.test#a": "tok"])
        let store = AccountsStore(fileURL: url, defaults: defaults, tokens: tokens)
        store.load()
        #expect(defaults.data(forKey: AccountsStore.defaultsKey) == nil)
        #expect(store.accounts.map(\.username) == ["t", "a"])
        #expect(store.state(rows[0].key).isSignedIn, "Keychain item is unchanged")
        #expect(store.signedInAt(rows[0].key) != nil)
    }

    @Test("an unreadable file never signs the app out")
    func malformedKeepsSessions() async throws {
        let rec = Recorder(), host = routedHost(rec)
        let url = tempAccountsURL(), server = "https://\(host)"
        let tokens = InMemoryTokenStore()
        let store = AccountsStore(fileURL: url, defaults: freshDefaults(), tokens: tokens, urlSession: HostRoutedURLProtocol.session)
        store.load()
        try await store.signIn(serverURL: server, username: "alice", password: "pw")
        try "accounts:\n  - server: \"unterminated\n".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.readOnlyReason != nil)
        #expect(tokens.token(account: "\(server)#alice") == "tok-app")
    }
}
