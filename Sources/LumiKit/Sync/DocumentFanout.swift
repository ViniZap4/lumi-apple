import Foundation

/// Lets several editors share one collaborative document (two panes on
/// the same note, SPEC-PARTE2 §3). A `CollaborativeDocument` has a single
/// `changeHandler` slot and never echoes local edits, so two editors bound
/// straight to it would diverge. The hub owns the slot and hands each
/// editor its own `View`: a view's local edits go to the document once and
/// reach the sibling views as remote edits; the document's own changes
/// reach every view; an undo reaches its originator as `.undo` and the
/// others as `.remote`.
@MainActor
public final class DocumentFanout {
    public let document: CollaborativeDocument
    private var views: [WeakView] = []
    private weak var undoOrigin: View?

    private struct WeakView { weak var view: View? }

    public init(document: CollaborativeDocument) {
        self.document = document
        document.changeHandler = { [weak self] change in self?.broadcast(change) }
    }

    /// A document for one more editor. Keep it alive as long as the
    /// editor (the editor holds it weakly).
    public func makeView() -> View {
        let v = View(hub: self)
        views.removeAll { $0.view == nil }
        views.append(WeakView(view: v))
        return v
    }

    public var viewCount: Int { views.filter { $0.view != nil }.count }

    /// Apply edits that come from outside every editor (a task toggled
    /// in a reader pane): into the document, and to every editor.
    public func applyExternal(_ edits: [TextEdit]) {
        guard !edits.isEmpty else { return }
        document.applyLocal(edits)
        for w in views { w.view?.changeHandler?(.remote(edits)) }
    }

    fileprivate func local(_ edits: [TextEdit], from origin: View) {
        document.applyLocal(edits)
        for w in views where w.view !== origin { w.view?.changeHandler?(.remote(edits)) }
    }

    fileprivate func undo(_ redo: Bool, from origin: View) -> Bool {
        undoOrigin = origin
        defer { undoOrigin = nil }
        return redo ? document.redo() : document.undo()
    }

    private func broadcast(_ change: DocumentChange) {
        for w in views {
            guard let v = w.view else { continue }
            if case let .undo(edits) = change, let origin = undoOrigin, v !== origin {
                v.changeHandler?(.remote(edits))
            } else {
                v.changeHandler?(change)
            }
        }
    }

    /// One editor's handle on the shared document.
    @MainActor
    public final class View: CollaborativeDocument {
        private weak var hub: DocumentFanout?
        private let document: CollaborativeDocument
        public var changeHandler: ((DocumentChange) -> Void)?

        fileprivate init(hub: DocumentFanout) {
            self.hub = hub
            self.document = hub.document
        }

        public var text: String { document.text }
        public var isEditable: Bool { document.isEditable }

        public func applyLocal(_ edits: [TextEdit]) {
            if let hub { hub.local(edits, from: self) } else { document.applyLocal(edits) }
        }

        @discardableResult public func undo() -> Bool { hub?.undo(false, from: self) ?? document.undo() }
        @discardableResult public func redo() -> Bool { hub?.undo(true, from: self) ?? document.redo() }
        public func breakUndoGroup() { document.breakUndoGroup() }
    }
}
