import Foundation

/// Single-file load + write for notes. Mirrors the behavior of VaultScanner
/// for one path, but exposes the parsed frontmatter and on-disk mtime so the
/// editor can detect external changes and roundtrip unknown frontmatter keys.
public enum NoteFile {
    public struct Loaded: Sendable, Hashable {
        public let note: Note
        public let frontmatter: Frontmatter
        public let mtime: Date

        public init(note: Note, frontmatter: Frontmatter, mtime: Date) {
            self.note = note
            self.frontmatter = frontmatter
            self.mtime = mtime
        }
    }

    public static func load(at url: URL, vaultRoot: URL) throws -> Loaded {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let (frontmatter, body) = FrontmatterParser.split(raw)

        let mtime = (try? attribute(.modificationDate, at: url)) ?? Date()
        let ctime = (try? attribute(.creationDate, at: url)) ?? mtime

        let fileName = url.deletingPathExtension().lastPathComponent
        let resolvedTitle = frontmatter.title ?? fileName
        let resolvedID = frontmatter.id ?? Note.slug(from: resolvedTitle)
        let relativePath = url.path
            .replacingOccurrences(of: vaultRoot.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let note = Note(
            id: resolvedID,
            title: resolvedTitle,
            createdAt: frontmatter.createdAt ?? ctime,
            updatedAt: frontmatter.updatedAt ?? mtime,
            tags: frontmatter.tags,
            path: relativePath,
            content: body
        )
        return Loaded(note: note, frontmatter: frontmatter, mtime: mtime)
    }

    /// Atomic write of frontmatter + body to `url`. Bumps `frontmatter.updatedAt`
    /// to now. Returns the new on-disk mtime so the caller can update its
    /// conflict-detection baseline.
    @discardableResult
    public static func write(
        body: String,
        frontmatter: Frontmatter,
        to url: URL,
        now: Date = Date()
    ) throws -> Date {
        var fm = frontmatter
        fm.updatedAt = now
        let serialized = FrontmatterParser.serialize(fm) + body
        try serialized.write(to: url, atomically: true, encoding: .utf8)
        return (try? attribute(.modificationDate, at: url)) ?? now
    }

    /// True when the on-disk mtime is newer than the loaded baseline (with a
    /// small tolerance for filesystem clock skew). Use before writing to flag
    /// conflicts.
    public static func hasChangedExternally(
        at url: URL,
        sinceLoadedAt loadedMTime: Date,
        tolerance: TimeInterval = 0.5
    ) -> Bool {
        guard let current = try? attribute(.modificationDate, at: url) else {
            return false
        }
        return current > loadedMTime.addingTimeInterval(tolerance)
    }

    private static func attribute(_ key: FileAttributeKey, at url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attrs[key] as? Date else {
            throw LumiError.ioFailure(underlying: "missing \(key.rawValue) attribute")
        }
        return date
    }
}
