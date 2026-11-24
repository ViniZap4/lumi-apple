import SwiftUI
import LumiKit
import LumiUI
#if canImport(AppKit)
import AppKit
#endif

// Board / Canvas in any pane (SPEC-PARTE2 §5–6), registered through
// `NoteViewHooks`: kanban → Board | Source, canvas → Canvas | Source. The
// primary pane and every split pane render `StructuredPane`, which wraps
// LumiUI's `StructuredNoteView`:
//   - server notes join the note's live session from the pane shell's
//     pool (`NoteViewContext.acquireSession`) through a DocumentFanout
//     view, so a Board and a Source editor on one note (two panes) edit
//     one replica; the protocol's join rules stay in the host — REST body
//     read-only until the first SyncStep2, "Load file contents" for an
//     uninitialised note;
//   - local notes write through the pooled `EditorState` and save
//     verbatim (no frontmatter rewrite);
//   - file nodes / card links open here, in a split (`⌃w f`, ⌘-click) or
//     in the browser (link nodes);
//   - keys go to the focused pane's board / canvas first
//     (`structuredKeySinks`, see `AppState.routeShellKey`).

extension NoteViewHooks {
    static func registerStructured() {
        // Reading | Edit | Source (SPEC-PARTE2 §5a): Reading is the
        // read-only board / canvas, Edit the interactive one.
        register(.kanban, views: [.reading, .board, .source]) { ctx in AnyView(StructuredPane(context: ctx)) }
        register(.canvas, views: [.reading, .canvas, .source]) { ctx in AnyView(StructuredPane(context: ctx)) }
    }
}

/// A live session seen through one fan-out view: edits reach the other
/// editors on the note; the join state comes from the session.
@MainActor
final class FanoutStructuredSession: StructuredSession {
    let session: OpenNoteSession
    let view: DocumentFanout.View

    init(session: OpenNoteSession, view: DocumentFanout.View) {
        self.session = session
        self.view = view
    }

    var text: String { view.text }
    var isEditable: Bool { view.isEditable }
    var changeHandler: ((DocumentChange) -> Void)? {
        get { view.changeHandler }
        set { view.changeHandler = newValue }
    }
    func applyLocal(_ edits: [TextEdit]) { view.applyLocal(edits) }
    func undo() -> Bool { view.undo() }
    func redo() -> Bool { view.redo() }
    func breakUndoGroup() { view.breakUndoGroup() }
    var phase: EditorSnapshot.Phase { session.phase }
    var hasSynced: Bool { session.hasSynced }
    var emptyAtSync: Bool { session.emptyAtSync }
    var termination: SessionTermination? { session.termination }
    var peers: [PeerPresence] { session.peers }
    var isDestroyed: Bool { session.isDestroyed }
    func initialiseFromFile(_ body: String) -> Bool { session.initialiseFromFile(body) }
}

extension AppState {
    /// Notes offered by the canvas file-node picker (no canvases).
    var structuredNoteRefs: [CanvasNoteRef] {
        explorer.tree.allNotes.compactMap { e in
            let p = e.note?.path ?? e.path
            guard !p.isEmpty, !NoteKind.isCanvasPath(p) else { return nil }
            return CanvasNoteRef(path: p, title: e.name)
        }
    }

    /// Body of a book note by book-relative path (canvas file previews).
    func structuredNoteBody(_ path: String) async -> String? {
        if let doc = localDocs.peek(path) { return doc.currentText }
        switch explorer.source {
        case let .local(root):
            guard let url = try? LumiOpenURL.localNoteURL(path, in: root),
                  let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return FrontmatterParser.split(raw).body
        case .remote:
            guard let row = remoteVaultsStore.notes.first(where: { $0.path == path || $0.id == path }) else { return nil }
            return try? await remoteVaultsStore.noteBody(noteID: row.id)
        case .none:
            return nil
        }
    }

