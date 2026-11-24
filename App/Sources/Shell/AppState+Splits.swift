import Foundation
import SwiftUI
import LumiKit
import LumiUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// A mounted vim editor, held weakly.
final class WeakVimController {
    weak var value: VimController?
    init(_ value: VimController) { self.value = value }
}

/// Where the keyboard is, across panes: the sidebar, the primary pane
/// (explorer / reader / editor / its split preview) or a secondary pane.
enum FocusSlot: Equatable {
    case sidebar
    case main(PaneID)
    case leaf(PaneLeafID)
}

/// Local notes in the pool: the last pane to let go saves unsaved edits.
extension EditorState: PoolableSession {
    var isPoolUsable: Bool { true }
    func destroy() {
        if isDirty { save() }
    }
}

// MARK: - Panes: geometry and focus (SPEC-PARTE2 §3)

extension AppState {
    /// The note area as the user sees it: the primary's split preview is
    /// drawn inside the primary pane (with its scroll sync), so preview
    /// leaves are left out of the rendered tree and of the geometry.
    var visibleLayout: PaneTree { noteLayout.withoutPreviews() }

    var primaryLeaf: PaneLeafID { noteLayout.mainLeaf }

    /// Several note panes on screen.
    var isSplit: Bool { isNoteOpen && noteLayout.notePanes.count > 1 }

    /// The secondary pane with the keyboard, if any.
    var focusedSecondary: PaneLeafID? {
        guard isSplit, let s = secondaryFocus, s != primaryLeaf, noteLayout.notePath(s) != nil else { return nil }
        return s
    }

    /// The note pane with the keyboard (the primary unless a secondary
    /// pane has it).
    var focusedLeaf: PaneLeafID { focusedSecondary ?? primaryLeaf }

    var currentSlot: FocusSlot {
        if let s = focusedSecondary { return .leaf(s) }
        if focusedPane == .sidebar { return .sidebar }
        return .main(focusedPane ?? mainPane ?? .reader)
    }

    /// The view a pane shows.
    func paneView(_ id: PaneLeafID) -> NoteViewMode {
        if id == primaryLeaf { return noteViewMode }
        if case let .note(_, view)? = noteLayout.content(id) { return view }
        return .reading
    }

    /// The note path a pane shows.
    func panePath(_ id: PaneLeafID?) -> String? {
        guard let id else { return openNotePath }
        if id == primaryLeaf { return openNotePath }
        return noteLayout.notePath(id)
    }

    /// The pane's editor, when its view edits text.
    func paneEditor(_ id: PaneLeafID) -> VimController? {
        if id == primaryLeaf { return isEditing ? activeEditor : nil }
        guard paneView(id).isEditing else { return nil }
        return paneEditors[id]?.value
    }

    /// The scroll view a link is read from in a pane (reader, the focused
    /// split preview, a secondary reader).
    func paneScrollView(_ id: PaneLeafID) -> MarkdownPlatformScrollView? {
        if id == primaryLeaf {
            if focusedPane == .preview { return activeSplit?.previewScrollView }
            return readCoordinator.scrollView
        }
        return paneReaders[id]?.scrollView
    }

    /// Give a pane the keyboard.
    func focusLeaf(_ id: PaneLeafID, entering dir: PaneDirection? = nil) {
        if id == primaryLeaf || !isSplit {
            let target: PaneID = (dir == .left && paneLayout.preview == .beside) ? .preview : (mainPane ?? .reader)
            focusPane(target)
            return
        }
        let from = currentSlot
        if from == .sidebar { leaveSidebarQuietly() }
        secondaryFocus = id
        noteLayout.focus(id)
        paneFocus = nil
        keymap.reset()
        if from != .leaf(id) { previousSlot = from }
        if let editor = paneEditor(id) {
            editor.focusTextView()
        } else {
            resignTextResponder()
            #if canImport(AppKit)
            if let view = paneReaders[id]?.scrollView?.documentView {
                view.window?.makeFirstResponder(view)
            }
            #endif
        }
    }

