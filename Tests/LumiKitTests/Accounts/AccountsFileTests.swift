import Foundation
import Testing
@testable import LumiKit

@Suite("accounts.yaml v3 codec + file IO (SPEC-LIVROS §8.3)")
struct AccountsFileTests {
    @Test("canonical fixture round-trips byte for byte")
    func golden() throws {
        let text = try Fixtures.text("accounts/accounts.v3.yaml")
        let doc = try AccountsFile.decode(text)
        #expect(doc.sourceVersion == 3)
        #expect(doc.accounts.count == 4)
        #expect(AccountsFile.encode(doc.accounts) == text)
        let friend = try #require(doc.accounts.first { $0.serverURL == "https://notes.friend.org/lumi" })
        #expect(friend.displayName == "Alice\tS. — Ação")
        #expect(friend.userID == "legacy-7")
        #expect(friend.signedOutAt == ts("2026-11-23T12:00:00Z"))
        let carol = try #require(doc.accounts.first { $0.username == "carol" })
        #expect(carol.displayName == "Carol \\ admin")
    }

    @Test("empty registry")
    func empty() throws {
        let text = try Fixtures.text("accounts/accounts.v3.empty.yaml")
        #expect(try AccountsFile.decode(text).accounts.isEmpty)
        #expect(AccountsFile.encode([]) == text)
    }

    @Test("non-canonical input (CRLF, comments, quotes, offsets, duplicates) normalises to the fixture")
    func noncanonical() throws {
        let doc = try AccountsFile.decode(try Fixtures.text("accounts/accounts.v3.noncanonical.yaml"))
        #expect(AccountsFile.encode(doc.accounts) == (try Fixtures.text("accounts/accounts.v3.yaml")))
    }

    @Test("TUI v2 file (yaml.v3 output, tokens) reads as v2 rows without tokens")
    func v2() throws {
        let text = try Fixtures.text("accounts/accounts.v2.yaml")
        let doc = try AccountsFile.decode(text)
        #expect(doc.sourceVersion == 2)
        let out = AccountsFile.encode(doc.accounts)
        #expect(out == (try Fixtures.text("accounts/accounts.v2.migrated.yaml")))
        #expect(!out.contains("tok-"))
    }

    @Test("a newer version is refused (read-only)")
    func newer() {
        #expect(throws: BooksFile.DecodeError.unsupportedVersion(4)) {
            try AccountsFile.decode("version: 4\naccounts: []\n")
        }
    }

    @Test("link fixtures decode; PKCE S256 matches RFC 7636")
    func linkFixtures() throws {
        let req = try JSONDecoder().decode(DeviceLink.Request.self, from: try Fixtures.data("accounts/link-request.json"))
        #expect(req.from == "tui" && req.to == "apple" && req.pid == 4242)
        #expect(req.account == AccountKey(serverURL: "https://lumi.work.com", username: "alice"))
        #expect(req.created == ts("2026-11-24T10:00:00Z"))
        #expect(DeviceLink.isValidChallenge(req.challenge))
        let resp = try JSONDecoder().decode(DeviceLink.Response.self, from: try Fixtures.data("accounts/link-response.json"))
        #expect(resp.id == req.id && resp.code?.count == 64 && resp.expires == ts("2026-11-24T10:02:00Z"))
        let denied = try JSONDecoder().decode(DeviceLink.Response.self, from: try Fixtures.data("accounts/link-response-denied.json"))
        #expect(denied.error == "denied" && denied.code == nil)
        struct PKCE: Decodable { let verifier: String; let challenge: String }
        let p = try JSONDecoder().decode(PKCE.self, from: try Fixtures.data("accounts/link-pkce.json"))
        #expect(DeviceLink.challenge(for: p.verifier) == p.challenge)
        #expect(p.challenge == req.challenge)
        let v = DeviceLink.makeVerifier()
        #expect(v.count == 43 && DeviceLink.isValidChallenge(DeviceLink.challenge(for: v)))
    }

    @Test("our request JSON round-trips through the shared field names")
    func requestEncoding() throws {
        let req = DeviceLink.Request(id: "x", from: "apple", to: "tui",
                                     account: AccountKey(serverURL: "https://a.test", username: "bob"),
                                     challenge: "c", label: "Lumi.app", pid: 7, createdAt: ts("2026-11-24T10:00:00Z"))
        let json = String(decoding: try JSONEncoder().encode(req), as: UTF8.self)
        #expect(json.contains("\"created_at\":\"2026-11-24T10:00:00Z\""))
        #expect(try JSONDecoder().decode(DeviceLink.Request.self, from: Data(json.utf8)) == req)
    }
}

