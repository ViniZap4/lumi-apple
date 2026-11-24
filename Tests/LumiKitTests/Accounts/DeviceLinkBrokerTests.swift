import Foundation
import Testing
@testable import LumiKit

/// Fake server: issues codes bound to a challenge and redeems them only
/// with the matching verifier (PKCE S256), once.
private final class FakeLinkServer: DeviceLinkAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [String: (challenge: String, user: String)] = [:]
    var issued: [(AccountKey, String, String)] = []
    var redeemed: [String] = []
    var failIssue = false
    var userOverride: String?

    func issueDeviceLink(for account: AccountKey, challenge: String, label: String) async throws -> DeviceLinkCode {
        try issue(account, challenge, label)
    }

    private func issue(_ account: AccountKey, _ challenge: String, _ label: String) throws -> DeviceLinkCode {
        lock.lock(); defer { lock.unlock() }
        if failIssue { throw LumiAPIError.unauthorized }
        let code = String(repeating: "ab", count: 32)
        codes[code] = (challenge, account.username)
        issued.append((account, challenge, label))
        return DeviceLinkCode(code: code, expiresAt: ts("2030-01-01T00:00:00Z"))
    }

    func redeemDeviceLink(serverURL: String, code: String, verifier: String, label: String) async throws -> SessionResponse {
        try redeem(code, verifier)
    }

    private func redeem(_ code: String, _ verifier: String) throws -> SessionResponse {
        lock.lock(); defer { lock.unlock() }
        guard let entry = codes.removeValue(forKey: code), DeviceLink.challenge(for: verifier) == entry.challenge else {
            throw LumiAPIError.unauthorized
        }
        redeemed.append(code)
        let user = userOverride ?? entry.user
        return SessionResponse(token: "linked-\(user)", expiresAt: nil,
                               user: UserDTO(id: "id-\(user)", username: user, displayName: user))
    }
}

@MainActor
@Suite("DeviceLinkBroker — requester and holder over the drop box (SPEC-LIVROS §8.4)")
struct DeviceLinkBrokerTests {
    let server = "https://link.test"
    var alice: AccountKey { AccountKey(serverURL: server, username: "alice") }

    private func setup(tokens: [String: String], now: Date = ts("2026-11-24T10:00:00Z"),
                       alive: Set<Int32> = []) throws
        -> (AccountsStore, DeviceLinkBroker, FakeLinkServer, DeviceLinkDirectory, InMemoryTokenStore) {
        let dir = tempDir()
        let url = dir.appendingPathComponent("accounts.yaml")
        try AccountsRegistryFile(fileURL: url).mutate {
            $0.append(Account(serverURL: server, username: "alice", userID: "", displayName: "",
                              addedAt: ts("2026-11-01T00:00:00Z")))
        }
        let tok = InMemoryTokenStore(tokens)
        let store = AccountsStore(fileURL: url, defaults: freshDefaults(), tokens: tok, now: { now })
        store.load()
        let fake = FakeLinkServer()
        let links = DeviceLinkDirectory(url: dir.appendingPathComponent("link"))
        let broker = DeviceLinkBroker(store: store, directory: links, api: fake, pid: 100,
                                      isPIDAlive: { alive.contains($0) }, now: { now })
        return (store, broker, fake, links, tok)
    }

    /// The TUI side of the drop box, for tests.
    private func tuiRequest(_ links: DeviceLinkDirectory, verifier: String, created: Date, pid: Int32 = 200) throws -> String {
        let req = DeviceLink.Request(from: "tui", to: "apple", account: alice,
                                     challenge: DeviceLink.challenge(for: verifier), label: "lumi TUI",
                                     pid: pid, createdAt: created)
        try links.write(req, to: links.requestURL(req.id))
        return req.id
    }