    func focusSlot(_ slot: FocusSlot?) {
        switch slot {
        case let .main(p) where p != .sidebar: focusPane(p)
        case let .leaf(id) where noteLayout.notePath(id) != nil: focusLeaf(id)
        default: focusPane(mainPane ?? .reader)
        }
    }

    /// A click / the editor's first responder put a secondary pane in charge.
    func noteSecondaryFocus(_ id: PaneLeafID) {
        guard isSplit, id != primaryLeaf else {
            if secondaryFocus != nil { secondaryFocus = nil; noteLayout.focus(primaryLeaf) }
            return
        }
        guard secondaryFocus != id else { return }
        let from = currentSlot
        if from == .sidebar { leaveSidebarQuietly() }
        previousSlot = from
        secondaryFocus = id
        noteLayout.focus(id)
        paneFocus = nil
        keymap.reset()
    }

    private func leaveSidebarQuietly() {
        sidebarAutoShown = false
    }

    /// Hand the keys to the shell router (no editable text view owns them).
    func resignTextResponder() {
        #if canImport(AppKit)
        if let window = NSApp.keyWindow, let text = window.firstResponder as? NSText, text.isEditable {
            window.makeFirstResponder(nil)
        }
        #endif
    }

    // MARK: Pane commands with splits

    /// `⌃h/j/k/l`, `⌃w h/j/k/l`: by geometry. The primary's own editor ⇄
    /// preview moves come first. (No sidebar: books are in the overlay.)
    func movePane(_ dir: PaneDirection) -> Bool {
        // Moving to another pane unzooms first (tmux).
        unzoom()
        switch currentSlot {
        case .sidebar:
            guard dir == .right else { return false }
            let last = noteLayout.focused
            if last != primaryLeaf, noteLayout.notePath(last) != nil { focusLeaf(last) } else { focusPane(mainPane ?? .reader) }
            return true
        case .main:
            if let t = PaneGraph.target(from: paneFocus, .move(dir), layout: paneLayout, previous: previousPane),
               t.pane != .sidebar {
                focusPane(t.pane, reveal: t.revealsSidebar)
                return true
            }
            var t = visibleLayout
            t.focus(primaryLeaf)
            if let n = t.neighbour(dir) {
                focusLeaf(n, entering: dir)
                return true
            }
        case let .leaf(id):
            var t = visibleLayout
            t.focus(id)
            if let n = t.neighbour(dir) {
                focusLeaf(n, entering: dir)
                return true
            }
        }
        return false
    }

    /// Cycle order: the panes left → right,
    /// top → bottom (the primary's preview right after it).
    var cycleSlots: [FocusSlot] {
        var out: [FocusSlot] = []
        for id in visibleLayout.leaves {
            if id == primaryLeaf {
                out.append(.main(mainPane ?? .reader))
                if paneLayout.preview != .none { out.append(.main(.preview)) }
            } else {
                out.append(.leaf(id))
            }
        }
        return out
    }

    func cyclePane(_ step: Int) -> Bool {
        unzoom()
        let slots = cycleSlots
        guard slots.count > 1 else { return false }
        let cur = currentSlot
        let i = slots.firstIndex(of: cur) ?? 0
        focusSlot(slots[((i + step) % slots.count + slots.count) % slots.count])
        return true
    }

    func lastPane() -> Bool {
        guard let p = previousSlot, p != currentSlot else { return false }
        unzoom()
        if case let .leaf(id) = p, noteLayout.notePath(id) == nil { return false }
        focusSlot(p)
        return true
    }

    // MARK: Layout

