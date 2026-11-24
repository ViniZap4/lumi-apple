import Foundation
import Testing
@testable import LumiKit

@Suite("lumi:// open links")
struct LumiOpenURLTests {
    static let vault = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    static let server = "https://notes.example.com"
    static let key = AccountKey(serverURL: server, username: "ana")

    static var books: [Book] {
        [
            Book(id: "b1", name: "Team", kind: .bound, serverURL: server, account: "ana", vaultID: vault.uuidString.lowercased(), sort: 10, addedAt: Date()),
            Book(id: "b2", name: "Local", kind: .local, path: "~/Notes/local", sort: 20, addedAt: Date()),
        ]
    }

    private func parse(_ s: String) -> Result<LumiOpenURL.Request, LumiOpenURL.Failure> {
        guard let url = URL(string: s) else { return .failure(.malformed("url")) }
        do { return .success(try LumiOpenURL.parse(url)) } catch { return .failure(error) }
    }

    private func resolve(_ s: String, signedIn: Set<AccountKey> = [key]) -> Result<LumiOpenURL.Target, LumiOpenURL.Failure> {
        switch parse(s) {
        case let .failure(f): return .failure(f)
        case let .success(r):
            do {
                return .success(try LumiOpenURL.resolve(r, books: Self.books, knownAccounts: [Self.key], signedIn: signedIn, home: "/Users/ana"))
            } catch { return .failure(error) }
        }
    }

    @Test("server form parses and resolves to the bound book")
    func server() throws {
        let link = "lumi://open?server=https%3A%2F%2Fnotes.example.com%2F&account=ana&vault=\(Self.vault.uuidString.lowercased())&note=projects%2Froadmap"
        let target = try resolve(link).get()
        #expect(target.book.id == "b1")
        #expect(target.note == "projects/roadmap")
        // Vault UUID is case-insensitive; host form is case-insensitive.
        #expect((try? resolve("LUMI://OPEN?server=https://notes.example.com&account=ana&vault=\(Self.vault.uuidString)").get())?.book.id == "b1")
    }

    @Test("local form resolves only a registered book; ~ and trailing / normalise")
    func local() throws {
        #expect(try resolve("lumi://open?path=/Users/ana/Notes/local/&note=a/b.md").get().book.id == "b2")
        #expect(try resolve("lumi://open?path=~/Notes/local").get().note == nil)
        #expect(resolve("lumi://open?path=/Users/ana/Notes/other") == .failure(.unknownBook))
        #expect(resolve("lumi://open?path=/Users/ana/Notes/local/../local2") == .failure(.unknownBook))
    }

    @Test("unknown servers, accounts and vaults are refused — never added")
    func unknown() {
        let v = Self.vault.uuidString
        #expect(resolve("lumi://open?server=https://evil.example&account=ana&vault=\(v)") == .failure(.unknownBook))
        #expect(resolve("lumi://open?server=https://notes.example.com&account=bob&vault=\(v)") == .failure(.unknownBook))
        #expect(resolve("lumi://open?server=https://notes.example.com&account=ana&vault=\(UUID().uuidString)") == .failure(.unknownBook))
        #expect(resolve("lumi://open?server=https://notes.example.com&account=ana&vault=\(v)", signedIn: []) == .failure(.accountNotSignedIn))
    }

    @Test("malformed links fail closed")
    func malformed() {
        let v = Self.vault.uuidString
        let bad = [
            "https://open?path=/x",                                     // wrong scheme
            "lumi://delete?path=/x",                                    // unknown action
            "lumi://open/extra?path=/x",                                // path component
            "lumi://user@open?path=/x",                                 // userinfo
            "lumi://open?path=/x#frag",                                 // fragment
            "lumi://open?path=/x&path=/y",                              // repeated
            "lumi://open?path=/x&evil=1",                               // unknown key
            "lumi://open?path=relative/dir",                            // relative
            "lumi://open?path=/x&server=https://a.b",                   // mixed forms
            "lumi://open?server=https://a.b&account=ana",               // missing vault
            "lumi://open?server=https://a.b&account=ana&vault=nope",    // not a uuid
            "lumi://open?server=http://public.example.com&account=ana&vault=\(v)", // plain http to a public host
            "lumi://open?server=javascript:alert(1)&account=ana&vault=\(v)",
            "lumi://open?path=",
            "lumi://open?path=/x%00y",
            "lumi://open",
        ]
        for s in bad {
            if case .success = parse(s) { Issue.record("accepted \(s)") }
        }
        let long = "lumi://open?path=/" + String(repeating: "a", count: 5000)
        if case .success = parse(long) { Issue.record("accepted a 5k link") }
    }

    @Test("note paths: traversal and absolute paths are rejected")
    func traversal() {
        for note in ["../secret.md", "a/../../b.md", "/etc/passwd.md", "~/x.md", "a//b.md", "./a.md", "a\\b.md", "notes.txt", "a/b"] {
            let enc = note.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? note
            #expect(parse("lumi://open?path=/Users/ana/Notes/local&note=\(enc)") == .failure(.unsafeNotePath), "\(note)")
        }
        for id in ["../x", "/x", "a/../b", "a\\b"] {
            let enc = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
            #expect(parse("lumi://open?server=https://notes.example.com&account=ana&vault=\(Self.vault.uuidString)&note=\(enc)") == .failure(.unsafeNotePath), "\(id)")
        }
    }

    @Test("local note file must stay inside the book (symlinks resolved) and exist")
    func localFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lumi-open-\(UUID().uuidString)")
        let outside = fm.temporaryDirectory.appendingPathComponent("lumi-out-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("a/n.md"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("s.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let ok = try LumiOpenURL.localNoteURL("a/n.md", in: root)
        #expect(ok.lastPathComponent == "n.md")
        #expect(throws: LumiOpenURL.Failure.noteNotFound) { try LumiOpenURL.localNoteURL("a/missing.md", in: root) }
        #expect(throws: LumiOpenURL.Failure.unsafeNotePath) { try LumiOpenURL.localNoteURL("link/s.md", in: root) }
        #expect(throws: LumiOpenURL.Failure.unsafeNotePath) { try LumiOpenURL.localNoteURL("../x.md", in: root) }
    }
}
