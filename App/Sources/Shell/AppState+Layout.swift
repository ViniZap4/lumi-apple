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
        guard isEditing else { return .reading }
        // A pane remembers Live vs Source; new edits take the preference.
        if case let .note(_, view)? = noteLayout.content(noteLayout.mainLeaf), view.isEditing { return view }
        return preferences.editMode == .live ? .live : .source
    }

    /// Reading / Live / Source from the note bar, `:live`, `:source`,
    /// the palette. Picking Live or Source is remembered as the editing
    /// mode (web parity: `editMode`).
    func setNoteViewMode(_ mode: NoteViewMode) {
        switch mode {
        case .live, .source:
            let wanted: LumiPreferences.EditMode = mode == .live ? .live : .source
            if preferences.editMode != wanted {
                withMotion(.standard) { preferences.editMode = wanted }
            }
            if let path = openNotePath { noteLayout.setContent(.note(path: path, view: mode), for: noteLayout.mainLeaf) }
            // The split preview belongs to Source.
            if mode == .live, splitPreviewShown { setSplitPreview(false) }
            if !isEditing { setEditing(true) }
        default:
            setEditing(false)
        }
        syncLayoutContent()
    }

    /// Live Preview options for the editor (the reader's prose style).
    func livePresentation(baseURL: URL?, vaultRoot: URL?, live: Bool? = nil) -> EditorPresentation {
        guard live ?? (noteViewMode == .live) else { return .source }
        let family: MarkdownFontFamily
        switch preferences.readingFontFamily {
        case .system: family = .system
        case .serif: family = .serif
        case .monospace: family = .monospace
        }
        return .live(LivePreviewOptions(scale: preferences.readingScale, fontFamily: family, baseURL: baseURL,
                                        vaultRoot: vaultRoot, readingWidth: preferences.readingWidth))
    }

    /// Open a note of the current book by book-relative path. False when
    /// there is no such note.
    @discardableResult
    func openNote(atPath path: String, edit: Bool? = nil) -> Bool {
        let wantsEdit = edit ?? isEditing
        switch explorer.source {
        case let .local(root):
            let url = root.appendingPathComponent(path)
            guard (try? LumiOpenURL.localNoteURL(path, in: root)) != nil, session != nil else { return false }
            if selectedRemoteNoteID != nil { selectedRemoteNoteID = nil }
            let entry = NoteEntry(url: url, relativePath: path, updatedAt: Date())
            bindPrimaryLocal(path: path, url: url)
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
        secondaryFocus = nil
        paneVim = [:]
        paneEditors = [:]
        paneReaders = [:]
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
        if let path = openNotePath, let book = openBook { bookMemory.noteOpened(path, inBook: book.id) }
        guard noteLayout.content(main) != content else { return }
        noteLayout.setContent(content, for: main)
        persistLayout()
    }

    func persistLayout() {
        guard let id = openBook?.id else { return }
        layoutStore.save(noteLayout, forBook: id)
    }

    /// Layout pane commands: `⌃w q/c o = v s f F Enter < > + -`.
    func performLayout(_ command: PaneCommand) {
        switch command {
        case .close:
            closeFocusedPane()
        case .only:
            onlyPane()
        case .equalize:
            withMotion(.standard) { noteLayout.equalize() }
            preferences.splitPreviewRatio = 0.5
            persistLayout()
        case let .split(axis):
            splitPane(axis)
        case let .follow(target):
            followLinkInFocusedPane(target)
        case let .resize(axis, steps):
            resizeFocusedPane(axis, steps: steps)
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

    /// Springs, not linear (SPEC-PARTE2 §1 "alive"): settle with a hint
    /// of bounce, inside the 120–220 ms budget.
    var animation: Animation {
        switch self {
        case .fast: return .snappy(duration: duration, extraBounce: 0.02)
        case .standard: return .spring(duration: duration, bounce: 0.12)
        case .slow: return .spring(duration: duration, bounce: 0.08)
        }
    }

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
    /// A view registered through `NoteViewHooks` (Board, Canvas, …).
    case custom(NoteViewMode)
}

extension AppState {
    /// Views per note kind. Markdown: Reading | Live | Source. Kanban and
    /// canvas register here in the next batch (Board, Canvas); until
    /// then they open with markdown's views.
    @MainActor static var noteViews: NoteViewRegistry<NoteRoute> = {
        var r = NoteViewRegistry<NoteRoute>()
        r.register(.markdown, views: NoteKind.markdown.views) { view in
            switch view {
            case .live: return .editor(live: true)
            case .source: return .editor(live: false)
            default: return .reader
            }
        }
        return r
    }()

    var openNoteKind: NoteKind {
        guard let path = openNotePath else { return .markdown }
        return NoteKind.detect(path: path, text: String(openNoteText.prefix(2048)))
    }

    /// Views the note bar offers for the open note.
    var openNoteViews: [NoteViewMode] { Self.noteViews.views(for: openNoteKind) }

    /// Route for the open note's current view.
    var noteRoute: NoteRoute {
        Self.noteViews.resolve(openNoteKind, noteViewMode)?.route ?? .reader
    }
}
