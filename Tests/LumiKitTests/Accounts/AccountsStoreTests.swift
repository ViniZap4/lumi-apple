import Foundation
import Testing
@testable import LumiKit

/// Per-host canned responses so these tests never share the global
/// `MockURLProtocol` handler with the serialized API-client suite.
final class HostRoutedURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: Handler] = [:]

    static func route(host: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    static func handler(for host: String?) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return host.flatMap { handlers[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let h = Self.handler(for: request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, data) = h(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [HostRoutedURLProtocol.self]
        return URLSession(configuration: c)
    }
}

private func loginJSON(_ user: String, token: String) -> Data {
    Data(#"{"token":"\#(token)","expires_at":"2026-12-22T00:00:00Z","user":{"id":"id-\#(user)","username":"\#(user)","display_name":"\#(user.capitalized)"}}"#.utf8)
}

@MainActor
@Suite("AccountsStore — multi-account, Keychain keys, migration (SPEC-LIVROS §2.2/§2.5)")
struct AccountsStoreTests {
    @Test("two accounts on the same server keep separate tokens and clients")
    func twoAccountsSameServer() async throws {
        let host = "acct-\(UUID().uuidString.prefix(8).lowercased()).test"
        HostRoutedURLProtocol.route(host: host) { req in
            let body = String(decoding: req.httpBodyStream.map(readAll) ?? req.httpBody ?? Data(), as: UTF8.self)
            if req.url?.path == "/api/auth/login" {
                return body.contains("alice") ? (200, loginJSON("alice", token: "tok-a")) : (200, loginJSON("bob", token: "tok-b"))
            }
            // Echo which token hit /users/me.
            let tok = req.value(forHTTPHeaderField: "X-Lumi-Token") ?? "none"
            return (200, Data(#"{"id":"x","username":"\#(tok)","display_name":"x"}"#.utf8))
        }
        let tokens = InMemoryTokenStore()
        let store = AccountsStore(defaults: freshDefaults(), tokens: tokens, urlSession: HostRoutedURLProtocol.session)
        let a = try await store.signIn(serverURL: "https://\(host)/", username: "alice", password: "pw")
        let b = try await store.signIn(serverURL: "https://\(host)", username: "bob", password: "pw")
        #expect(store.accounts.count == 2)
        #expect(a.serverURL == b.serverURL)
        #expect(tokens.token(account: "https://\(host)#alice") == "tok-a")
        #expect(tokens.token(account: "https://\(host)#bob") == "tok-b")
        let ca = try #require(store.client(for: a.key))
        let cb = try #require(store.client(for: b.key))
        #expect(ca !== cb)
        #expect(try await ca.currentUser().username == "tok-a")
        #expect(try await cb.currentUser().username == "tok-b")
    }

    @Test("a 401 on one account flips only that account to needs-sign-in")
    func isolation401() async throws {
        let host = "iso-\(UUID().uuidString.prefix(8).lowercased()).test"
        HostRoutedURLProtocol.route(host: host) { req in
            if req.value(forHTTPHeaderField: "X-Lumi-Token") == "dead" { return (401, Data()) }
            return (200, Data(#"{"vaults":[]}"#.utf8))
        }
        let server = "https://\(host)"
        let tokens = InMemoryTokenStore(["\(server)#alice": "dead", "\(server)#bob": "live"])
        let defaults = freshDefaults()
        let accounts = [
            Account(serverURL: server, username: "alice", userID: "1", displayName: "A", addedAt: ts("2026-01-01T00:00:00Z")),
            Account(serverURL: server, username: "bob", userID: "2", displayName: "B", addedAt: ts("2026-01-02T00:00:00Z"))
        ]
        defaults.set(try JSONEncoder.accounts.encode(accounts), forKey: AccountsStore.defaultsKey)
        let store = AccountsStore(defaults: defaults, tokens: tokens, urlSession: HostRoutedURLProtocol.session)
        store.load()
        let alice = accounts[0].key, bob = accounts[1].key
        _ = try? await store.client(for: alice)!.listVaults()
        _ = try await store.client(for: bob)!.listVaults()
        // Observer hops to the main actor asynchronously.
        for _ in 0..<50 where store.state(alice).isSignedIn { await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
        #expect(!store.state(alice).isSignedIn)
        #expect(store.state(bob).isSignedIn)
        #expect(tokens.token(account: "\(server)#alice") == nil, "dead token is purged")
        #expect(tokens.token(account: "\(server)#bob") == "live")
    }

    @Test("legacy single session migrates to server#username and the old item is deleted")
    func migratesLegacy() throws {
        let defaults = freshDefaults()
        let legacy = AuthSession(serverURL: URL(string: "https://Lumi.Work.com/")!,
                                 user: UserDTO(id: "u1", username: "alice", displayName: "Alice"), expiresAt: nil)
        defaults.set(try JSONEncoder().encode(legacy), forKey: AccountsStore.legacySessionKey)
        let tokens = InMemoryTokenStore(["https://Lumi.Work.com/": "tok"])
        let store = AccountsStore(defaults: defaults, tokens: tokens)
        store.load()
        let key = AccountKey(serverURL: "https://lumi.work.com", username: "alice")
        #expect(store.accounts.map(\.key) == [key])
        #expect(store.state(key) == .signedIn)
        #expect(tokens.allAccounts == ["https://lumi.work.com#alice"])
        #expect(defaults.data(forKey: AccountsStore.legacySessionKey) == nil)
        // Persisted: a second store sees it without re-migrating.
        let again = AccountsStore(defaults: defaults, tokens: tokens)
        again.load()
        #expect(again.accounts.map(\.key) == [key])
    }

    @Test("failed Keychain rewrite during migration leaves the account in needs-sign-in")
    func migrationFailure() throws {
        let defaults = freshDefaults()
        let legacy = AuthSession(serverURL: URL(string: "https://lumi.work.com")!,
                                 user: UserDTO(id: "u1", username: "alice", displayName: "Alice"), expiresAt: nil)
        defaults.set(try JSONEncoder().encode(legacy), forKey: AccountsStore.legacySessionKey)
        let tokens = InMemoryTokenStore(["https://lumi.work.com": "tok"])
        tokens.failWrites = true
        let store = AccountsStore(defaults: defaults, tokens: tokens)
        store.load()
        let key = AccountKey(serverURL: "https://lumi.work.com", username: "alice")
        #expect(store.account(key) != nil)
        #expect(!store.state(key).isSignedIn)
    }

    @Test("http to a public host is refused; base path is preserved in requests")
    func urlRules() async throws {
        let store = AccountsStore(defaults: freshDefaults(), tokens: InMemoryTokenStore())
        await #expect(throws: LumiAPIError.self) {
            try await store.signIn(serverURL: "http://lumi.work.com", username: "a", password: "b")
        }
        #expect(LumiAPIClient.endpoint(URL(string: "https://x.com/lumi")!, "/api/vaults")?.absoluteString
                == "https://x.com/lumi/api/vaults")
    }
}

private func readAll(_ stream: InputStream) -> Data {
    stream.open(); defer { stream.close() }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    return data
}
