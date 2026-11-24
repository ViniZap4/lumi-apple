import Foundation
import SwiftUI
import LumiKit
import LumiUI

/// What fills the main area. Drives key routing, the top line and the
/// status line.
enum ShellSurface: Equatable {
    case empty
    case explorer
    case reader
    case editor
}

struct ShellToast: Equatable, Identifiable {
    enum Tone: Equatable { case info, success, warning, error }
    let id = UUID()
    var text: String
    var tone: Tone = .info
}

extension AppState {
    // MARK: Surface

    var surface: ShellSurface {
        if selectedEntry != nil { return editorMode == .edit ? .editor : .reader }
        if selectedRemoteNoteID != nil { return remoteEditorMode == .edit ? .editor : .reader }
        if openBook != nil { return .explorer }
        return .empty
    }

    var isNoteOpen: Bool { selectedEntry != nil || selectedRemoteNoteID != nil }

    /// Title of the open note (frontmatter title when known).
    var openNoteTitle: String? {
        if let entry = selectedEntry { return editor.frontmatter.title ?? entry.title }
        if let id = selectedRemoteNoteID {
            let row = remoteVaultsStore.notes.first { $0.id == id }
            if let t = row?.title, !t.isEmpty { return t }
            return id
        }
        return nil
    }

    /// Book-relative path of the open note.
    var openNotePath: String? {
        if let entry = selectedEntry { return entry.relativePath }
        if let id = selectedRemoteNoteID {
            return remoteVaultsStore.notes.first { $0.id == id }?.path ?? id
        }
        return nil
    }

    /// Text of the open note as currently shown (for the word count).
    var openNoteText: String {
        if selectedEntry != nil { return editor.currentText }
        if let id = selectedRemoteNoteID {
            if let s = remoteVaultsStore.openSession, s.noteID == id, s.hasSynced { return s.text }
            if let snap = remoteVaultsStore.openNoteSnapshot, snap.id == id { return snap.text }
            return remoteEditor.currentText
        }
        return ""
    }

