import Foundation
import SwiftUI
import LumiKit
import LumiUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// MARK: - View mode (Reading | Live | Source)

extension AppState {
    /// What the open note shows.
    var noteViewMode: NoteViewMode {
        guard isNoteOpen else { return .reading }
        // Board / Canvas notes: their view, or Source while editing.
        let kind = openNoteKind
        if kind != .markdown { return isEditing ? .source : kind.defaultView }
        guard isEditing else { return .reading }
        return preferences.editMode == .live ? .live : .source
    }

    /// Reading / Live / Source from the note bar, `:live`, `:source`,
    /// the palette. Picking Live or Source is remembered as the editing
    /// mode (web parity: `editMode`).
    func setNoteViewMode(_ mode: NoteViewMode) {
        switch mode {
        case .source where openNoteKind != .markdown:
            // Structured Source never changes the markdown edit mode.
            if !isEditing { setEditing(true) }
        case .live, .source:
            let wanted: LumiPreferences.EditMode = mode == .live ? .live : .source
            if preferences.editMode != wanted {
                withMotion(.standard) { preferences.editMode = wanted }
            }
            // The split preview belongs to Source.
            if mode == .live, splitPreviewShown { setSplitPreview(false) }
            if !isEditing { setEditing(true) }
        default:
            setEditing(false)
        }
        syncLayoutContent()
    }

    /// Live Preview options for the editor (the reader's prose style).
    func livePresentation(baseURL: URL?, vaultRoot: URL?) -> EditorPresentation {
        guard preferences.editMode == .live else { return .source }
        let family: MarkdownFontFamily
        switch preferences.readingFontFamily {
        case .system: family = .system
        case .serif: family = .serif
        case .monospace: family = .monospace
        }
        return .live(LivePreviewOptions(scale: preferences.readingScale, fontFamily: family, baseURL: baseURL,
                                        vaultRoot: vaultRoot, readingWidth: preferences.readingWidth))
    }

    /// ⌘-click on a Live Preview link: http(s)/mailto open in the
    /// browser, note links open in the app (inside the book only).
    func openLiveLink(_ link: LiveLink) {
        switch link {
        case let .external(href):
            guard let safe = LivePreview.safeHref(href), let url = URL(string: safe) else { return }
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        case let .note(href):
            guard let from = openNotePath, let path = LivePreview.resolveNoteLink(href, from: from) else {
                showToast("link leaves the book", tone: .warning)
                return
            }
            if !openNote(atPath: path) { showToast("note not found: \(path)", tone: .warning) }
        case .inert:
            break
        }
    }

    /// Open a note of the current book by book-relative path. False when
    /// there is no such note.
    @discardableResult
    func openNote(atPath path: String, edit: Bool? = nil) -> Bool {
        let wantsEdit = edit ?? isEditing
        switch explorer.source {
        case let .local(root):
            let url = root.appendingPathComponent(path)
            guard (try? LumiOpenURL.localNoteURL(path, in: root)) != nil, let session else { return false }
            if editor.isDirty { editor.save() }
            let entry = NoteEntry(url: url, relativePath: path, updatedAt: Date())
            editor.load(noteID: path, at: url, vaultRoot: session.rootURL)
            selectedNoteID = path
            selectedEntry = entry
            editorMode = wantsEdit ? .edit : .view
        case let .remote(vaultID):
            guard let row = remoteVaultsStore.notes.first(where: { $0.path == path || $0.id == path }) else { return false }
            openRemoteNote(id: row.id, vaultID: vaultID, edit: wantsEdit)
        case .none:
            return false
        }
        keymap.reset()
        syncLayoutContent()
        return true
    }

    func openRemoteNote(id: String, vaultID: UUID, edit: Bool) {
        if selectedRemoteNoteID != nil, selectedRemoteNoteID != id {
            remoteVaultsStore.closeOpenNote()
            remoteEditor.reset()
        }
        remoteEditorMode = edit && can("note.write") ? .edit : .view
        selectedRemoteNoteID = id
        let store = remoteVaultsStore
        Task { await store.loadOpenNote(vaultID: vaultID, noteID: id) }
    }
}

