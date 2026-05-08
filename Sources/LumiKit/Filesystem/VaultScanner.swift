import Foundation

/// Walks a vault directory and produces `Note` records for every `.md` file.
/// Pure I/O — does not start security-scoped access; caller is responsible for
/// wrapping the call in `withScopedAccess`.
public enum VaultScanner {
    public static func scan(at vaultRoot: URL) -> [Note] {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: vaultRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return []
        }

        var notes: [Note] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            if let note = loadNote(at: url, vaultRoot: vaultRoot) {
                notes.append(note)
            }
        }
        notes.sort { $0.updatedAt > $1.updatedAt }
        return notes
    }

    public static func loadNote(at url: URL, vaultRoot: URL) -> Note? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (frontmatter, body) = FrontmatterParser.split(content)

        let fileName = url.deletingPathExtension().lastPathComponent
        let resolvedTitle = frontmatter.title ?? fileName
        let resolvedID = frontmatter.id ?? Note.slug(from: resolvedTitle)

        let resourceValues = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .creationDateKey
        ])
        let mtime = resourceValues?.contentModificationDate ?? Date()
        let ctime = resourceValues?.creationDate ?? mtime

        let relativePath = url.path.replacingOccurrences(of: vaultRoot.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return Note(
            id: resolvedID,
            title: resolvedTitle,
            createdAt: frontmatter.createdAt ?? ctime,
            updatedAt: frontmatter.updatedAt ?? mtime,
            tags: frontmatter.tags,
            path: relativePath,
            content: body
        )
    }
}
