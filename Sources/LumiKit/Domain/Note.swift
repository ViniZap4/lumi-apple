import Foundation

/// A note in a vault. Mirrors the shared `domain.Note` shape used by the Go
/// server and TUI: id derived from title, frontmatter-managed timestamps, tags,
/// path relative to the vault root, and the markdown body.
public struct Note: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var tags: [String]
    public var path: String
    public var content: String

    public init(
        id: String,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        tags: [String] = [],
        path: String,
        content: String = ""
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
        self.path = path
        self.content = content
    }
}

public extension Note {
    /// Slugify a title into a note id, matching the rule used by TUI/server:
    /// lowercase, non-alphanumeric runs become single hyphens, trimmed.
    static func slug(from title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(Character(scalar))
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