    /// `⌃w v` / `⌃w s`, `:vsplit [note]`, `:split [note]`, link → split.
    /// The new pane shows `note` (default: the target's note, in the
    /// target's view — vim's `⌃w v`) and takes the keyboard.
    func splitPane(_ axis: SplitAxis, note: String? = nil, view: NoteViewMode? = nil, target: PaneLeafID? = nil,
                   before: Bool = false) {
        guard isNoteOpen else {
            showToast("open a note first", tone: .warning)
            return
        }
        guard noteLayout.notePanes.count < PaneTree.maxPanes else {
            showToast("too many panes — close one first (⌃w q)", tone: .warning)
            return
        }
        let t = target ?? focusedLeaf
        guard let path = note ?? panePath(t) else { return }
        var v = view ?? (note == nil ? paneView(t) : .reading)
        if v.isEditing, !canWritePane(path) { v = .reading }
        var id = t
        // Splitting unzooms first (PaneTree.split does).
        withMotion(.standard) {
            id = noteLayout.split(axis, content: .note(path: path, view: v), target: t, focusNew: false, before: before)
        }
        persistLayout()
        focusLeaf(id)
        // The editor mounts on the next pass: give it the keyboard then.
        DispatchQueue.main.async { [weak self] in
            if self?.secondaryFocus == id { self?.focusLeaf(id) }
        }
    }

    func canWritePane(_ path: String) -> Bool {
        explorer.isLocal || can("note.write")
    }

    /// Close a pane (`⌃w q`, `:q`, `:close`, the × in its header). The
    /// last pane closes the note (back to the explorer).
    func closeLeaf(_ id: PaneLeafID) {
        guard noteLayout.notePanes.count > 1 else {
            if id == primaryLeaf { closeNote() }
            return
        }
        let wasPrimary = id == primaryLeaf
        let wasFocused = id == focusedLeaf
        withMotion(.standard) { noteLayout.close(id) }
        forgetPane(id)
        if wasPrimary {
            adoptPrimary(noteLayout.mainLeaf)
        } else if wasFocused {
            secondaryFocus = nil
            let next = noteLayout.focused
            if next == primaryLeaf || noteLayout.notePath(next) == nil { focusPane(mainPane ?? .reader) } else { focusLeaf(next) }
        }
        persistLayout()
    }

    private func forgetPane(_ id: PaneLeafID) {
        paneVim[id] = nil
        paneEditors[id] = nil
        paneReaders[id] = nil
        paneGlobalFrames[id] = nil
        if secondaryFocus == id { secondaryFocus = nil }
        for key in fanoutViews.keys where key.hasPrefix("leaf\(id.raw)#") { fanoutViews[key] = nil }
    }

    /// Make pane `id` the primary: the app's open-note state follows its
    /// note (the pool hands over the same document / live session).
    func adoptPrimary(_ id: PaneLeafID) {
        guard case let .note(path, view)? = noteLayout.content(id) else { return }
        noteLayout.setPrimary(id)
        noteLayout.focus(id)
        secondaryFocus = nil
        forgetPane(id)
        if openNotePath != path {
            _ = openNote(atPath: path, edit: view.isEditing)
        } else if isEditing != view.isEditing {
            setEditing(view.isEditing)
        }
        if view == .live || view == .source { setNoteViewMode(view) }
        focusPane(mainPane ?? .reader)
    }

    /// `⌃w q` / `:q` / `:close` on whatever has the keyboard.
    func closeFocusedPane() {
        if let s = focusedSecondary {
            closeLeaf(s)
            return
        }
        if isSplit, focusedPane != .preview {
            closeLeaf(primaryLeaf)
            return
        }
        if focusedPane == .preview || (focusedPane == .editor && splitPreviewShown) {
            let wasPreview = focusedPane == .preview
            setSplitPreview(false)
            if wasPreview { focusPane(.editor) }
        } else if isNoteOpen {
            closeNote()
        }
    }

