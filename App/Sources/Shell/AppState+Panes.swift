import Foundation
import SwiftUI
import LumiKit
import LumiUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Pane focus (vim windows / vim-tmux-navigator): `⌃h ⌃j ⌃k ⌃l`,
/// `⌃w h/j/k/l`, `⌃w w` / `⌃w W`, `⌃w p` move the keyboard between the
/// books sidebar, the main area (explorer, reader or editor) and the
/// split preview. Where focus may go is `PaneGraph` (pure, tested); this
/// file moves the first responder and keeps `paneFocus` in step with
/// clicks.
extension AppState {
    /// The main area's pane.
    var mainPane: PaneID? {
        switch surface {
        case .empty: return nil
        case .explorer: return .explorer
        case .reader: return .reader
        case .editor: return .editor
        }
    }

    var paneLayout: PaneLayout {
        var preview: PaneLayout.Preview = .none
        if surface == .editor, preferences.splitPreview, let split = activeSplit {
            switch split.placement {
            case .off: preview = .none
            case .beside: preview = .beside
            case .tabbed: preview = .tabbed
            }
        }
        return PaneLayout(
            sidebarVisible: columnVisibility != .detailOnly,
            sidebarAvailable: true,
            main: mainPane,
            preview: preview
        )
    }

    /// The pane that has the keyboard (resolved against the layout).
    var focusedPane: PaneID? { PaneGraph.resolve(paneFocus, in: paneLayout) }

    /// More than one pane on screen: the focused one wears a marker.
    var showsPaneMarker: Bool { PaneGraph.panes(paneLayout).count > 1 }

    /// Which split side wears the focus marker (only while a pane key
    /// could move away from it).
    var splitFocusMarker: ScrollSync.Side? {
        switch focusedPane {
        case .editor: return showsPaneMarker ? .source : nil
        case .preview: return .preview
        default: return nil
        }
    }

    /// Run a pane command. False when no pane lies that way.
    @discardableResult
    func performPane(_ command: PaneCommand) -> Bool {
        guard let target = PaneGraph.target(from: paneFocus, command, layout: paneLayout, previous: previousPane) else {
            return false
        }
        focusPane(target.pane, reveal: target.revealsSidebar)
        return true
    }

    /// Give `pane` the keyboard.
    func focusPane(_ pane: PaneID, reveal: Bool = false) {
        let from = focusedPane
        if reveal {
            columnVisibility = .all
            sidebarAutoShown = true
        }
        if pane == .sidebar, from != .sidebar {
            let list = BookSwitcherOrder.flattened(books.books)
            sidebarCursor = openBook.flatMap { list.firstIndex(of: $0) } ?? min(sidebarCursor, max(0, list.count - 1))
        }
        if let from, from != pane { previousPane = from }
        if from == .sidebar, pane != .sidebar { closeDrawerIfAuto() }
        paneFocus = pane == mainPane ? nil : pane
        keymap.reset()
        moveResponder(to: pane, from: from)
    }

    /// Esc / ⏎ / ⌃l out of the sidebar: back to the main area.
    func leaveSidebar() {
        previousPane = .sidebar
        paneFocus = nil
        closeDrawerIfAuto()
        keymap.reset()
        if let main = mainPane { moveResponder(to: main, from: .sidebar) }
    }

    /// A click (or the system) gave `pane` the keyboard.
    func notePaneFocus(_ pane: PaneID?) {
        let target = pane == mainPane ? nil : pane
        guard target != paneFocus else { return }
        let from = focusedPane
        if let from, from != (pane ?? mainPane) { previousPane = from }
        if from == .sidebar, pane != .sidebar { closeDrawerIfAuto() }
        paneFocus = target
        keymap.reset()
        // A click on the sidebar leaves the editor first responder: hand
        // the keys to the shell router.
        if pane == .sidebar { moveResponder(to: .sidebar, from: from) }
    }

    private func closeDrawerIfAuto() {
        guard sidebarAutoShown else { return }
        sidebarAutoShown = false
        columnVisibility = .detailOnly
    }

    private func moveResponder(to pane: PaneID, from: PaneID?) {
        switch pane {
        case .editor:
            let editor = activeEditor
            if let split = activeSplit {
                split.focusEditor()
            } else {
                editor?.focusTextView()
            }
            if from == .preview, preferences.previewReturnMovesCursor {
                // After the editor viewport caught up with the preview.
                DispatchQueue.main.async { editor?.moveCursorIntoViewport() }
            }
        case .preview:
            guard let split = activeSplit else { return }
            split.focusPreview()
            DispatchQueue.main.async { [weak self] in
                if let view = split.previewScrollView { self?.previewCoordinator.attach(scrollView: view) }
            }
        case .sidebar, .explorer, .reader:
            // The shell key router only acts while no text view owns the
            // keyboard.
            #if canImport(AppKit)
            if let window = NSApp.keyWindow, let text = window.firstResponder as? NSText, text.isEditable {
                window.makeFirstResponder(nil)
            }
            #endif
        }
    }

