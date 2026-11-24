import SwiftUI
import LumiKit
import LumiUI
#if canImport(AppKit)
import AppKit
#endif

// Board / Canvas in the note pane (SPEC-PARTE2 §5–6).
//
// Integration hook for the pane shell: a pane whose route is
// `.structured(kind)` renders `LocalStructuredNote` (local book) or
// `RemoteStructuredNote` (server book). Both wrap LumiUI's
// `StructuredNoteView`; a multi-pane shell only needs to
//   - pass its own `acquireSession` / `releaseSession` (session pool) in
//     `RemoteStructuredNote.source` instead of waiting for the store's
//     single open session, and
//   - route `openStructuredLink(_:_:)`'s `.split` to "open in a split".
// Keys reach the visible board/canvas through `StructuredKeyRouting`
// (see `AppState.routeShellKey`).

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

    /// Canvas file nodes (`gf`, `⌃w f`, Enter) and link nodes.
    func openStructuredLink(_ href: String, _ target: StructuredOpenTarget) {
        switch target {
        case .external:
            guard let url = CanvasBoardModel.safeURL(href) else { return }
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        case .current, .split:
            // `.split` opens in place until the pane shell provides splits.
            if !openNote(atPath: NoteTree.normalizePath(href), edit: false) {
                showToast("note not found: \(href)", tone: .warning)
            }
        }
    }

    /// Board/Canvas → Source.
    func showStructuredSource() { setNoteViewMode(.source) }
}

/// Local book: the editor buffer is the text; every board/canvas change
/// writes through and saves (each op is one discrete minimal edit).
struct LocalStructuredNote: View {
    let kind: NoteKind
    let title: String
    @Environment(AppState.self) private var appState
    @State private var live: MemoryLiveText?

    var body: some View {
        Group {
            if let live {
                StructuredNoteView(
                    kind: kind == .canvas ? .canvas : .kanban,
                    title: title,
                    body: live.read(),
                    source: .local(live),
                    notes: appState.structuredNoteRefs,
                    loadNote: { await appState.structuredNoteBody($0) },
                    motion: appState.motionEnabled,
                    openLink: { appState.openStructuredLink($0, $1) },
                    onSource: { appState.showStructuredSource() }
                )
            } else {
                Color.clear
            }
        }
        .onAppear {
            let lt = MemoryLiveText(appState.editor.currentText)
            let editor = appState.editor
            lt.onWrite = { text in
                editor.currentText = text
                editor.save()
            }
            live = lt
        }
        .onChange(of: appState.editor.currentText) { _, text in
            // Reload / conflict resolution / external change.
            if let live, live.read() != text { live.replaceExternally(text) }
        }
    }
}

/// Server book: join the open note's live session (read-only REST body
/// until the first SyncStep2). Viewers and visionOS stay read-only.
struct RemoteStructuredNote: View {
    let kind: NoteKind
    let noteID: String
    let title: String
    let restBody: String
    let canEdit: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        StructuredNoteView(
            kind: kind == .canvas ? .canvas : .kanban,
            title: title,
            body: restBody,
            source: source,
            notes: appState.structuredNoteRefs,
            loadNote: { await appState.structuredNoteBody($0) },
            motion: appState.motionEnabled,
            openLink: { appState.openStructuredLink($0, $1) },
            onSource: { appState.showStructuredSource() }
        )
        .id(noteID)
    }

    private var source: StructuredSource {
        guard canEdit, LumiCRDT.isSupported else { return .readOnly }
        let store = appState.remoteVaultsStore
        let id = noteID
        return .session(acquire: {
            // The store opens the note's one live session on select;
            // wait for it (pane shells pass their pool instead).
            for _ in 0..<200 {
                if let s = store.openSession, s.noteID == id, !s.isDestroyed { return .success(s) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return .failure(StructuredSessionError("Live editing is not available for this note."))
        }, release: nil)
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
