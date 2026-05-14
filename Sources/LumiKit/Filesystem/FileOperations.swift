import Foundation

/// Filesystem operations that mutate the vault: create, rename, delete,
/// duplicate, move. Each call is synchronous and atomic at the
/// `FileManager` level. Callers are expected to refresh the parent
/// folder (`FolderNode.reload()`) after a successful operation.
public enum FileOperations {
    public enum Error: Swift.Error, LocalizedError {
        case alreadyExists(URL)
        case emptyName
        case parentMissing(URL)
        case rejected(String)
        case underlying(Swift.Error)

        public var errorDescription: String? {
            switch self {
            case .alreadyExists(let url):
                return "An item named \(url.lastPathComponent) already exists."
            case .emptyName:
                return "Name cannot be empty."
            case .parentMissing(let url):
                return "Folder \(url.lastPathComponent) doesn't exist."
            case .rejected(let reason):
                return reason
            case .underlying(let err):
                return err.localizedDescription
            }
        }
    }

    // MARK: - Create

    /// Creates a new markdown note in `folderURL` with the given title.
    /// File name is the title slugged + `.md`. Body has a minimal
    /// frontmatter block with id / title / created_at / updated_at /
    /// tags, then a single H1 with the title. Returns the file URL.
    @discardableResult
    public static func createNote(in folderURL: URL, title: String) throws -> URL {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.emptyName }
        try ensureDirectory(folderURL)
        let slug = slugify(trimmed)
        let url = uniqueURL(folderURL.appendingPathComponent(slug + ".md"))
        let now = isoNow()
        let frontmatter = """
        ---
        id: \(slug)
        title: \(yamlString(trimmed))
        created_at: \(now)
        updated_at: \(now)
        tags: []
        ---

        # \(trimmed)


        """
        do {
            try frontmatter.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            throw Error.underlying(error)
        }
    }

    /// Creates an empty subfolder inside `parentURL`.
    @discardableResult
    public static func createFolder(in parentURL: URL, name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.emptyName }
        try ensureDirectory(parentURL)
        let url = uniqueURL(parentURL.appendingPathComponent(trimmed))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        } catch {
            throw Error.underlying(error)
        }
    }

    // MARK: - Rename / Move

    /// Renames the item at `oldURL` to `newName` (same parent). For
    /// notes, the `.md` extension is preserved automatically. Returns
    /// the new URL.
    @discardableResult
    public static func rename(at oldURL: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.emptyName }
        let isNote = oldURL.pathExtension.lowercased() == "md"
        let parent = oldURL.deletingLastPathComponent()
        // For notes the rename uses the slugged title as the file
        // stem; the visible title sits in the frontmatter, so we keep
        // the slug there too.
        let finalName: String
        if isNote {
            finalName = slugify(trimmed) + ".md"
        } else {
            finalName = trimmed
        }
        let newURL = parent.appendingPathComponent(finalName)
        if FileManager.default.fileExists(atPath: newURL.path), newURL != oldURL {
            throw Error.alreadyExists(newURL)
        }
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            throw Error.underlying(error)
        }
        if isNote {
            try? updateFrontmatterTitle(at: newURL, newTitle: trimmed)
        }
        return newURL
    }

    /// Moves `sourceURL` into `destinationFolderURL`. Returns the new
    /// URL. Refuses to move a folder into itself or its descendants.
    @discardableResult
    public static func move(_ sourceURL: URL, into destinationFolderURL: URL) throws -> URL {
        let resolvedSrc = sourceURL.standardizedFileURL
        let resolvedDst = destinationFolderURL.standardizedFileURL
        guard !resolvedDst.path.hasPrefix(resolvedSrc.path + "/"),
              resolvedDst.path != resolvedSrc.path
        else { throw Error.rejected("Cannot move a folder into itself.") }
        try ensureDirectory(destinationFolderURL)
        let target = uniqueURL(destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent))
        do {
            try FileManager.default.moveItem(at: sourceURL, to: target)
            return target
        } catch {
            throw Error.underlying(error)
        }
    }

    // MARK: - Delete / Duplicate

    /// Moves the item at `url` to the trash. Returns the trash URL.
    @discardableResult
    public static func delete(at url: URL) throws -> URL {
        var trashURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
            return (trashURL as URL?) ?? url
        } catch {
            throw Error.underlying(error)
        }
    }

    /// Duplicates a note (`.md`). The new file gets " copy" appended
    /// to the title in the frontmatter and a slugged-with-suffix file
    /// stem. Folders aren't duplicated (would recurse — leave for a
    /// follow-up).
    @discardableResult
    public static func duplicateNote(at url: URL) throws -> URL {
        let parent = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        var candidate = parent.appendingPathComponent(stem + "-copy.md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(stem)-copy-\(n).md")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: candidate)
        } catch {
            throw Error.underlying(error)
        }
        // Bump the title + id in the frontmatter so the duplicate is
        // a fresh logical note, not a clone of the original's identity.
        if let raw = try? String(contentsOf: candidate, encoding: .utf8) {
            var updated = raw
            updated = bumpFrontmatterValue(updated, key: "id", to: candidate.deletingPathExtension().lastPathComponent)
            if let existingTitle = readFrontmatterValue(updated, key: "title") {
                let cleanTitle = existingTitle.replacingOccurrences(of: "\"", with: "")
                let newTitle = cleanTitle + " (copy)"
                updated = bumpFrontmatterValue(updated, key: "title", to: yamlString(newTitle))
            }
            try? updated.write(to: candidate, atomically: true, encoding: .utf8)
        }
        return candidate
    }

    // MARK: - Helpers

    /// Slug used as a file stem: lowercase ASCII letters / digits, with
    /// hyphens replacing any other run of characters. Matches the
    /// behavior the TUI / web clients use so notes sync cleanly across
    /// platforms.
    public static func slugify(_ string: String) -> String {
        var out = ""
        var lastDash = false
        for scalar in string.lowercased().unicodeScalars {
            let isAlphaNum = (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            if isAlphaNum {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out += "-"
                lastDash = true
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "note" : out
    }

    private static func ensureDirectory(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw Error.parentMissing(url)
        }
    }

    private static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let parent = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let suffix = ext.isEmpty ? "-\(n)" : "-\(n)"
            let candidate = ext.isEmpty
                ? parent.appendingPathComponent(stem + suffix)
                : parent.appendingPathComponent(stem + suffix).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return f.string(from: Date())
    }

    /// Escapes a string for inclusion in a YAML scalar. We quote if it
    /// contains characters that would change its YAML parsing.
    private static func yamlString(_ s: String) -> String {
        let needsQuotes = s.contains(":")
            || s.contains("#")
            || s.contains("\"")
            || s.contains("\n")
            || s.hasPrefix("-")
            || s.hasPrefix("[")
        if needsQuotes {
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }

    private static func readFrontmatterValue(_ raw: String, key: String) -> String? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstDelim = lines.firstIndex(where: { $0 == "---" }) else { return nil }
        for i in (firstDelim + 1)..<lines.count {
            let line = lines[i]
            if line == "---" { break }
            let prefix = "\(key):"
            if line.hasPrefix(prefix) {
                let v = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return v
            }
        }
        return nil
    }

    private static func bumpFrontmatterValue(_ raw: String, key: String, to newValue: String) -> String {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstDelim = lines.firstIndex(of: "---") else { return raw }
        for i in (firstDelim + 1)..<lines.count {
            if lines[i] == "---" { break }
            if lines[i].hasPrefix("\(key):") {
                lines[i] = "\(key): \(newValue)"
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func updateFrontmatterTitle(at url: URL, newTitle: String) throws {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        let updated = bumpFrontmatterValue(raw, key: "title", to: yamlString(newTitle))
        try? updated.write(to: url, atomically: true, encoding: .utf8)
    }
}
