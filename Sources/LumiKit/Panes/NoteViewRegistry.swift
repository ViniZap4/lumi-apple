import Foundation

/// Which view renders a note, keyed by its kind (SPEC-PARTE2 §5–6).
/// Generic over the host's `Route` (the App maps routes to SwiftUI
/// views), so the decision stays pure and testable. Markdown registers
/// Reading / Live / Source; kanban registers Board / Source and canvas
/// Canvas / Source (the App's `AppState.noteViews`). An unregistered kind
/// falls back to markdown's views.
public struct NoteViewRegistry<Route> {
    public struct Entry {
        public let views: [NoteViewMode]
        public let route: (NoteViewMode) -> Route
    }

    public struct Resolution {
        public let route: Route
        /// The view actually shown (the requested one, or the kind's
        /// default when the kind does not offer it).
        public let view: NoteViewMode
        /// The kind has no views of its own yet; `fallback`'s are used.
        public let isFallback: Bool
    }

    private var entries: [NoteKind: Entry] = [:]
    public let fallback: NoteKind

    public init(fallback: NoteKind = .markdown) {
        self.fallback = fallback
    }

    public mutating func register(_ kind: NoteKind, views: [NoteViewMode], route: @escaping (NoteViewMode) -> Route) {
        precondition(!views.isEmpty, "a note kind needs at least one view")
        entries[kind] = Entry(views: views, route: route)
    }

    public func isRegistered(_ kind: NoteKind) -> Bool { entries[kind] != nil }

    /// Views offered for `kind`, in toggle order.
    public func views(for kind: NoteKind) -> [NoteViewMode] {
        (entries[kind] ?? entries[fallback])?.views ?? []
    }

    public func resolve(_ kind: NoteKind, _ requested: NoteViewMode) -> Resolution? {
        let own = entries[kind]
        guard let entry = own ?? entries[fallback] else { return nil }
        let view = entry.views.contains(requested) ? requested : entry.views[0]
        return Resolution(route: entry.route(view), view: view, isFallback: own == nil)
    }
}
