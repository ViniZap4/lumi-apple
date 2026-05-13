import Foundation
import Observation
import LumiKit

/// Yazi / TUI-style three-column browser state.
///
/// `pathStack` is the breadcrumb of folders the user has descended into:
///   `[root]` at the very start, `[root, "projects"]` after diving in,
///   `[root, "projects", "alpha"]` two levels deep, etc.
///
/// The active column ("current") is `pathStack.last`. The previous entry
/// in the stack is the "parent" column. The "preview" column reflects
/// whichever item the cursor sits on inside `current`.
///
/// `cursorPerFolder` remembers cursor position per visited folder so going
/// back into a parent restores where you were.
@Observable
@MainActor
final class TreeBrowserState {
    var pathStack: [FolderNode]
    private var cursorPerFolder: [String: Int] = [:]

    init(root: FolderNode) {
        root.loadIfNeeded()
        self.pathStack = [root]
    }

    var currentFolder: FolderNode { pathStack.last ?? pathStack[0] }
    var parentFolder: FolderNode? {
        pathStack.count >= 2 ? pathStack[pathStack.count - 2] : nil
    }

    var cursor: Int {
        get { cursorPerFolder[currentFolder.relativePath] ?? 0 }
        set { cursorPerFolder[currentFolder.relativePath] = newValue }
    }

    var currentItems: [FolderNode.Item] {
        currentFolder.items ?? []
    }

    var selectedItem: FolderNode.Item? {
        let items = currentItems
        guard !items.isEmpty else { return nil }
        let idx = max(0, min(items.count - 1, cursor))
        return items[idx]
    }

    /// j / arrow-down
    func moveCursor(by delta: Int) {
        let items = currentItems
        guard !items.isEmpty else { return }
        let bounded = max(0, min(items.count - 1, cursor + delta))
        cursor = bounded
    }

    /// G — bottom of current column.
    func moveCursorToEnd() {
        let items = currentItems
        guard !items.isEmpty else { return }
        cursor = items.count - 1
    }

    /// gg — top.
    func moveCursorToStart() {
        cursor = 0
    }

    /// l / Enter — dive into selected folder. If the selection is a note,
    /// return it so the host can open it; folders push onto the path stack
    /// and reset cursor to remembered (or 0).
    @discardableResult
    func enterSelection() -> NoteEntry? {
        guard let item = selectedItem else { return nil }
        switch item {
        case .folder(let f):
            f.loadIfNeeded()
            pathStack.append(f)
            return nil
        case .note(let n):
            return n
        }
    }

    /// h / Esc — back to parent. Returns false if already at root.
    @discardableResult
    func goBack() -> Bool {
        guard pathStack.count > 1 else { return false }
        pathStack.removeLast()
        return true
    }

    /// Direct selection — used when a user clicks a row (mouse / trackpad).
    /// Sets the cursor; if the row is a folder and the user double-clicks
    /// or presses Enter immediately after, `enterSelection` handles it.
    func setCursor(toItemID id: String) {
        if let idx = currentItems.firstIndex(where: { $0.id == id }) {
            cursor = idx
        }
    }
}
