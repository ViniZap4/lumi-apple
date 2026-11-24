import SwiftUI
import LumiKit
import LumiUI

// MARK: - Note view registration hook (SPEC-PARTE2 §5, §6)
//
// Kinds other than markdown (kanban boards, JSON canvases, …) register
// their views here. A pane renders whatever the registry resolves for its
// note's kind and view, and offers a view switch whenever the kind has
// more than one view:
//
//     NoteViewHooks.register(.kanban, views: [.board, .source]) { ctx in
//         AnyView(KanbanBoardView(context: ctx))
//     }
//
// `.source` always maps to the built-in vim editor; every other view of
// the kind is built by `make`. Call `register` from
// `NoteViewHooks.registerBuiltIns()` (run once at launch).

/// What a registered note view gets (web `NoteViewProps`).
struct NoteViewContext {
    /// The view being rendered (`.board`, `.canvas`, …).
    let view: NoteViewMode
    let kind: NoteKind
    /// Book-relative path (`boards/q3.md`, `maps/plan.canvas`).
    let notePath: String
    /// Server note id (bound books) or the path (local books).
    let noteID: String
    let title: String
    /// Latest known text (local buffer, live replica or REST body).
    let text: String
    /// This pane has the keyboard.
    let isFocused: Bool
    let isReadOnly: Bool
    /// A server note (live session) rather than a local file.
    let isRemote: Bool
    /// Follow a link written in this note (same table as the reader).
    let openLink: @MainActor (String, LinkOpenWhere) -> Void
    /// Join (or share) the note's document. Edits MUST go through it as
    /// minimal ranged edits (CRDT-safe). nil when editing is impossible.
    let acquireSession: @MainActor () -> NoteViewSession?
    let releaseSession: @MainActor (NoteViewSession) -> Void
    /// Switch this pane to another view (Board ⇄ Source).
    let switchView: @MainActor (NoteViewMode) -> Void
    /// Open a book path / card link from a structured view: here, in a
    /// vertical split, or (link nodes) in the browser.
    let openStructured: @MainActor (String, StructuredOpenTarget) -> Void
    /// The view's key handler while it shows (nil when it goes). Keys
    /// reach it only while its pane has the keyboard.
    let registerKeys: @MainActor (((StructuredKey) -> Bool)?) -> Void
    /// Keep / drop a session handle for the life of a structured host.
    let retain: @MainActor (NoteViewSession) -> Void
    let releaseRetained: @MainActor () -> Void
}

/// A note's shared document for a registered view. Local notes edit the
/// pooled buffer (and save); server notes edit the live replica through
/// a fan-out view, so other panes' editors see every change.
@MainActor
final class NoteViewSession {
    let key: String
    let local: EditorState?
    /// Server notes: the live session seen through this view's fan-out
    /// (with the join state the structured host needs).
    let structured: (any StructuredSession)?
    /// The collaborative document (server notes) — bind an editor to it
    /// or call `apply`. Set `document.changeHandler` to hear remote edits.
    let document: CollaborativeDocument?
    fileprivate let release: () -> Void

    init(key: String, local: EditorState?, document: CollaborativeDocument?, structured: (any StructuredSession)? = nil,
         release: @escaping () -> Void) {
        self.key = key
        self.local = local
        self.document = document
        self.structured = structured
        self.release = release
    }

    /// Local notes: replace the whole text and save it verbatim.
    func writeVerbatim(_ text: String) {
        guard let local, local.currentText != text else { return }
        local.currentText = text
        local.save()
    }

    var text: String { document?.text ?? local?.currentText ?? "" }
    var isEditable: Bool { document?.isEditable ?? (local != nil) }

    /// Apply sequential ranged edits (UTF-16) in one change.
    func apply(_ edits: [TextEdit]) {
        guard !edits.isEmpty else { return }
        if let document {
            document.applyLocal(edits)
        } else if let local {
            local.currentText = TextEdit.apply(edits, to: local.currentText)
            local.save()
        }
    }
}

@MainActor
enum NoteViewHooks {
    typealias Builder = @MainActor (NoteViewContext) -> AnyView