    /// Wire the mounted editor / split so clicks keep `paneFocus` true.
    func adoptEditor(_ controller: VimController) {
        activeEditor = controller
        controller.paneKeys.ctrlHJKL = preferences.ctrlHJKLPanes
        controller.onPaneCommand = { [weak self] command in
            self?.performPane(command) ?? false
        }
        controller.onFocus = { [weak self] in self?.notePaneFocus(.editor) }
    }

    func adoptSplit(_ split: SplitScrollSync) {
        activeSplit = split
        split.onPreviewFocus = { [weak self] in
            guard let self else { return }
            self.notePaneFocus(.preview)
            if let view = split.previewScrollView { self.previewCoordinator.attach(scrollView: view) }
        }
    }

    // MARK: Sidebar keys

    func performSidebar(_ action: ShellAction) -> Bool {
        let list = BookSwitcherOrder.flattened(books.books)
        let last = max(0, list.count - 1)
        switch action {
        case let .move(n): sidebarCursor = max(0, min(last, sidebarCursor + n))
        case let .halfPage(d): sidebarCursor = max(0, min(last, sidebarCursor + d * 5))
        case let .page(d): sidebarCursor = max(0, min(last, sidebarCursor + d * 10))
        case .top: sidebarCursor = 0
        case .bottom: sidebarCursor = last
        case .open:
            guard list.indices.contains(sidebarCursor) else { return true }
            let book = list[sidebarCursor]
            leaveSidebar()
            Task { await selectBook(book) }
        case .clearOrBack, .close, .parent: leaveSidebar()
        case .refresh: books.reload()
        case .pending, .palette, .command, .help, .book, .prevBook, .nextBook, .settings:
            return false // shared keys
        default: return false
        }
        return true
    }

    // MARK: Reading keys shared by the reader and the focused preview

    /// `{` `}` `[[` `]]`: previous / next heading.
    func jumpHeading(next: Bool, in scrollView: MarkdownPlatformScrollView?, coordinator: ReadModeCoordinator) {
        let offsets = MarkdownReading.headingOffsets(in: scrollView)
        #if canImport(AppKit)
        guard let current = scrollView?.contentView.bounds.minY else { return }
        #else
        guard let current = scrollView?.contentOffset.y else { return }
        #endif
        let target = next ? offsets.first { $0 > current + 2 } : offsets.last { $0 < current - 2 }
        guard let target else { return }
        coordinator.glide(by: target - current)
    }

    func performPreview(_ action: ShellAction) -> Bool {
        let split = activeSplit
        let view = split?.previewScrollView
        if let view { previewCoordinator.attach(scrollView: view) }
        split?.claim(.preview)
        let c = previewCoordinator
        switch action {
        case let .move(n): c.glide(by: CGFloat(22 * n))
        case let .halfPage(d): c.scrollHalfPage(direction: CGFloat(d))
        case let .page(d): c.scrollFullPage(direction: CGFloat(d))
        case .top: c.scrollTo(.top)
        case .bottom: c.scrollTo(.bottom)
        case .nextHeading: jumpHeading(next: true, in: view, coordinator: c)
        case .prevHeading: jumpHeading(next: false, in: view, coordinator: c)
        case .find: MarkdownReading.find(.show, in: view)
        case .nextMatch: MarkdownReading.find(.next, in: view)
        case .prevMatch: MarkdownReading.find(.previous, in: view)
        case .open:
            if !MarkdownReading.followSelectedLink(in: view) { showToast("no link here · f labels the links") }
        case .yank:
            // Selection (or the current find match, which is selected),
            // else the whole note.
            if MarkdownReading.copySelection(in: view) {
                showToast("copied selection")
            } else {
                copyToPasteboard(openNoteText)
                showToast("copied the note")
            }
        case .hints: startHints()
        case .clearOrBack:
            // Esc first closes the find bar, then leaves.
            if !MarkdownReading.closeFind(in: view) { focusPane(.editor) }
        case .parent, .close, .edit: focusPane(.editor)
        default: return false
        }
        return true
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    // MARK: Legend

    /// `⌃h⌃l panes` (or `⌃h books`) when a pane key does something here.
    var paneLegendItem: LegendItem? {
        guard preferences.ctrlHJKLPanes else { return nil }
        let layout = paneLayout
        if layout.preview == .tabbed { return LegendItem("⌃j ⌃k", "source/preview") }
        if layout.preview == .beside, focusedPane == .editor { return LegendItem("⌃l", "read preview") }
        if PaneGraph.panes(layout).count > 1 { return LegendItem("⌃h ⌃l", "panes") }
        if layout.main != nil, layout.sidebarAvailable { return LegendItem("⌃h", "books") }
        return nil
    }
}