// MARK: - Pane tree (layout per book)

extension AppState {
    /// The split preview beside the note (a preview leaf in the tree).
    var splitPreviewShown: Bool { noteLayout.preview(of: noteLayout.mainLeaf) != nil }

    func setSplitPreview(_ on: Bool) {
        guard on != splitPreviewShown else { return }
        withMotion(.standard) {
            noteLayout.setPreview(on, ratio: preferences.splitPreviewRatio)
        }
        // The last choice seeds books that have no layout yet.
        preferences.splitPreview = on
        persistLayout()
    }

    /// The note's share of the source + preview split.
    var splitRatio: Double {
        get { noteLayout.previewRatio() ?? preferences.splitPreviewRatio }
        set {
            noteLayout.setRatio(newValue, for: noteLayout.mainLeaf)
            preferences.splitPreviewRatio = newValue
            persistLayout()
        }
    }

    var splitRatioBinding: Binding<Double> {
        Binding(get: { self.splitRatio }, set: { self.splitRatio = $0 })
    }

    /// Load the book's layout (or start one from the last choices).
    func restoreLayout(for book: Book?) {
        guard let book else {
            noteLayout = PaneTree()
            return
        }
        if let saved = layoutStore.layout(forBook: book.id) {
            noteLayout = saved
        } else {
            var t = PaneTree()
            if preferences.splitPreview { t.setPreview(true, ratio: preferences.splitPreviewRatio) }
            noteLayout = t
        }
    }

    /// Mirror the open note and its view into the main leaf.
    func syncLayoutContent() {
        let content: PaneContent = openNotePath.map { .note(path: $0, view: noteViewMode) } ?? .empty
        let main = noteLayout.mainLeaf
        guard noteLayout.content(main) != content else { return }
        noteLayout.setContent(content, for: main)
        persistLayout()
    }

    func persistLayout() {
        guard let id = openBook?.id else { return }
        layoutStore.save(noteLayout, forBook: id)
    }

    /// `⌃w q` / `⌃w o` / `⌃w =` (and `:only`-like palette commands).
    func performLayout(_ command: PaneCommand) {
        switch command {
        case .close:
            if focusedPane == .preview || (focusedPane == .editor && splitPreviewShown) {
                let wasPreview = focusedPane == .preview
                setSplitPreview(false)
                if wasPreview { focusPane(.editor) }
            } else if isNoteOpen {
                // The last pane closes the note.
                closeNote()
            }
        case .only:
            if splitPreviewShown {
                setSplitPreview(false)
                if focusedPane == .preview { focusPane(.editor) }
            }
        case .equalize:
            if splitPreviewShown { withMotion(.standard) { noteLayout.equalize() } }
            preferences.splitPreviewRatio = 0.5
            persistLayout()
        default:
            break
        }
    }
}

// MARK: - Motion (SPEC-PARTE2 §1)

/// Durations for view changes: 120–220 ms, GPU-friendly properties only.
enum Motion {
    case fast, standard, slow

    var duration: Double {
        switch self {
        case .fast: return 0.12
        case .standard: return 0.18
        case .slow: return 0.22
        }
    }

    var animation: Animation { .smooth(duration: duration) }

    /// System Reduce Motion.
    @MainActor static var systemReduceMotion: Bool {
        #if canImport(AppKit)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }
}

extension AppState {
    /// Motion is on: the app setting, the "animate" preference and the
    /// system all allow it.
    var motionEnabled: Bool {
        preferences.contentAnimations && !preferences.reduceMotion && !Motion.systemReduceMotion
    }

    /// The animation for `kind`, or nil (instant) under Reduce Motion.
    func animation(_ kind: Motion = .standard) -> Animation? {
        motionEnabled ? kind.animation : nil
    }

    /// A transition that degrades to `.identity` under Reduce Motion.
    func transition(_ t: AnyTransition) -> AnyTransition {
        motionEnabled ? t : .identity
    }