    private static var builders: [NoteKind: Builder] = [:]
    private static var didRegisterBuiltIns = false

    /// Register the views of `kind`. `views` in toggle order (the first is
    /// the default); include `.source` to offer the markdown editor.
    static func register(_ kind: NoteKind, views: [NoteViewMode], make: @escaping Builder) {
        builders[kind] = make
        AppState.noteViews.register(kind, views: views) { view in
            switch view {
            case .source: return .editor(live: false)
            case .live: return .editor(live: true)
            case .reading: return .reader
            default: return .custom(view)
            }
        }
    }

    /// Kinds shipped with the app. The kanban / canvas views add their
    /// `register` lines here.
    static func registerBuiltIns() {
        guard !didRegisterBuiltIns else { return }
        didRegisterBuiltIns = true
        registerStructured()
    }

    static func view(_ context: NoteViewContext) -> AnyView? {
        builders[context.kind].map { $0(context) }
    }
}

extension AppState {
    /// Build the context a registered view gets in pane `leaf`.
    func noteViewContext(view: NoteViewMode, kind: NoteKind, path: String, leaf: PaneLeafID, text: String) -> NoteViewContext {
        let remoteRow = remoteVaultsStore.notes.first { $0.path == path || $0.id == path }
        let noteID = explorer.isLocal ? path : (remoteRow?.id ?? path)
        let title = remoteRow?.title.isEmpty == false ? remoteRow!.title : NoteTree.stem(path)
        let owner = "view\(leaf.raw)"
        return NoteViewContext(
            view: view, kind: kind, notePath: path, noteID: noteID, title: title, text: text,
            isFocused: focusedLeaf == leaf, isReadOnly: !canWritePane(path), isRemote: !explorer.isLocal,
            openLink: { [weak self] href, target in self?.openLink(href, where: target, from: leaf) },
            acquireSession: { [weak self] in self?.acquireNoteViewSession(path: path, owner: owner) },
            releaseSession: { $0.release() },
            switchView: { [weak self] v in self?.setPaneView(leaf, v) },
            openStructured: { [weak self] href, target in self?.openStructuredLink(href, target, from: leaf) },
            registerKeys: { [weak self] handler in self?.structuredKeySinks[leaf] = handler },
            retain: { [weak self] h in
                self?.noteViewHandles[owner]?.release()
                self?.noteViewHandles[owner] = h
            },
            releaseRetained: { [weak self] in
                self?.noteViewHandles[owner]?.release()
                self?.noteViewHandles[owner] = nil
            }
        )
    }

    func acquireNoteViewSession(path: String, owner: String) -> NoteViewSession? {
        switch explorer.source {
        case let .local(root):
            guard let s = session, let url = try? LumiOpenURL.localNoteURL(path, in: root) else { return nil }
            let doc = localDocs.acquire(path) {
                let e = EditorState()
                e.load(noteID: path, at: url, vaultRoot: s.rootURL)
                return e
            }
            return NoteViewSession(key: path, local: doc, document: nil) { [weak self] in
                self?.localDocs.release(path, session: doc, defer: true)
            }
        case let .remote(vault):
            guard can("note.write"), let row = remoteVaultsStore.notes.first(where: { $0.path == path || $0.id == path }),
                  let live = remoteVaultsStore.acquireSession(vaultID: vault, noteID: row.id, user: awarenessUser) else { return nil }
            let view = docView(for: live, owner: owner)
            return NoteViewSession(key: row.id, local: nil, document: view,
                                   structured: FanoutStructuredSession(session: live, view: view)) { [weak self] in
                self?.fanoutViews = self?.fanoutViews.filter { !$0.key.hasPrefix(owner + "#") } ?? [:]
                self?.remoteVaultsStore.releaseSession(live, defer: true)
            }
        case .none:
            return nil
        }
    }

    /// The local user as published over awareness.
    var awarenessUser: AwarenessUser? {
        guard let account = activeAccount else { return nil }
        return AwarenessUser(username: account.username, displayName: account.displayName)
    }
}
