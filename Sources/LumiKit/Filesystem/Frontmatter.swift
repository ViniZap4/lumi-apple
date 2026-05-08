import Foundation

/// Note frontmatter, parsed from the YAML block at the top of a markdown file.
/// Mirrors the Go domain.Note frontmatter shape: id, title, created_at,
/// updated_at, tags. We parse a minimal flat YAML by hand (matches the project
/// convention of not pulling a YAML library for simple key/value blocks).
public struct Frontmatter: Sendable, Hashable {
    public var id: String?
    public var title: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var tags: [String]

    public init(
        id: String? = nil,
        title: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
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

        func flushList() {
            guard let key = pendingListKey else { return }
            if key == "tags" { fm.tags = pendingList }
            pendingListKey = nil
            pendingList = []
        }

        for rawLine in yaml.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if line.hasPrefix("- ") || line.hasPrefix("  - ") {
                let trimmed = line.drop(while: { $0 == " " }).dropFirst(2)
                pendingList.append(unquote(String(trimmed).trimmingCharacters(in: .whitespaces)))
                continue
            }
            flushList()

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if value.isEmpty {
                pendingListKey = key
                continue
            }

            switch key {
            case "id": fm.id = unquote(value)
            case "title": fm.title = unquote(value)
            case "created_at": fm.createdAt = parseDate(value)
            case "updated_at": fm.updatedAt = parseDate(value)
            case "tags":
                fm.tags = parseInlineList(value)
            default:
                break
            }
        }
        flushList()
        return fm
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v
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
