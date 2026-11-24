import Foundation

// Which view a note gets: markdown, a kanban board or a canvas — port of
// web-client `lib/note-kind.ts` (`noteViewKind`). Server DTOs carry
// `kind: "markdown" | "canvas"` (CRDT-CLIENT-PROTOCOL §13); older
// servers do not, so the file extension decides.

public extension NoteKind {
    static func isCanvasPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.lowercased().hasSuffix(".canvas")
    }

    /// - Parameters:
    ///   - path: book-relative path (or server path).
    ///   - kind: the server DTO's `kind`, when known. It wins over the
    ///     extension (`x.canvas` with `kind: "markdown"` is markdown).
    ///   - frontmatterText: the raw frontmatter lines, when the caller
    ///     holds them apart from the body (local books, `/content`).
    ///   - text: the text as held — a full file (with frontmatter) or a
    ///     body. A body counts as a board when it carries the plugin's
    ///     `%% kanban:settings` block (server CRDT bodies have no
    ///     frontmatter; Apple-specific fallback, see SPEC-PARTE2 §9).
    static func resolve(path: String?, kind: String? = nil, frontmatterText: String? = nil, text: String? = nil) -> NoteKind {
        if kind == "canvas" || (kind == nil && isCanvasPath(path)) { return .canvas }
        if Kanban.format(frontmatterText: frontmatterText) != nil { return .kanban }
        if let text {
            if Kanban.isKanbanText(text) { return .kanban }
            if Kanban.hasSettingsBlock(text) { return .kanban }
        }
        return .markdown
    }
}
