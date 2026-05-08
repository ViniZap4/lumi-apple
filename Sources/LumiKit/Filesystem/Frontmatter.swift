import Foundation

/// Note frontmatter, parsed from the YAML block at the top of a markdown file.
/// Mirrors the Go domain.Note frontmatter shape: id, title, created_at,
/// updated_at, tags. We parse a minimal flat YAML by hand (matches the project
/// convention of not pulling a YAML library for simple key/value blocks).
///
/// `unknownLines` carries lines from the original frontmatter that we did not
/// parse into typed fields, so a load → save roundtrip preserves user-defined
/// keys verbatim.
public struct Frontmatter: Sendable, Hashable {
    public var id: String?
    public var title: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var tags: [String]

    /// Lines from the source frontmatter that didn't match a known key. Stored
    /// in the order they appeared, including indented list-item continuations.
    public var unknownLines: [String]

    public init(
        id: String? = nil,
        title: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        tags: [String] = [],
        unknownLines: [String] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
        self.unknownLines = unknownLines
    }

    /// Whether any frontmatter content (typed fields or unknown lines) is set.
    public var isEmpty: Bool {
        id == nil && title == nil && createdAt == nil && updatedAt == nil
            && tags.isEmpty && unknownLines.isEmpty
    }
}

public enum FrontmatterParser {
    /// Split a markdown source into frontmatter and body. If no frontmatter is
    /// present (no leading `---`), returns an empty Frontmatter and the
    /// original string as body.
    public static func split(_ source: String) -> (frontmatter: Frontmatter, body: String) {
        let openers: [String] = ["---\n", "---\r\n"]
        var rest: Substring?
        for opener in openers where source.hasPrefix(opener) {
            rest = source.dropFirst(opener.count)
            break
        }
        guard let rest else {
            return (Frontmatter(), source)
        }

        let closers: [String] = ["\n---\n", "\n---\r\n", "\n---"]
        var endIndex: String.Index?
        var afterIndex: String.Index?
        for closer in closers {
            if let range = rest.range(of: closer) {
                endIndex = range.lowerBound
                afterIndex = range.upperBound
                break
            }
        }
        guard let endIndex, let afterIndex else {
            return (Frontmatter(), source)
        }

        let yamlBlock = String(rest[..<endIndex])
        let body = String(rest[afterIndex...])
        return (parse(yamlBlock), body)
    }

    static func parse(_ yaml: String) -> Frontmatter {
        var fm = Frontmatter()
        var pendingListKey: String?
        var pendingList: [String] = []
        var pendingUnknownKey: String?
        var pendingUnknownItems: [String] = []

        func flushList() {
            if let key = pendingListKey {
                if key == "tags" { fm.tags = pendingList }
                pendingListKey = nil
                pendingList = []
            }
            if let key = pendingUnknownKey {
                fm.unknownLines.append("\(key):")
                fm.unknownLines.append(contentsOf: pendingUnknownItems.map { "  - \($0)" })
                pendingUnknownKey = nil
                pendingUnknownItems = []
            }
        }

        for rawLine in yaml.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if line.hasPrefix("- ") || line.hasPrefix("  - ") {
                let trimmed = line.drop(while: { $0 == " " }).dropFirst(2)
                let value = unquote(String(trimmed).trimmingCharacters(in: .whitespaces))
                if pendingListKey != nil {
                    pendingList.append(value)
                } else if pendingUnknownKey != nil {
                    pendingUnknownItems.append(value)
                } else {
                    fm.unknownLines.append(line)
                }
                continue
            }
            flushList()

            guard let colon = line.firstIndex(of: ":") else {
                fm.unknownLines.append(line)
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if value.isEmpty {
                if key == "tags" {
                    pendingListKey = key
                } else {
                    pendingUnknownKey = key
                }
                continue
            }

            switch key {
            case "id": fm.id = unquote(value)
            case "title": fm.title = unquote(value)
            case "created_at": fm.createdAt = parseDate(value)
            case "updated_at": fm.updatedAt = parseDate(value)
            case "tags": fm.tags = parseInlineList(value)
            default:
                fm.unknownLines.append(line)
            }
        }
        flushList()
        return fm
    }

    /// Render a frontmatter block including the `---` fences. If the
    /// frontmatter is fully empty, returns an empty string so the file body
    /// stands alone.
    public static func serialize(_ fm: Frontmatter) -> String {
        if fm.isEmpty { return "" }
        var out = "---\n"
        if let id = fm.id { out += "id: \(escapeIfNeeded(id))\n" }
        if let title = fm.title { out += "title: \(escapeIfNeeded(title))\n" }
        if let createdAt = fm.createdAt { out += "created_at: \(formatDate(createdAt))\n" }
        if let updatedAt = fm.updatedAt { out += "updated_at: \(formatDate(updatedAt))\n" }
        if !fm.tags.isEmpty {
            out += "tags:\n"
            for tag in fm.tags {
                out += "  - \(escapeIfNeeded(tag))\n"
            }
        }
        for line in fm.unknownLines {
            out += line + "\n"
        }
        out += "---\n"
        return out
    }

    /// Local-timezone ISO 8601 string. Matches the format used by the Go TUI
    /// and server (e.g. `2026-02-16T11:00:00-03:00`). Per-call instantiation
    /// keeps us Sendable-clean under Swift 6.
    public static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if (v.hasPrefix("\"") && v.hasSuffix("\""))
            || (v.hasPrefix("'") && v.hasSuffix("'"))
        {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    private static func escapeIfNeeded(_ s: String) -> String {
        if s.contains(":") || s.contains("#") || s.hasPrefix(" ") || s.hasSuffix(" ") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return s
    }

    private static func parseInlineList(_ value: String) -> [String] {
        var v = value
        if v.hasPrefix("[") && v.hasSuffix("]") {
            v = String(v.dropFirst().dropLast())
        }
        return v.split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func parseDate(_ value: String) -> Date? {
        let v = unquote(value)
        let withFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? Date(v, strategy: withFractional) { return d }
        let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        return try? Date(v, strategy: plain)
    }
}