@Suite("AccountsRegistryFile — locking, atomic writes, v2 aside")
struct AccountsRegistryFileTests {
    private static func row(_ i: Int) -> Account {
        Account(serverURL: "https://s\(i % 3).test", username: "u\(i)", userID: "", displayName: "",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
    }

    @Test("concurrent writers never lose a row; file stays 0600")
    func concurrentWriters() async throws {
        let url = tempAccountsURL()
        let n = 64
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    // Separate instances, like two processes.
                    let file = AccountsRegistryFile(fileURL: url)
                    _ = try? file.mutate { $0.append(Self.row(i)) }
                }
            }
        }
        let doc = try #require(AccountsRegistryFile(fileURL: url).read().document)
        #expect(doc.accounts.count == n)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("a second process writing under the same lock is serialised with us")
    func crossProcess() throws {
        let url = tempAccountsURL()
        let file = AccountsRegistryFile(fileURL: url)
        try file.mutate { $0.append(Self.row(1)) }
        // Another process (perl's flock(2), as the TUI's Go flock) holds
        // the lock: our write must wait for it.
        let lockPath = file.lockURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "$| = 1; use Fcntl ':flock'; open(my $f, '>>', $ARGV[0]) or die; flock($f, LOCK_EX) or die; print STDOUT \"locked\\n\"; select(undef,undef,undef,0.6);", lockPath]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        _ = out.fileHandleForReading.availableData // wait until the peer holds the lock
        let start = Date()
        try file.mutate { $0.append(Self.row(2)) }
        #expect(Date().timeIntervalSince(start) > 0.3, "mutate waited for the other process's lock")
        p.waitUntilExit()
        #expect(file.read().document?.accounts.count == 2)
    }

    @Test("a TUI v2 file is set aside untouched before the first v3 write")
    func v2Aside() throws {
        let url = tempAccountsURL()
        let v2 = try Fixtures.text("accounts/accounts.v2.yaml")
        try v2.write(to: url, atomically: true, encoding: .utf8)
        let file = AccountsRegistryFile(fileURL: url)
        #expect(file.read().document?.sourceVersion == 2)
        try file.mutate { list in
            list.append(Account(serverURL: "https://new.test", username: "zed", userID: "", displayName: "",
                                addedAt: ts("2026-11-24T00:00:00Z")))
        }
        #expect(try String(contentsOf: file.legacyAsideURL, encoding: .utf8) == v2)
        let mode = try FileManager.default.attributesOfItem(atPath: file.legacyAsideURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("token"))
        #expect(file.read().document?.accounts.map(\.username) == ["bob", "alice", "zed"])
    }

    @Test("a newer format is never rewritten")
    func readOnly() throws {
        let url = tempAccountsURL()
        try "version: 9\naccounts: []\n".write(to: url, atomically: true, encoding: .utf8)
        let file = AccountsRegistryFile(fileURL: url)
        #expect(file.read().readOnlyReason != nil)
        #expect(throws: AccountsRegistryFile.Failure.self) { try file.mutate { _ in } }
        #expect(try String(contentsOf: url, encoding: .utf8) == "version: 9\naccounts: []\n")
    }
}