    /// Canvas file nodes and card links (`⏎`/`gf` here, `⌃w f` / ⌘-click
    /// in a vertical split) and link nodes (the browser). Canvas file
    /// paths are book paths (Obsidian), not relative to the canvas.
    func openStructuredLink(_ href: String, _ target: StructuredOpenTarget, from leaf: PaneLeafID?) {
        switch target {
        case .external:
            openExternal(href)
        case .current, .split:
            let where_: LinkOpenWhere = target == .split ? .vsplit : .current
            let path = NoteTree.normalizePath(href)
            if noteExists(path) {
                openNoteIn(path, where: where_, from: leaf)
            } else {
                // A card link (`[[x]]`, `x.md`): the shared link table.
                openLink(href, where: where_, from: leaf)
            }
        }
    }
}

/// Board / Canvas for one pane.
struct StructuredPane: View {
    let context: NoteViewContext
    @Environment(AppState.self) private var appState
    @State private var handle: NoteViewSession?
    @State private var localText: MemoryLiveText?
    @State private var leafKey = UUID()

    var body: some View {
        Group {
            if context.isRemote {
                StructuredNoteView(
                    kind: kind, title: context.title, body: context.text,
                    source: remoteSource,
                    notes: appState.structuredNoteRefs,
                    loadNote: { await appState.structuredNoteBody($0) },
                    motion: appState.motionEnabled,
                    openLink: { context.openStructured($0, $1) },
                    // The pane header / note bar carries Board | Source.
                    onSource: nil,
                    keySink: { context.registerKeys($0) },
                    readOnly: context.view == .reading,
                    onMode: modeRequest
                )
                .id(context.noteID)
            } else if let localText {
                StructuredNoteView(
                    kind: kind, title: context.title, body: localText.read(),
                    source: .local(localText),
                    notes: appState.structuredNoteRefs,
                    loadNote: { await appState.structuredNoteBody($0) },
                    motion: appState.motionEnabled,
                    openLink: { context.openStructured($0, $1) },
                    // The pane header / note bar carries Board | Source.
                    onSource: nil,
                    keySink: { context.registerKeys($0) },
                    readOnly: context.view == .reading,
                    onMode: modeRequest
                )
            } else {
                NoteSkeleton()
            }
        }
        .onAppear(perform: bindLocal)
        .onDisappear {
            if let handle, !context.isRemote { context.releaseSession(handle) }
            handle = nil
            localText = nil
            context.registerKeys(nil)
        }
        .onChange(of: handle?.text ?? "") { _, text in
            // Another pane (the Source editor) changed the local note.
            if let localText, localText.read() != text { localText.replaceExternally(text) }
        }
    }

    private var kind: StructuredKind { context.kind == .canvas ? .canvas : .kanban }

    /// Reading ⇄ Edit from the board's keys (SPEC-PARTE2 §5a).
    private var modeRequest: (StructuredModeKeys.Request) -> Void {
        let ctx = context
        return { r in
            switch r {
            case .edit:
                guard !ctx.isReadOnly else { return }
                ctx.switchView(NoteViewMode.editView(for: ctx.kind, markdown: .live))
            case .reading:
                ctx.switchView(.reading)
            }
        }
    }

    private func bindLocal() {
        guard !context.isRemote, handle == nil, let h = context.acquireSession() else { return }
        handle = h
        let lt = MemoryLiveText(h.text, editable: !context.isReadOnly)
        lt.onWrite = { text in h.writeVerbatim(text) }
        localText = lt
    }

    /// Server notes: the pane shell's pooled session, through a fan-out
    /// view; read-only roles and platforms without a CRDT stay read-only.
    private var remoteSource: StructuredSource {
        guard !context.isReadOnly, LumiCRDT.isSupported else { return .readOnly }
        let ctx = context
        return .session(acquire: {
            guard let h = ctx.acquireSession(), let s = h.structured else {
                return .failure(StructuredSessionError("Live editing is not available for this note."))
            }
            ctx.retain(h)
            return .success(s)
        }, release: { _ in ctx.releaseRetained() })
    }
}

extension AppState {
    /// Shift state for structured-view keys (`KeyStroke` carries none for
    /// Tab / arrows).
    static var shiftHeld: Bool {
        #if canImport(AppKit)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }
}
