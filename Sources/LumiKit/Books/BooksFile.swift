import Foundation

/// In-memory form of `books.yaml`.
public struct BooksDocument: Sendable, Equatable {
    public var version: Int
    /// TUI-only active pointer. Apple keeps its own active book in
    /// `UserDefaults['lumi.activeBookID']` but MUST preserve this field
    /// verbatim when it rewrites the file.
    public var active: String?
    public var books: [Book]

    public init(version: Int = BooksFile.currentVersion, active: String? = nil, books: [Book] = []) {
        self.version = version
        self.active = active
        self.books = books
    }
}

/// Byte-exact codec for the shared book registry (SPEC-LIVROS §2.3).
///
/// The Apple client and the TUI must emit identical bytes for the same
/// document; both test against `Tests/Fixtures/books/books.v1.yaml`. The
/// canonical writer rules are:
///
/// 1. First line is the header comment (`headerComment`), then
///    `version: 1`, `active: …`, `books:`.
/// 2. `books: []` when the list is empty; otherwise one `  - id: …` item
///    per book with the remaining keys indented four spaces, in the fixed
///    order id, name, kind, server_url, account, vault_id, path, sort,
///    added_at, last_opened_at.
/// 3. Books sorted by `sort` ascending, then `id` bytewise.
/// 4. `id`, `vault_id`, `active`: bare when the value is a canonical
///    lowercase UUID, otherwise a double-quoted string. `kind` bare.
///    `sort` bare integer. `name`, `server_url`, `account`, `path` always
///    double-quoted.
/// 5. Double-quoted escaping: `\` → `\\`, `"` → `\"`, LF → `\n`, TAB → `\t`,
///    CR → `\r`, any other U+0000–U+001F or U+007F → `\u00XX` (uppercase
///    hex). Everything else is raw UTF-8.
/// 6. Timestamps in UTC, `YYYY-MM-DDTHH:MM:SSZ` (fractional seconds
///    truncated). Absent optional values are the literal `null`.
/// 7. LF line endings, exactly one trailing LF.
///
/// The reader is tolerant: comments, CRLF, a BOM, single-quoted or bare
/// scalars, `~`, timezone offsets and fractional seconds are all accepted
/// and normalised on the next write.
public enum BooksFile {
    public static let currentVersion = 1
    public static let headerComment = "# ~/.config/lumi/books.yaml — lumi book registry. Format: SPEC-LIVROS §2.3."

    public enum DecodeError: Error, Equatable, Sendable {
        /// File declares a newer schema. Callers must treat the registry as
        /// read-only so an old client never truncates fields it can't see.
        case unsupportedVersion(Int)
        case malformed(line: Int, reason: String)
    }

    // MARK: Encode