    @Test("requester: missing session → request; TUI answers → redeem with our verifier → signed in")
    func requesterFlow() async throws {
        let (store, broker, fake, links, tokens) = try setup(tokens: [:])
        broker.start(watch: false)
        await broker.scan()
        #expect(FileManager.default.fileExists(atPath: links.presenceURL("apple").path))
        let id = try #require(links.requestIDs().first)
        let req = try #require(links.read(DeviceLink.Request.self, from: links.requestURL(id)))
        #expect(req.from == "apple" && req.to == "tui" && req.pid == 100 && req.account == alice)
        #expect(!String(decoding: try Data(contentsOf: links.requestURL(id)), as: UTF8.self).contains("verifier"))
        #expect(broker.waitingFor == [alice])
        // The TUI (holder) mints a code with its own session.
        let code = try await fake.issueDeviceLink(for: alice, challenge: req.challenge, label: req.label)
        try links.write(DeviceLink.Response(id: id, code: code.code, expiresAt: code.expiresAt!), to: links.responseURL(id))
        await broker.scan()
        #expect(tokens.token(account: alice.keychainAccount) == "linked-alice")
        #expect(store.state(alice).isSignedIn)
        #expect(links.requestIDs().isEmpty && links.responseIDs().isEmpty)
        #expect(broker.waitingFor.isEmpty)
        broker.stop()
        #expect(!FileManager.default.fileExists(atPath: links.presenceURL("apple").path))
    }