    func showToast(_ text: String, tone: ShellToast.Tone = .info) {
        let t = ShellToast(text: text, tone: tone)
        toast = t
        withMotion(.standard) {
            toasts.removeAll { $0.text == text }
            toasts.append(t)
            if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: tone == .error ? 6_000_000_000 : 3_000_000_000)
            guard let self else { return }
            if self.toast?.id == t.id { self.toast = nil }
            self.withMotion(.standard) { self.toasts.removeAll { $0.id == t.id } }
        }
    }

    // MARK: Capabilities

    /// Capability check for the open book. Local books can do everything;
    /// server books match the signed-in member's role capabilities.
    func can(_ capability: String) -> Bool {
        guard let book = openBook else { return false }
        if book.kind == .local { return true }
        guard let account = activeAccount,
              let caps = remoteVaultsStore.capabilities(forUsername: account.username) else { return false }
        let ns = capability.split(separator: ".").first.map { String($0) + ".*" } ?? ""
        return caps.contains { $0 == "*" || $0 == capability || $0 == ns || $0 == "vault.*" }
    }

    /// True when Book settings has anything to show beyond the basics.
    var bookSettingsAvailable: Bool { openBook != nil }

    // MARK: Opening / closing notes

    /// Open the note under an explorer entry.
    func open(_ entry: ExplorerEntry, edit: Bool = false) {
        guard entry.kind == .note, let note = entry.note else { return }
        let wantsEdit = edit || preferences.defaultOpenMode == .edit
        switch explorer.source {
        case let .local(root):
            let url = root.appendingPathComponent(entry.path)
            let ne = NoteEntry(url: url, relativePath: entry.path, updatedAt: note.updatedAt ?? Date())
            guard session != nil else { return }
            bindPrimaryLocal(path: ne.relativePath, url: ne.url)
            selectedNoteID = ne.relativePath
            selectedEntry = ne
            editorMode = wantsEdit ? .edit : .view
            syncLayoutContent()
        case let .remote(vaultID):
            if selectedRemoteNoteID != nil, selectedRemoteNoteID != note.id {
                remoteVaultsStore.closeOpenNote()
                remoteEditor.reset()
            }
            remoteEditorMode = wantsEdit && can("note.write") ? .edit : .view
            selectedRemoteNoteID = note.id
            let store = remoteVaultsStore
            Task { await store.loadOpenNote(vaultID: vaultID, noteID: note.id) }
            Task { await store.learnFrontmatter(noteID: note.id) }
            syncLayoutContent()
        case .none:
            break
        }
        keymap.reset()
    }

    /// Back to the explorer with the cursor on the note that was open.
    func closeNote() {
        let revealID: String?
        if selectedEntry != nil {
            if editor.isDirty { editor.save() }
            revealID = selectedEntry?.relativePath
            selectedEntry = nil
            selectedNoteID = nil
            editorMode = .view
            releasePrimaryLocal()
        } else if let remoteID = selectedRemoteNoteID {
            // Live (CRDT) edits are already on the server; only the REST
            // fallback (visionOS) has anything to save.
            if remoteEditor.isDirty, let vaultID = remoteEditor.vaultID,
               let save = remoteEditor.beginSave(via: remoteVaultsStore.apiClient) {
                let store = remoteVaultsStore
                Task {
                    if let snapshot = await save.value {
                        store.recordSavedSnapshot(snapshot, vaultID: vaultID)
                    }
                }
            }
            revealID = remoteID
            selectedRemoteNoteID = nil
            remoteVaultsStore.closeOpenNote()
            remoteEditor.reset()
            remoteEditorMode = .view
        } else {
            revealID = nil
        }
        if let revealID { explorer.revealPath(revealID) }
        secondaryFocus = nil
        homeCursor = 0
        keymap.reset()
        syncLayoutContent()
    }

    var isEditing: Bool { surface == .editor }

    /// ⌘E / `i` / `e`: reader ⇄ editor for the open note.
    func setEditing(_ on: Bool) {
        if selectedEntry != nil {
            editorMode = on ? .edit : .view
        } else if selectedRemoteNoteID != nil {
            if on && !can("note.write") {
                showToast("read-only — note.write required", tone: .warning)
                return
            }
            remoteEditorMode = on ? .edit : .view
        }
        syncLayoutContent()
    }

    func toggleEditing() {
        if isNoteOpen {
            setEditing(!isEditing)
        } else if let cur = explorer.nav.current, cur.kind == .note {
            open(cur, edit: true)
        }
    }

    // MARK: Books

    func cycleBook(_ delta: Int) {
        let list = BookSwitcherOrder.flattened(books.books)
        guard !list.isEmpty else { return }
        let idx = openBook.flatMap { list.firstIndex(of: $0) } ?? -1
        let next = list[((idx + delta) % list.count + list.count) % list.count]
        Task { await selectBook(next) }
    }

    /// `R`: reload the open book.
    func refreshBook() {
        switch explorer.source {
        case .local:
            explorer.rescanLocal()
            showToast("rescanned")
        case let .remote(vaultID):
            let store = remoteVaultsStore
            Task {
                await store.selectVault(vaultID)
                var pages = 0
                while store.notesHasMore, pages < 200 {
                    await store.loadMoreNotes()
                    pages += 1
                }
            }
        case .none:
            break
        }
    }

    func openPalette(commands: Bool = false) {
        paletteCommandMode = commands
        showPalette = true
        keymap.reset()
    }

    // MARK: Keys

    /// Route one key press. Returns false to let it through (text fields,
    /// the vim editor, sheets).
    func handleShellKey(_ k: KeyStroke) -> Bool {
        let handled = routeShellKey(k)
        let pending = keymap.pendingDisplay
        if shellPending != pending { shellPending = pending }
        return handled
    }

    private func routeShellKey(_ k: KeyStroke) -> Bool {
        if showPalette { return false }
        if hintSession != nil { return handleHintKey(k) }
        if hoverCard != nil, handleHoverKey(k) { return true }
        if showFloatingExplorer, !showHelp { return handleFloatingKey(k) }
        if MarkdownZoom.shared.item != nil {
            if k.command { return false }
            MarkdownZoom.shared.dismiss()
            return true
        }
        if showHelp {
            if k.command { return false }
            showHelp = false
            return true
        }
        if explorer.pendingDelete != nil { return handleDeleteConfirm(k) }
        if explorer.prompt != nil { return false }

        keymap.ctrlHJKLPanes = preferences.ctrlHJKLPanes
        let now = ProcessInfo.processInfo.systemUptime
        // The focused pane's Board / Canvas takes its keys first
        // (SPEC-PARTE2 §5–6): on a canvas `-` zooms out; elsewhere it is
        // the floating explorer.
        // `⌃w` stays the shell's window prefix (⌃w f / ⏎ reach the canvas
        // through `followLinkInFocusedPane`).
        if isNoteOpen, focusedPane != .preview, !paneView(focusedLeaf).isEditing,
           let sink = structuredKeySinks[focusedLeaf], keymap.pendingDisplay.isEmpty,
           !(k.control && k.chars?.lowercased() == "w"),
           let key = StructuredKey(stroke: k, shift: Self.shiftHeld), sink(key) {
            return true
        }
        if let leaf = focusedSecondary {
            // A secondary pane: its editor owns its keys; its reader reads here.
            if paneView(leaf).isEditing, paneEditors[leaf]?.value != nil { return false }
            guard let action = keymap.feed(k, context: .reader, now: now) else { return false }
            return dispatch(action) { self.performSecondaryReader($0, leaf: leaf) }
        }
        let pane = focusedPane
        if pane == .sidebar {
            guard let action = keymap.feed(k, context: .sidebar, now: now) else { return false }
            return dispatch(action) { self.performShared($0) || self.performSidebar($0) }
        }
        if pane == .preview {
            guard let action = keymap.feed(k, context: .preview, now: now) else { return false }
            return dispatch(action) { self.performShared($0) || self.performPreview($0) }
        }
        switch surface {
        case .editor:
            return false
        case .empty:
            guard let action = keymap.feed(k, context: .explorer, now: now) else { return false }
            return dispatch(action) { self.performShared($0) }
        case .explorer:
            // The book home: the floating explorer is the navigation.
            return handleHomeKey(k)
        case .reader:
            guard let action = keymap.feed(k, context: .reader, now: now) else { return false }
            return dispatch(action) { self.performReader($0) }
        }
    }

    /// Pane keys first: `⌃w …` and `⌃h/j/k/l` move focus; with no pane
    /// that way the key is consumed (web parity).
    private func dispatch(_ action: ShellAction, _ perform: (ShellAction) -> Bool) -> Bool {
        switch action {
        case let .pane(command):
            performPane(command)
            return true
        case let .paneKey(direction):
            performPane(.move(direction))
            return true
        default:
            return perform(action)
        }
    }

    private func handleDeleteConfirm(_ k: KeyStroke) -> Bool {
        if k.command { return false }
        if k.chars == "y" || k.chars == "Y" || k.special == .enter {
            confirmDelete()
        } else {
            explorer.pendingDelete = nil
        }
        return true
    }

    /// Keys that mean the same everywhere.
    func performShared(_ action: ShellAction) -> Bool {
        switch action {
        case .pending: return true
        case .palette: openPalette()
        case .command: openPalette(commands: true)
        case .help: showHelp = true
        case let .book(n): selectBook(number: n)
        case .prevBook: cycleBook(-1)
        case .nextBook: cycleBook(1)
        case .settings: showSettings = true
        case .hints: startHints()
        case .books: openFloatingExplorer(level: .books)
        default: return false
        }
        return true
    }

    func performExplorer(_ action: ShellAction) -> Bool {
        if performShared(action) { return true }
        let ex = explorer
        let half = max(1, ex.pageRows / 2)
        switch action {
        case let .move(n): ex.nav.move(n)
        case let .halfPage(d): ex.nav.move(d * half)
        case let .page(d): ex.nav.move(d * max(1, ex.pageRows - 1))
        case .top: ex.nav.top()
        case .bottom: ex.nav.bottom()
        case .parent: ex.nav.left()
        case .open:
            if let note = ex.nav.right() { open(note) }
        case .historyBack: ex.nav.historyBack()
        case .historyForward: ex.nav.historyForward()
        case .home: ex.nav.home()
        case .filter: ex.prompt = .init(kind: .filter, text: ex.nav.filter)
        case .nextMatch: ex.nav.cycle(1)
        case .prevMatch: ex.nav.cycle(-1)
        case .clearOrBack:
            if !ex.nav.filter.isEmpty { ex.nav.setFilter("") }
        case .create: beginCreate()
        case .rename: beginRename()
        case .delete: beginDelete()
        case .yank:
            if let cur = ex.nav.current, cur.kind == .note {
                ex.yanked = cur
                showToast("yanked \(cur.name) · p to paste")
            }
        case .paste: paste()
        case .toggleHidden:
            preferences.explorerShowHidden.toggle()
            ex.setShowHidden(preferences.explorerShowHidden)
            showToast(preferences.explorerShowHidden ? "showing hidden" : "hiding hidden")
        case .togglePreview: preferences.explorerShowPreview.toggle()
        case .refresh: refreshBook()
        case .edit:
            if let cur = ex.nav.current, cur.kind == .note { open(cur, edit: true) }
        case .contextMenu: showContextMenuForCursor()
        case .close: break
        default: return false
        }
        return true
    }

    private func performReader(_ action: ShellAction) -> Bool {
        if performShared(action) { return true }
        let c = readCoordinator
        switch action {
        case let .move(n): c.glide(by: CGFloat(22 * n))
        case let .halfPage(d): c.scrollHalfPage(direction: CGFloat(d))
        case let .page(d): c.scrollFullPage(direction: CGFloat(d))
        case .top: c.scrollTo(.top)
        case .bottom: c.scrollTo(.bottom)
        case .close:
            if isSplit { closeLeaf(primaryLeaf) } else { closeNote() }
        case .parent, .clearOrBack:
            if !MarkdownReading.closeFind(in: c.scrollView) { closeNote() }
        case .explore: openFloatingExplorer()
        case .hover: hoverFromKeyboard()
        case .follow, .open: followLinkInFocusedPane(.current)
        case .edit: setEditing(true)
        case .yank: performYank()
        case .refresh: refreshBook()
        case .find: MarkdownReading.find(.show, in: c.scrollView)
        case .nextMatch: MarkdownReading.find(.next, in: c.scrollView)
        case .prevMatch: MarkdownReading.find(.previous, in: c.scrollView)
        case .nextHeading: jumpHeading(next: true, in: c.scrollView, coordinator: c)
        case .prevHeading: jumpHeading(next: false, in: c.scrollView, coordinator: c)
        default: return false
        }
        return true
    }
}

extension AppState {
    /// Per-device editor settings for the vim editor (web parity).
    var vimEditorOptions: VimEditorOptions {
        VimEditorOptions(
            escapeSequences: preferences.escapeSequences,
            escapeTimeout: Double(preferences.escapeTimeoutMs) / 1000,
            fontSize: CGFloat(preferences.editorFontSize),
            lineWrapping: preferences.lineWrapping
        )
    }
}
