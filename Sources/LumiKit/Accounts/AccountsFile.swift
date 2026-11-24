import Foundation

/// In-memory form of `accounts.yaml`.
public struct AccountsDocument: Sendable, Equatable {
    /// Format version found on disk (1 when the file had none). The writer
    /// always emits `AccountsFile.currentVersion`.
    public var sourceVersion: Int
    public var accounts: [Account]

    public init(sourceVersion: Int = AccountsFile.currentVersion, accounts: [Account] = []) {
        self.sourceVersion = sourceVersion
        self.accounts = accounts
    }
}

/// Byte-exact codec for the shared account registry (SPEC-LIVROS §8.3).
///
/// The app and the TUI emit identical bytes for the same document; both
/// test against `Tests/Fixtures/accounts/accounts.v3.yaml`. Writer rules:
///
/// 1. Header comment, `version: 3`, `accounts:` (`accounts: []` when empty).
/// 2. One `  - server: …` item per account, the other keys indented four
///    spaces, in the fixed order server, username, user_id, display_name,
///    web_origin, added_at, expires_at, signed_out_at.
/// 3. Accounts sorted by `added_at` (whole seconds), then `server`, then
///    `username`, both bytewise.
/// 4. `server`, `username`, `display_name` always double-quoted;
///    `web_origin` quoted or `null`; `user_id` bare when a canonical
///    lowercase UUID, quoted otherwise, `null` when empty.
/// 5. Escaping, timestamps, LF and the single trailing LF as in books.yaml.
///
/// The reader is tolerant and also reads the TUI's v1/v2 files (yaml.v3
/// output, `server` or `server_url`, `token:` ignored — the app never reads
/// a TUI token).
public enum AccountsFile {
    public static let currentVersion = 3
    public static let headerComment = "# ~/.config/lumi/accounts.yaml — lumi account registry, no secrets. Format: SPEC-LIVROS §8.3."

    public typealias DecodeError = BooksFile.DecodeError

    // MARK: Encode

    public static func encode(_ accounts: [Account]) -> String {
        var out: [String] = [headerComment, "version: \(currentVersion)"]
        let sorted = canonicalOrder(accounts)
        if sorted.isEmpty {
            out.append("accounts: []")
        } else {
            out.append("accounts:")
            for a in sorted {
                out.append("  - server: \(BooksFile.quoted(a.serverURL))")
                out.append("    username: \(BooksFile.quoted(a.username))")
                out.append("    user_id: \(a.userID.isEmpty ? "null" : BooksFile.idToken(a.userID))")
                out.append("    display_name: \(BooksFile.quoted(a.displayName))")
                out.append("    web_origin: \(a.webOrigin.flatMap { $0.isEmpty ? nil : BooksFile.quoted($0) } ?? "null")")
                out.append("    added_at: \(BooksFile.timestamp(a.addedAt))")
                out.append("    expires_at: \(a.expiresAt.map(BooksFile.timestamp) ?? "null")")
                out.append("    signed_out_at: \(a.signedOutAt.map(BooksFile.timestamp) ?? "null")")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Canonical ordering: added_at (whole seconds), server, username.
    public static func canonicalOrder(_ accounts: [Account]) -> [Account] {
        accounts.sorted { l, r in
            let ls = floor(l.addedAt.timeIntervalSince1970), rs = floor(r.addedAt.timeIntervalSince1970)
            if ls != rs { return ls < rs }
            if l.serverURL != r.serverURL { return bytewiseLess(l.serverURL, r.serverURL) }
            return bytewiseLess(l.username, r.username)
        }
    }

    static func bytewiseLess(_ a: String, _ b: String) -> Bool {
        Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
    }

    // MARK: Decode

    public static func decode(_ text: String) throws(DecodeError) -> AccountsDocument {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        var version: Int?
        var inAccounts = false
        var current: [String: String?]?
        var rows: [[String: String?]] = []

        func flush() {
            if let c = current { rows.append(c) }
            current = nil
        }

        let lines = body.split(omittingEmptySubsequences: false,
                               whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        for (idx, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let content = line.drop(while: { $0 == " " || $0 == "\t" })
            if content.isEmpty || content.first == "#" { continue }
            let indent = line.count - content.count
            if indent == 0 {
                flush()
                guard let (key, value) = try BooksFile.splitKV(String(content), line: idx + 1) else {
                    throw .malformed(line: idx + 1, reason: "expected key: value")
                }
                inAccounts = false
                switch key {
                case "version":
                    guard let v = value, let n = Int(v) else {
                        throw .malformed(line: idx + 1, reason: "version must be an integer")
                    }
                    version = n
                case "accounts":
                    inAccounts = true
                default:
                    continue
                }
                continue
            }
            guard inAccounts else { continue }
            var item = String(content)
            if item.first == "-" {
                flush()
                current = [:]
                item = String(item.dropFirst().drop(while: { $0 == " " }))
                if item.isEmpty { continue }
            }
            guard current != nil else { continue }
            if let (key, value) = try BooksFile.splitKV(item, line: idx + 1) {
                current?[key] = value
            }
        }
        flush()

        let source = version ?? 1
        if source > currentVersion { throw .unsupportedVersion(source) }

        var out: [Account] = []
        var index: [AccountKey: Int] = [:]
        for row in rows {
            let server = (row["server"] ?? nil) ?? (row["server_url"] ?? nil)
            guard let server, !server.isEmpty, let user = row["username"] ?? nil, !user.isEmpty else { continue }
            let acc = Account(
                serverURL: server,
                username: user,
                userID: ((row["user_id"] ?? nil)).map(BooksFile.normalizeID) ?? "",
                displayName: (row["display_name"] ?? nil) ?? "",
                addedAt: (row["added_at"] ?? nil).flatMap(parseTime) ?? Date(timeIntervalSince1970: 0),
                expiresAt: (row["expires_at"] ?? nil).flatMap(parseTime),
                webOrigin: (row["web_origin"] ?? nil).flatMap { $0.isEmpty ? nil : $0 },
                signedOutAt: (row["signed_out_at"] ?? nil).flatMap(parseTime)
            )
            // Duplicate key: the later added_at wins; a tie goes to the
            // later row in the file.
            if let i = index[acc.key] {
                if floor(acc.addedAt.timeIntervalSince1970) >= floor(out[i].addedAt.timeIntervalSince1970) {
                    out[i] = acc
                }
            } else {
                index[acc.key] = out.count
                out.append(acc)
            }
        }
        return AccountsDocument(sourceVersion: source, accounts: canonicalOrder(out))
    }

    /// Timestamps truncated to whole seconds, so a decoded document
    /// compares equal to what the writer emits. Go's zero time (year 1,
    /// from an old yaml.v3 writer) reads as absent.
    static func parseTime(_ s: String) -> Date? {
        guard let d = BooksFile.parseTimestamp(s) else { return nil }
        let t = floor(d.timeIntervalSince1970)
        if t < -62_000_000_000 { return nil }
        return Date(timeIntervalSince1970: t)
    }
}
