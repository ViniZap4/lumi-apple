import Foundation

/// Miller-column navigation state (parent | current | preview).
///
/// Port of the web client's `miller.svelte.ts` (itself mirroring the TUI
/// tree grammar): `h` ascends landing on the folder you came from, `l`
/// descends, `H`/`L` walk a capped back/forward history of folder
/// visits, `gg`/`G` jump to the ends, `~` goes to the book root. Each
/// folder remembers its own selection, so walking back out restores the
/// cursor like yazi does.
///
/// Pure value type: the view feeds keys/clicks and renders the derived
/// columns. `tree` is replaced whenever the note list changes; a folder
/// that disappears resolves to its nearest surviving ancestor.
public struct MillerNav: Sendable, Equatable {
    public static let historyCap = 50

    struct Loc: Sendable, Equatable {
        var dir: String
        var key: String?
    }

    struct Remembered: Sendable, Equatable {
        var key: String?
        var index: Int
    }

    public var tree: NoteTree
    /// Requested folder; `dir` is the one actually shown.
    public private(set) var cwd: String = NoteTree.root
    /// Filter for the CURRENT column (`/`). Cleared on folder change.
    public private(set) var filter: String = ""
    /// Show dot-files / dot-folders (`.` toggles).
    public var showHidden: Bool = false

    private var memory: [String: Remembered] = [:]
    private var back: [Loc] = []
    private var fwd: [Loc] = []

    public init(tree: NoteTree = .empty) {
        self.tree = tree
    }

    // MARK: Derived columns

    public var dir: String { tree.nearestExisting(cwd) }
    public var allEntries: [ExplorerEntry] { tree.entries(in: dir, showHidden: showHidden) }
    public var entries: [ExplorerEntry] { NoteTree.filter(allEntries, query: filter) }
    public var cursor: Int { resolveCursor(dir, entries) }
    public var current: ExplorerEntry? {
        let e = entries
        let c = resolveCursor(dir, e)
        return c >= 0 && c < e.count ? e[c] : nil
    }

    public var parent: String? { NoteTree.parentDir(dir) }
    public var parentEntries: [ExplorerEntry] {
        guard let parent else { return [] }
        return tree.entries(in: parent, showHidden: showHidden)
    }
    /// The current folder's row in the parent column (-1 at the root).
    public var parentCursor: Int {
        guard parent != nil else { return -1 }
        let key = NoteTree.folderKey(dir)
        return parentEntries.firstIndex { $0.key == key } ?? -1
    }
    /// Children of the folder under the cursor (preview column), nil when
    /// the cursor is on a note (the preview renders the note instead).
    public var previewEntries: [ExplorerEntry]? {
        guard let cur = current, cur.kind == .folder else { return nil }
        return tree.entries(in: cur.path, showHidden: showHidden)
    }
    public var previewCursor: Int {
        guard let cur = current, cur.kind == .folder, let pe = previewEntries else { return -1 }
        return resolveCursor(cur.path, pe)
    }

    public var canBack: Bool { !back.isEmpty }
    public var canForward: Bool { !fwd.isEmpty }

    // MARK: Cursor

    public mutating func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        setCursor(cursor + delta)
    }

    public mutating func top() { setCursor(0) }
    public mutating func bottom() { setCursor(entries.count - 1) }

    public mutating func setCursor(_ i: Int) {
        let e = entries
        guard !e.isEmpty else { return }
        let index = max(0, min(e.count - 1, i))
        remember(dir, key: e[index].key, index: index)
    }

    /// `n` / `N`: next / previous row of the (filtered) column, wrapping.
    public mutating func cycle(_ delta: Int) {
        let n = entries.count
        guard n > 0 else { return }
        setCursor(((cursor + delta) % n + n) % n)
    }

    // MARK: Columns

    /// `h`: ascend, landing on the folder we came from. False at root.
    @discardableResult
    public mutating func left() -> Bool {
        guard let p = parent else { return false }
        goTo(p, select: NoteTree.folderKey(dir))
        return true
    }

    /// `l` / Enter: descend into the folder under the cursor. Returns the
    /// note under the cursor instead (the caller opens it).
    public mutating func right() -> ExplorerEntry? {
        guard let e = current else { return nil }
        if e.kind == .note { return e }
        goTo(e.path)
        return nil
    }

    /// Navigate to `dir` (recorded in history), optionally selecting
    /// `selectKey` there. Already there → no history entry.
    public mutating func goTo(_ dir: String, select selectKey: String? = nil) {
        let target = tree.nearestExisting(dir)
        if target == self.dir {
            filter = ""
            if let selectKey { self.selectKey(selectKey) }
            return
        }
        pushBack()
        fwd = []
        enter(target, select: selectKey)
    }

    /// `~`: book root.
    public mutating func home() { goTo(NoteTree.root) }

    /// `H`
    @discardableResult
    public mutating func historyBack() -> Bool {
        guard let dest = back.popLast() else { return false }
        fwd = Self.capped(fwd + [here])
        enter(dest.dir, select: dest.key)
        return true
    }

    /// `L`
    @discardableResult
    public mutating func historyForward() -> Bool {
        guard let dest = fwd.popLast() else { return false }
        back = Self.capped(back + [here])
        enter(dest.dir, select: dest.key)
        return true
    }

    /// Show `noteID` in its folder with the cursor on it. False if unknown.
    @discardableResult
    public mutating func reveal(noteID: String) -> Bool {
        guard let d = tree.noteDir[noteID] else { return false }
        let key = NoteTree.noteKey(noteID)
        if current?.key == key { return true }
        if d != dir {
            goTo(d, select: key)
        } else {
            if !entries.contains(where: { $0.key == key }) { filter = "" }
            selectKey(key)
        }
        return true
    }

    /// Select a folder by path in the current column, if present.
    public mutating func select(key: String) { selectKey(key) }

    public mutating func setFilter(_ q: String) { filter = q }

    /// Forget everything (book switch).
    public mutating func reset() {
        cwd = NoteTree.root
        filter = ""
        memory = [:]
        back = []
        fwd = []
    }

    // MARK: Internals

    private mutating func selectKey(_ key: String) {
        if let i = entries.firstIndex(where: { $0.key == key }) {
            remember(dir, key: key, index: i)
        }
    }

    private mutating func enter(_ dir: String, select selectKey: String?) {
        cwd = dir
        filter = ""
        if let selectKey {
            let list = tree.entries(in: tree.nearestExisting(dir), showHidden: showHidden)
            if let i = list.firstIndex(where: { $0.key == selectKey }) {
                remember(dir, key: selectKey, index: i)
            }
        }
    }

    private var here: Loc { Loc(dir: dir, key: current?.key) }

    private mutating func pushBack() {
        let h = here
        if back.last == h { return }
        back = Self.capped(back + [h])
    }

    private mutating func remember(_ dir: String, key: String?, index: Int) {
        memory[dir] = Remembered(key: key, index: index)
    }

    /// Remembered key if still visible, else the remembered index clamped
    /// (the row that took its place), else 0.
    private func resolveCursor(_ dir: String, _ entries: [ExplorerEntry]) -> Int {
        guard !entries.isEmpty else { return -1 }
        guard let m = memory[dir] else { return 0 }
        if let key = m.key {
            if m.index < entries.count, entries[m.index].key == key { return m.index }
            if let i = entries.firstIndex(where: { $0.key == key }) { return i }
        }
        return max(0, min(entries.count - 1, m.index))
    }

    private static func capped(_ stack: [Loc]) -> [Loc] {
        stack.count > historyCap ? Array(stack.suffix(historyCap)) : stack
    }
}
