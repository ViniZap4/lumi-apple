import Foundation

/// Lightweight list-mode descriptor for a markdown file. Carries only the
/// metadata needed to render a row: file URL, vault-relative path, mtime,
/// and a title fallback derived from the filename.
///
/// Notably absent: frontmatter (title, tags, etc.) and body content. Both
/// are loaded on demand when the user opens the note — keeping them out
/// here means a vault with N notes consumes O(N × ~200 bytes) for the
/// listing, not O(N × file-size). For a million-note vault that's the
/// difference between 200 MB and many gigabytes.
public struct NoteEntry: Sendable, Hashable, Identifiable {
    public let url: URL
    /// Path relative to the vault root, using forward slashes. Used as the
    /// stable identifier across renders and for selection state.
    public let relativePath: String
    public let updatedAt: Date

    /// Filename-derived title. Once the editor opens the file, the real
    /// frontmatter title (if present) becomes available via EditorState;
    /// the list happily renders this filename fallback in the meantime.
    public var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    public var id: String { relativePath }

    public init(url: URL, relativePath: String, updatedAt: Date) {
        self.url = url
        self.relativePath = relativePath
        self.updatedAt = updatedAt
    }
}