    public static func encode(_ doc: BooksDocument) -> String {
        var out: [String] = []
        out.append(headerComment)
        out.append("version: \(doc.version)")
        out.append("active: \(doc.active.map(idToken) ?? "null")")
        let sorted = doc.books.sorted(by: Book.registryOrder)
        if sorted.isEmpty {
            out.append("books: []")
        } else {
            out.append("books:")
            for b in sorted {
                out.append("  - id: \(idToken(b.id))")
                out.append("    name: \(quoted(b.name))")
                out.append("    kind: \(b.kind.rawValue)")
                out.append("    server_url: \(b.serverURL.map(quoted) ?? "null")")
                out.append("    account: \(b.account.map(quoted) ?? "null")")
                out.append("    vault_id: \(b.vaultID.map(idToken) ?? "null")")
                out.append("    path: \(b.path.map(quoted) ?? "null")")
                out.append("    sort: \(b.sort)")
                out.append("    added_at: \(timestamp(b.addedAt))")
                out.append("    last_opened_at: \(b.lastOpenedAt.map(timestamp) ?? "null")")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public static func timestamp(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let whole = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func idToken(_ s: String) -> String {
        isCanonicalUUID(s) ? s : quoted(s)
    }

    static func isCanonicalUUID(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count == 36 else { return false }
        for (i, c) in bytes.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                if c != UInt8(ascii: "-") { return false }
            } else {
                let isDigit = c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
                let isHex = c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f")
                if !(isDigit || isHex) { return false }
            }
        }
        return true
    }

    static func quoted(_ s: String) -> String {
        var r = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": r += "\\\\"
            case "\"": r += "\\\""
            case "\n": r += "\\n"
            case "\t": r += "\\t"
            case "\r": r += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    r += String(format: "\\u%04X", scalar.value)
                } else {
                    r.unicodeScalars.append(scalar)
                }
            }
        }
        return r + "\""
    }

    // MARK: Decode

    public static func decode(_ text: String) throws(DecodeError) -> BooksDocument {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        var doc = BooksDocument(version: currentVersion, active: nil, books: [])
        var sawVersion = false
        var inBooks = false
        var current: [String: String?]?
        var rows: [[String: String?]] = []

        func flush() {
            if let c = current { rows.append(c) }
            current = nil
        }

        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        for (idx, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let content = line.drop(while: { $0 == " " || $0 == "\t" })
            if content.isEmpty || content.first == "#" { continue }
            let indent = line.count - content.count

            if indent == 0 {
                flush()
                guard let (key, value) = try splitKV(String(content), line: idx + 1) else {
                    throw .malformed(line: idx + 1, reason: "expected key: value")
                }
                inBooks = false
                switch key {
                case "version":
                    guard let v = value, let n = Int(v) else {
                        throw .malformed(line: idx + 1, reason: "version must be an integer")
                    }
                    sawVersion = true
                    doc.version = n
                case "active":
                    doc.active = value.map(normalizeID)
                case "books":
                    // `books:` opens the list; `books: []` is an empty list.
                    inBooks = true
                default:
                    continue // unknown top-level keys are ignored
                }
                continue
            }

            guard inBooks else { continue }
            var item = String(content)
            if item.first == "-" {
                flush()
                current = [:]
                item = String(item.dropFirst().drop(while: { $0 == " " }))
                if item.isEmpty { continue }
            }
            guard current != nil else { continue }
            if let (key, value) = try splitKV(item, line: idx + 1) {
                current?[key] = value
            }
        }
        flush()

        if sawVersion && doc.version > currentVersion {
            throw .unsupportedVersion(doc.version)
        }
        if !sawVersion { doc.version = currentVersion }

        for (i, row) in rows.enumerated() {
            guard let idRaw = row["id"] ?? nil, !idRaw.isEmpty else { continue }
            let serverURL = (row["server_url"] ?? nil).map(ServerURL.normalizedOrRaw)
            let kind: Book.Kind
            if let k = row["kind"] ?? nil, let parsed = Book.Kind(rawValue: k) {
                kind = parsed
            } else {
                kind = serverURL == nil ? .local : .bound
            }
            let book = Book(
                id: normalizeID(idRaw),
                name: (row["name"] ?? nil) ?? "",
                kind: kind,
                serverURL: serverURL,
                account: row["account"] ?? nil,
                vaultID: (row["vault_id"] ?? nil).map(normalizeID),
                path: row["path"] ?? nil,
                sort: (row["sort"] ?? nil).flatMap { Int($0) } ?? (i + 1) * 10,
                addedAt: (row["added_at"] ?? nil).flatMap(parseTimestamp) ?? Date(timeIntervalSince1970: 0),
                lastOpenedAt: (row["last_opened_at"] ?? nil).flatMap(parseTimestamp)
            )
            doc.books.append(book)
        }
        doc.books.sort(by: Book.registryOrder)
        return doc
    }

    /// Lowercase UUID-shaped ids so the writer can emit them bare.
    static func normalizeID(_ s: String) -> String {
        if UUID(uuidString: s) != nil { return s.lowercased() }
        return s
    }

    public static func parseTimestamp(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? fractional.parse(s) { return d }
        // Space separator / offset variants: fall back to ISO8601DateFormatter.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Split `key: value` and unquote the value. Returns nil value for YAML
    /// null spellings. Returns nil for lines that aren't key/value.
    static func splitKV(_ s: String, line: Int) throws(DecodeError) -> (String, String?)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let key = s[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let rest = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (key, try scalar(rest, line: line))
    }

    static func scalar(_ raw: String, line: Int) throws(DecodeError) -> String? {
        if raw.hasPrefix("\"") { return try doubleQuoted(raw, line: line) }
        if raw.hasPrefix("'") {
            var inner = raw.dropFirst()
            guard let end = singleQuoteEnd(inner) else {
                throw .malformed(line: line, reason: "unterminated single-quoted string")
            }
            inner = inner[..<end]
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        // Bare scalar: strip a trailing ` # comment`.
        var bare = raw
        if let hash = bare.range(of: " #") { bare = String(bare[..<hash.lowerBound]) }
        bare = bare.trimmingCharacters(in: .whitespaces)
        switch bare {
        case "", "~", "null", "Null", "NULL": return nil
        case "[]": return "" // `books: []`
        default: return bare
        }
    }

    private static func singleQuoteEnd(_ s: Substring) -> Substring.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "'" {
                let next = s.index(after: i)
                if next < s.endIndex && s[next] == "'" {
                    i = s.index(after: next)
                    continue
                }
                return i
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func doubleQuoted(_ raw: String, line: Int) throws(DecodeError) -> String {
        var out = String.UnicodeScalarView()
        var it = raw.unicodeScalars.dropFirst().makeIterator()
        while let c = it.next() {
            if c == "\"" { return String(out) }
            guard c == "\\" else { out.append(c); continue }
            guard let e = it.next() else { break }
            switch e {
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "/": out.append("/")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\u{0}")
            case "x", "u", "U":
                let count = e == "x" ? 2 : (e == "u" ? 4 : 8)
                var hex = ""
                for _ in 0..<count { if let h = it.next() { hex.unicodeScalars.append(h) } }
                guard let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) else {
                    throw .malformed(line: line, reason: "bad escape \\\(e)\(hex)")
                }
                out.append(s)
            default:
                throw .malformed(line: line, reason: "unknown escape \\\(e)")
            }
        }
        throw .malformed(line: line, reason: "unterminated double-quoted string")
    }
}