    func withMotion(_ kind: Motion = .standard, _ body: () -> Void) {
        if let a = animation(kind) { withAnimation(a, body) } else { body() }
    }
}

// MARK: - lumi:// (SPEC-PARTE2 §8)

extension AppState {
    /// Open a `lumi://open` link: validate, select the book, open the
    /// note, bring the window forward. Anything unknown is a toast —
    /// accounts, servers and books are never added from a link.
    func handleOpenURL(_ url: URL) {
        let request: LumiOpenURL.Request
        let target: LumiOpenURL.Target
        do {
            request = try LumiOpenURL.parse(url)
            let known = Set(accounts.accounts.map(\.key))
            let signedIn = Set(known.filter { accounts.state($0).isSignedIn })
            target = try LumiOpenURL.resolve(request, books: books.books, knownAccounts: known, signedIn: signedIn)
        } catch {
            showToast("lumi:// — \((error as? LumiOpenURL.Failure)?.description ?? "invalid link")", tone: .error)
            return
        }
        #if canImport(AppKit)
        NSApp.activate()
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        #endif
        Task { @MainActor in
            if openBook?.id != target.book.id { await selectBook(target.book) }
            guard let note = target.note else {
                if isNoteOpen { closeNote() }
                return
            }
            switch target.book.kind {
            case .local:
                guard let root = session?.rootURL else {
                    showToast("lumi:// — the book's folder is unavailable", tone: .error)
                    return
                }
                do {
                    _ = try LumiOpenURL.localNoteURL(note, in: root)
                } catch {
                    showToast("lumi:// — \((error as? LumiOpenURL.Failure)?.description ?? "invalid link")", tone: .error)
                    return
                }
                if !openNote(atPath: note, edit: false) { showToast("lumi:// — note not found", tone: .error) }
            case .bound:
                guard let vault = target.book.vaultUUID else { return }
                if remoteVaultsStore.notes.contains(where: { $0.id == note }) {
                    openRemoteNote(id: note, vaultID: vault, edit: false)
                    syncLayoutContent()
                } else if !openNote(atPath: note, edit: false) {
                    showToast("lumi:// — note not found in “\(target.book.name)”", tone: .error)
                }
            }
        }
    }
}

// MARK: - Note view registry

/// How the note area renders a note.
enum NoteRoute: Equatable {
    case reader
    case editor(live: Bool)
    /// Kanban Board / JSON Canvas (`StructuredNoteHost.swift`).
    case structured(NoteKind)
}

extension AppState {
    /// Views per note kind. Markdown: Reading | Live | Source. Kanban and
    /// canvas register here in the next batch (Board, Canvas); until
    /// then they open with markdown's views.
    @MainActor static let noteViews: NoteViewRegistry<NoteRoute> = {
        var r = NoteViewRegistry<NoteRoute>()
        r.register(.markdown, views: NoteKind.markdown.views) { view in
            switch view {
            case .live: return .editor(live: true)
            case .source: return .editor(live: false)
            default: return .reader
            }
        }
        for kind in [NoteKind.kanban, .canvas] {
            r.register(kind, views: kind.views) { $0 == .source ? .editor(live: false) : .structured(kind) }
        }
        return r
    }()

    var openNoteKind: NoteKind {
        guard let path = openNotePath else { return .markdown }
        if selectedEntry != nil {
            // Local: the editor holds the body; the flag is in the frontmatter.
            return NoteKind.resolve(path: path, frontmatterText: editor.frontmatter.unknownLines.joined(separator: "\n"),
                                    text: editor.currentText)
        }
        let row = selectedRemoteNoteID.flatMap { id in remoteVaultsStore.notes.first { $0.id == id } }
        return NoteKind.resolve(path: path, kind: row?.kind, text: openNoteText)
    }

    /// Views the note bar offers for the open note.
    var openNoteViews: [NoteViewMode] { Self.noteViews.views(for: openNoteKind) }

    /// Route for the open note's current view.
    var noteRoute: NoteRoute {
        Self.noteViews.resolve(openNoteKind, noteViewMode)?.route ?? .reader
    }
}