    /// `⌃w o` / `:only`.
    func onlyPane() {
        if isSplit {
            let keep = focusedLeaf
            let wasPrimary = keep == primaryLeaf
            withMotion(.standard) {
                noteLayout.focus(keep)
                noteLayout.onlyNote()
            }
            for id in Array(paneVim.keys) + Array(paneEditors.keys) where id != keep { forgetPane(id) }
            if !wasPrimary { adoptPrimary(keep) }
            persistLayout()
            return
        }
        if splitPreviewShown {
            setSplitPreview(false)
            if focusedPane == .preview { focusPane(.editor) }
        }
    }

    /// `⌃w < > + -`: 5% of the enclosing split per step.
    func resizeFocusedPane(_ axis: SplitAxis, steps: Int) {
        guard isNoteOpen else { return }
        let before = noteLayout
        noteLayout.nudge(focusedLeaf, axis: axis, by: 0.05 * Double(steps))
        if noteLayout != before { persistLayout() }
    }

    /// A divider dragged to `at` (path in the rendered tree — the same
    /// path in the full tree, previews only ever collapse below it).
    func resizeDivider(path: [Int], index: Int, at: Double) {
        noteLayout.resizeDivider(at: path, index: index, to: at)
        persistLayout()
    }

    /// Switch a pane's view (its header switch, `i` / `e` in a reader).
    func setPaneView(_ id: PaneLeafID, _ view: NoteViewMode) {
        if id == primaryLeaf {
            setNoteViewMode(view)
            return
        }
        guard let path = noteLayout.notePath(id) else { return }
        if view.isEditing, !canWritePane(path) {
            showToast("read-only — note.write required", tone: .warning)
            return
        }
        withMotion(.fast) { noteLayout.setContent(.note(path: path, view: view), for: id) }
        persistLayout()
        if view == .live || view == .source {
            preferences.editMode = view == .live ? .live : .source
        }
        if secondaryFocus == id {
            DispatchQueue.main.async { [weak self] in self?.focusLeaf(id) }
        }
    }

    /// Show another note in a secondary pane (link followed "here").
    func setPaneNote(_ id: PaneLeafID, path: String) {
        let view = paneView(id)
        withMotion(.fast) { noteLayout.setContent(.note(path: path, view: view.isEditing ? view : .reading), for: id) }
        persistLayout()
    }

    // MARK: Deleted / moved notes

    func noteExists(_ path: String) -> Bool {
        switch explorer.source {
        case let .local(root):
            guard let url = try? LumiOpenURL.localNoteURL(path, in: root) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        case .remote:
            let notes = remoteVaultsStore.notes
            if notes.isEmpty { return true } // still loading: keep the layout
            return notes.contains { $0.path == path || $0.id == path }
        case .none:
            return true
        }
    }

    /// Close the panes whose note is gone (deleted, renamed or moved).
    func pruneDeletedPanes() {
        guard explorer.source != .none else { return }
        let gone = noteLayout.prune { noteExists($0) }
        guard !gone.isEmpty else { return }
        for id in gone { forgetPane(id) }
        persistLayout()
    }

    /// The primary note is going away (deleted / renamed): with other
    /// panes the primary pane closes, else the note closes.
    func closePrimaryNoteForRemoval() {
        if isSplit { closeLeaf(primaryLeaf) } else { closeNote() }
    }

    // MARK: Local documents

    /// Point the primary pane at a local note through the pool.
    func bindPrimaryLocal(path: String, url: URL) {
        guard let session else { return }
        if editor.noteID == path, localDocs.peek(path) === editor { return }
        if editor.isDirty { editor.save() }
        let root = session.rootURL
        let doc = localDocs.acquire(path) {
            let e = EditorState()
            e.load(noteID: path, at: url, vaultRoot: root)
            return e
        }
        releasePrimaryLocal()
        editor = doc
    }

    /// Let go of the primary's local document (a pane may keep it).
    func releasePrimaryLocal() {
        guard let id = editor.noteID else { return }
        localDocs.release(id, session: editor, defer: true)
        editor = EditorState()
    }