    @Test("requester: a code read by another process is useless without our verifier")
    func pkceBinding() async throws {
        let (_, broker, fake, links, _) = try setup(tokens: [:])
        broker.start(watch: false)
        await broker.scan()
        let id = try #require(links.requestIDs().first)
        let req = try #require(links.read(DeviceLink.Request.self, from: links.requestURL(id)))
        let code = try await fake.issueDeviceLink(for: alice, challenge: req.challenge, label: "x")
        await #expect(throws: LumiAPIError.self) {
            _ = try await fake.redeemDeviceLink(serverURL: server, code: code.code,
                                                verifier: DeviceLink.makeVerifier(), label: "thief")
        }
    }

    @Test("requester: denied → opt-out, no new request; no_session → retried only after the registry changes")
    func requesterDenied() async throws {
        let (store, broker, _, links, _) = try setup(tokens: [:])
        broker.start(watch: false)
        await broker.scan()
        var id = try #require(links.requestIDs().first)
        try links.write(DeviceLink.Response(id: id, error: "no_session"), to: links.responseURL(id))
        await broker.scan()
        #expect(links.requestIDs().isEmpty, "exhausted until the registry changes")
        try AccountsRegistryFile(fileURL: store.registry.fileURL).mutate { $0[0].displayName = "Alice" }
        store.reload()
        await broker.scan()
        id = try #require(links.requestIDs().first)
        try links.write(DeviceLink.Response(id: id, error: "denied"), to: links.responseURL(id))
        await broker.scan()
        #expect(store.isLinkOptedOut(alice))
        #expect(links.requestIDs().isEmpty)
    }

    @Test("requester: a session for a different user is refused")
    func userMismatch() async throws {
        let (_, broker, fake, links, tokens) = try setup(tokens: [:])
        fake.userOverride = "mallory"
        broker.start(watch: false)
        await broker.scan()
        let id = try #require(links.requestIDs().first)
        let req = try #require(links.read(DeviceLink.Request.self, from: links.requestURL(id)))
        let code = try await fake.issueDeviceLink(for: alice, challenge: req.challenge, label: "")
        try links.write(DeviceLink.Response(id: id, code: code.code, expiresAt: code.expiresAt!), to: links.responseURL(id))
        await broker.scan()
        #expect(tokens.token(account: alice.keychainAccount) == nil)
        #expect(tokens.allAccounts.isEmpty)
    }

    @Test("holder: a TUI request is never auto-approved; Permitir mints a code bound to its challenge")
    func holderApprove() async throws {
        let now = ts("2026-11-24T10:00:00Z")
        let (_, broker, fake, links, _) = try setup(tokens: ["https://link.test#alice": "app-tok"], now: now)
        broker.start(watch: false)
        let verifier = DeviceLink.makeVerifier()
        let id = try tuiRequest(links, verifier: verifier, created: now)
        await broker.scan()
        #expect(broker.pendingApprovals.map(\.id) == [id])
        #expect(broker.pendingApprovals[0].message == "O lumi no Terminal quer entrar como alice em link.test.")
        #expect(fake.issued.isEmpty, "nothing issued before the user decides")
        #expect(links.responseIDs().isEmpty)
        await broker.approve(id)
        let resp = try #require(links.read(DeviceLink.Response.self, from: links.responseURL(id)))
        #expect(resp.error == nil)
        #expect(fake.issued.first?.1 == DeviceLink.challenge(for: verifier))
        #expect(fake.issued.first?.2 == "lumi TUI")
        // The TUI redeems with its verifier.
        let session = try await fake.redeemDeviceLink(serverURL: server, code: resp.code!, verifier: verifier, label: "lumi TUI")
        #expect(session.user.username == "alice")
        #expect(broker.pendingApprovals.isEmpty)
        await broker.scan()
        #expect(broker.pendingApprovals.isEmpty, "answered requests are not asked again")
    }

    @Test("holder: deny writes denied; no session writes no_session; issue failure writes failed")
    func holderOutcomes() async throws {
        let now = ts("2026-11-24T10:00:00Z")
        let (_, broker, fake, links, tokens) = try setup(tokens: ["https://link.test#alice": "app-tok"], now: now)
        broker.start(watch: false)
        let denyID = try tuiRequest(links, verifier: DeviceLink.makeVerifier(), created: now)
        await broker.scan()
        broker.deny(denyID)
        #expect(links.read(DeviceLink.Response.self, from: links.responseURL(denyID))?.error == "denied")

        fake.failIssue = true
        let failID = try tuiRequest(links, verifier: DeviceLink.makeVerifier(), created: now)
        await broker.scan()
        await broker.approve(failID)
        #expect(links.read(DeviceLink.Response.self, from: links.responseURL(failID))?.error == "failed")

        try tokens.deleteToken(account: alice.keychainAccount)
        let noID = try tuiRequest(links, verifier: DeviceLink.makeVerifier(), created: now)
        await broker.scan()
        #expect(links.read(DeviceLink.Response.self, from: links.responseURL(noID))?.error == "no_session")
        #expect(!broker.pendingApprovals.contains { $0.id == noID })
    }

    @Test("holder: stale requests (> 5 min, requester dead) are ignored and collected; a live requester keeps it valid")
    func expiry() async throws {
        let now = ts("2026-11-24T10:00:00Z")
        let (_, broker, _, links, _) = try setup(tokens: ["https://link.test#alice": "app-tok"], now: now, alive: [300])
        broker.start(watch: false)
        let old = now.addingTimeInterval(-600)
        let deadID = try tuiRequest(links, verifier: DeviceLink.makeVerifier(), created: old, pid: 299)
        let liveID = try tuiRequest(links, verifier: DeviceLink.makeVerifier(), created: old, pid: 300)
        await broker.scan()
        #expect(!FileManager.default.fileExists(atPath: links.requestURL(deadID).path))
        #expect(broker.pendingApprovals.map(\.id) == [liveID])
    }

    @Test("holder: malformed or misaddressed requests are ignored")
    func malformed() async throws {
        let now = ts("2026-11-24T10:00:00Z")
        let (_, broker, _, links, _) = try setup(tokens: ["https://link.test#alice": "app-tok"], now: now)
        broker.start(watch: false)
        var bad = DeviceLink.Request(from: "tui", to: "apple", account: alice, challenge: "short", label: "x",
                                     pid: 1, createdAt: now)
        try links.write(bad, to: links.requestURL(bad.id))
        bad = DeviceLink.Request(from: "apple", to: "apple", account: alice,
                                 challenge: DeviceLink.challenge(for: "v"), label: "x", pid: 1, createdAt: now)
        try links.write(bad, to: links.requestURL(bad.id))
        try Data("{not json".utf8).write(to: links.requestURL("junk"))
        await broker.scan()
        #expect(broker.pendingApprovals.isEmpty)
        #expect(links.responseIDs().isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: links.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }
}
