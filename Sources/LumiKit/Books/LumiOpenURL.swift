import Foundation

/// `lumi://open` deep links (SPEC-PARTE2 §8), as `lumi open` in the TUI
/// builds them:
///
///     lumi://open?server=<url>&account=<user>&vault=<uuid>[&note=<id>]
///     lumi://open?path=<local book path>[&note=<book-relative path>]
///
/// Parsing is strict and validation only ever *selects* something this
/// device already knows: a signed-in account's bound book, or a
/// registered local book. Nothing is ever added — an unknown server,
/// account, vault or folder is an error the app shows, never a prompt to
/// sign in or link. Pure; the app does the opening.
public enum LumiOpenURL {
    public enum Request: Equatable, Sendable {
        case server(serverURL: String, account: String, vaultID: UUID, note: String?)
        case local(path: String, note: String?)
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case notLumiURL
        case unknownAction(String)
        case malformed(String)
        case unknownBook
        case accountNotSignedIn
        case unsafeNotePath
        case noteNotFound

        public var description: String {
            switch self {
            case .notLumiURL: return "not a lumi:// link"
            case let .unknownAction(a): return "unknown lumi:// action “\(a)”"
            case let .malformed(why): return "invalid lumi:// link: \(why)"
            case .unknownBook: return "that book is not on this device — add it first"
            case .accountNotSignedIn: return "sign in to that server first"
            case .unsafeNotePath: return "invalid note path in the link"
            case .noteNotFound: return "note not found in that book"
            }
        }
    }

    /// What a valid link opens.
    public struct Target: Equatable, Sendable {
        public var book: Book
        /// Server note id, or the book-relative path of a local note.
        public var note: String?
    }

    static let maxLength = 4096
    static let allowedKeys: Set<String> = ["server", "account", "vault", "path", "note"]

    // MARK: Parse

    public static func parse(_ url: URL) throws(Failure) -> Request {
        let raw = url.absoluteString
        guard raw.utf8.count <= maxLength else { throw .malformed("too long") }
        guard url.scheme?.lowercased() == "lumi" else { throw .notLumiURL }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw .malformed("unparsable") }
        // `lumi://open?…` (host form). `lumi:open` / paths are refused.
        let action = (comps.host ?? "").lowercased()
        guard comps.user == nil, comps.password == nil, comps.port == nil, comps.fragment == nil else {
            throw .malformed("unexpected URL parts")
        }
        guard comps.path.isEmpty || comps.path == "/" else { throw .malformed("unexpected path") }
        guard action == "open" else { throw .unknownAction(action) }

        var params: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            guard allowedKeys.contains(item.name) else { throw .malformed("unknown parameter “\(item.name)”") }
            guard params[item.name] == nil else { throw .malformed("repeated parameter “\(item.name)”") }
            guard let v = item.value, !v.isEmpty else { throw .malformed("empty “\(item.name)”") }
            guard !v.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw .malformed("control characters in “\(item.name)”")
            }
            guard v.utf8.count <= 2048 else { throw .malformed("“\(item.name)” too long") }
            params[item.name] = v
        }
        let note = params["note"]

        if let path = params["path"] {
            guard params["server"] == nil, params["account"] == nil, params["vault"] == nil else {
                throw .malformed("path cannot be combined with server/account/vault")
            }
            guard path.hasPrefix("/") || path.hasPrefix("~/") else { throw .malformed("path must be absolute") }
            if let note { try checkRelativeNotePath(note) }
            return .local(path: path, note: note)
        }
        guard let server = params["server"], let account = params["account"], let vault = params["vault"] else {
            throw .malformed("needs server, account and vault — or path")
        }
        let normalized: String
        do { normalized = try ServerURL.normalize(server) } catch { throw .malformed("invalid server URL") }
        guard let id = UUID(uuidString: vault) else { throw .malformed("vault must be a UUID") }
        guard account.count <= 128, !account.contains("/") else { throw .malformed("invalid account") }
        if let note { try checkNoteID(note) }
        return .server(serverURL: normalized, account: account, vaultID: id, note: note)
    }

    /// Book-relative note path: no absolute paths, `..`, `.`, empty
    /// segments, backslashes, `~` or NUL; markdown or canvas only.
    static func checkRelativeNotePath(_ p: String) throws(Failure) {
        guard !p.hasPrefix("/"), !p.hasPrefix("~"), !p.contains("\\"), !p.contains("\0") else { throw .unsafeNotePath }
        let segments = p.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw .unsafeNotePath }
        let lower = p.lowercased()
        guard lower.hasSuffix(".md") || lower.hasSuffix(".markdown") || lower.hasSuffix(".canvas") else { throw .unsafeNotePath }
    }

    /// Server note id: an opaque id or a path-like id; never traversal.
    static func checkNoteID(_ id: String) throws(Failure) {
        guard id.count <= 512, !id.hasPrefix("/"), !id.contains("\\"), !id.contains("\0") else { throw .unsafeNotePath }
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw .unsafeNotePath }
    }

    // MARK: Resolve

    /// Pick the book a request names among what this device has.
    /// - `signedIn`: accounts with a live session; a known but signed-out
    ///   account is `.accountNotSignedIn`.
    /// - `home`: expands `~/` in links and in registry paths.
    public static func resolve(
        _ request: Request,
        books: [Book],
        knownAccounts: Set<AccountKey>,
        signedIn: Set<AccountKey>,
        home: String = NSHomeDirectory()
    ) throws(Failure) -> Target {
        switch request {
        case let .server(serverURL, account, vaultID, note):
            let key = AccountKey(serverURL: serverURL, username: account)
            guard knownAccounts.contains(key) else { throw .unknownBook }
            guard let book = books.first(where: {
                $0.kind == .bound && $0.accountKey == key && $0.vaultUUID == vaultID
            }) else { throw .unknownBook }
            guard signedIn.contains(key) else { throw .accountNotSignedIn }
            return Target(book: book, note: note)
        case let .local(path, note):
            let wanted = canonical(path, home: home)
            guard let book = books.first(where: { b in
                b.kind == .local && b.path.map { canonical($0, home: home) == wanted } == true
            }) else { throw .unknownBook }
            return Target(book: book, note: note)
        }
    }

    /// The note's file inside `root`, or a failure when it escapes the
    /// book (symlinks resolved) or does not exist.
    public static func localNoteURL(_ note: String, in root: URL,
                                    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws(Failure) -> URL {
        try checkRelativeNotePath(note)
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = base.appendingPathComponent(note).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard file.path.hasPrefix(prefix) else { throw .unsafeNotePath }
        guard fileExists(file.path) else { throw .noteNotFound }
        return file
    }

    static func canonical(_ path: String, home: String) -> String {
        var p = path
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = (home as NSString).appendingPathComponent(String(p.dropFirst(2))) }
        var s = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