    // MARK: Shared live documents

    func fanout(for session: OpenNoteSession) -> DocumentFanout {
        let key = ObjectIdentifier(session)
        if let hub = fanouts[key], hub.document === session { return hub }
        // Drop hubs of destroyed sessions.
        fanouts = fanouts.filter { !(($0.value.document as? OpenNoteSession)?.isDestroyed ?? true) }
        let hub = DocumentFanout(document: session)
        fanouts[key] = hub
        return hub
    }

    /// The document an editor mounted by `owner` binds to.
    func docView(for session: OpenNoteSession, owner: String) -> DocumentFanout.View {
        let key = owner + "#" + String(UInt(bitPattern: ObjectIdentifier(session).hashValue))
        if let v = fanoutViews[key] { return v }
        let v = fanout(for: session).makeView()
        fanoutViews = fanoutViews.filter { !$0.key.hasPrefix(owner + "#") }
        fanoutViews[key] = v
        return v
    }

    // MARK: Opening a note somewhere

    /// Open `path` in pane `from` (current), or a new split beside it.
    func openNoteIn(_ path: String, where target: LinkOpenWhere, from leaf: PaneLeafID?) {
        switch target {
        case .current:
            if let leaf, isSplit, leaf != primaryLeaf {
                setPaneNote(leaf, path: path)
            } else if !openNote(atPath: path) {
                showToast("note not found: \(path)", tone: .warning)
            }
        case .vsplit, .hsplit:
            if !isNoteOpen {
                _ = openNote(atPath: path)
                return
            }
            splitPane(target.axis ?? .vertical, note: path, view: .reading, target: leaf ?? focusedLeaf)
        }
    }

    /// `:vsplit plan` — the best fuzzy match among the book's notes.
    func noteMatching(_ query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let entries = explorer.tree.allNotes
        if let exact = entries.first(where: { $0.path.lowercased() == q.lowercased() || $0.name.lowercased() == q.lowercased() }) {
            return exact.path
        }
        return FuzzyMatch.rank(entries, query: q) { $0.name + " " + $0.path }.first?.path
    }

    // MARK: Ex commands for panes

    /// `:vsplit` `:split` `:only` `:zoom` `:close` `:explore` `:follow` `:hover`.
    /// True when `command` was a pane command.
    func performPaneHostCommand(_ command: String) -> Bool {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "vsplit", "split":
            let axis: SplitAxis = name == "vsplit" ? .vertical : .horizontal
            if arg.isEmpty {
                splitPane(axis)
            } else if let path = noteMatching(arg) {
                splitPane(axis, note: path, view: .reading)
            } else {
                showToast("no note matches “\(arg)”", tone: .warning)
            }
        case "only": onlyPane()
        case "zoom": toggleZoom()
        case "close", "close!": closeFocusedPane()
        case "explore": openFloatingExplorer()
        case "follow": followLinkInFocusedPane(.current)
        case "hover": hoverFromKeyboard()
        default: return false
        }
        return true
    }

    // MARK: lumi:// link

    /// "Copy lumi:// link to this note".
    func copyLumiLink() {
        guard let book = openBook, let note = panePath(focusedLeaf) else {
            showToast("open a note first", tone: .warning)
            return
        }
        let request: LumiOpenURL.Request
        switch book.kind {
        case .local:
            guard let path = book.path ?? session?.rootURL.path else { return }
            request = .local(path: path, note: note)
        case .bound:
            guard let server = book.serverURL, let account = book.account, let vault = book.vaultUUID else { return }
            let id = remoteVaultsStore.notes.first { $0.path == note || $0.id == note }?.id ?? note
            request = .server(serverURL: server, account: account, vaultID: vault, note: id)
        }
        guard let link = LumiOpenURL.link(request) else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        #else
        UIPasteboard.general.string = link
        #endif
        showToast("copied \(link)")
    }
}
