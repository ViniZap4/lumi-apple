import Foundation

// MARK: - Note kinds and views

/// What a note *is*, which decides the views it offers (SPEC-PARTE2 §5,
/// §6). The note-view registry (LumiUI / App) maps a kind + view to the
/// view that renders it.
public enum NoteKind: String, Codable, Sendable, CaseIterable {
    case markdown
    /// Obsidian Kanban board (`kanban-plugin: board|basic` frontmatter).
    case kanban
    /// JSON Canvas 1.0 (`.canvas`).
    case canvas

    /// Kind from the path and (when known) the text.
    public static func detect(path: String, text: String? = nil) -> NoteKind {
        if path.lowercased().hasSuffix(".canvas") { return .canvas }
        if let text, isKanban(text) { return .kanban }
        return .markdown
    }

    /// `kanban-plugin: board` / `basic` in the frontmatter.
    public static func isKanban(_ text: String) -> Bool {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if l == "---" || l == "..." { return false }
            if l.hasPrefix("kanban-plugin:") {
                let v = l.dropFirst("kanban-plugin:".count).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v == "board" || v == "basic"
            }
        }
        return false
    }

    /// Views this kind offers, in toggle order.
    public var views: [NoteViewMode] {
        switch self {
        case .markdown: return [.reading, .live, .source]
        // Reading | Edit | Source (SPEC-PARTE2 §5a): Reading first.
        case .kanban: return [.reading, .board, .source]
        case .canvas: return [.reading, .canvas, .source]
        }
    }

    public var defaultView: NoteViewMode { views[0] }
}

/// How a pane shows its note.
public enum NoteViewMode: String, Codable, Sendable, CaseIterable {
    case reading, live, source, board, canvas

    public var label: String {
        switch self {
        case .reading: return "Reading"
        case .live: return "Live"
        case .source: return "Source"
        // The interactive Board / Canvas is the structured "Edit" mode.
        case .board: return "Edit"
        case .canvas: return "Edit"
        }
    }

    /// The view edits text (vim editor mounted).
    public var isEditing: Bool { self == .live || self == .source }

    /// The interactive (editing) Board / Canvas.
    public var isStructuredEdit: Bool { self == .board || self == .canvas }

    /// The "edit" view of a kind: Live/Source for markdown (per
    /// preference), the Board / Canvas for structured notes.
    public static func editView(for kind: NoteKind, markdown: NoteViewMode) -> NoteViewMode {
        switch kind {
        case .markdown: return markdown
        case .kanban: return .board
        case .canvas: return .canvas
        }
    }
}

// MARK: - Tree

public struct PaneLeafID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "#\(raw)" }
}

/// What a pane holds.
public enum PaneContent: Hashable, Codable, Sendable {
    /// Nothing open yet (a fresh book).
    case empty
    /// A note (book-relative path or server note id) in a view.
    case note(path: String, view: NoteViewMode)
    /// The rendered preview that follows another pane's note (the
    /// source + preview pair).
    case preview(of: PaneLeafID)
}

/// `vertical` = side by side (`:vsplit`, `⌃w v`); `horizontal` = stacked
/// (`:split`, `⌃w s`). Vim's naming.
public enum SplitAxis: String, Codable, Sendable {
    case vertical, horizontal
}

public indirect enum PaneNode: Hashable, Codable, Sendable {
    case leaf(PaneLeafID, PaneContent)
    /// Children with their weights (sum 1).
    case split(SplitAxis, [PaneNode], [Double])
}

/// A rect in unit space (the note area is 1 × 1).
public struct PaneRect: Hashable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// The note area as a tree of panes (vim windows): splits, close, only,
/// equalise, directional / cyclic focus, persisted per book. Pure value
/// type; the views render whatever it says.
public struct PaneTree: Hashable, Codable, Sendable {
    public private(set) var root: PaneNode
    public private(set) var focused: PaneLeafID
    /// For `⌃w p`.
    public private(set) var previous: PaneLeafID?
    private var nextID: Int
    /// The primary note pane: the one the explorer / book selection
    /// drives and the app's open-note state mirrors. Other note panes
    /// are secondary (their own sessions from the pool).
    public private(set) var primary: PaneLeafID?
    /// tmux-style zoom (`⌃w z`, SPEC-PARTE2 §3): this pane (with its
    /// source + preview pair) fills the note area; the others are hidden,
    /// not closed. Never persisted (not in the coding keys).
    public private(set) var zoomed: PaneLeafID?

    private enum CodingKeys: String, CodingKey { case root, focused, previous, nextID, primary }

    /// Most panes on screen at once (web `MAX_PANES`).
    public static let maxPanes = 8
    /// Smallest share a divider drag / `⌃w < >` leaves (web `MIN_SIZE`).
    public static let minSize = 0.12

    /// Weight bounds for a resized split child.
    public static let minWeight = 0.15

    public init(_ content: PaneContent = .empty) {
        let id = PaneLeafID(1)
        root = .leaf(id, content)
        focused = id
        nextID = 2
        primary = id
        zoomed = nil
    }

    // MARK: Zoom (tmux `prefix z`)

    /// The zoomed pane, when it is still in the tree.
    public var zoomedLeaf: PaneLeafID? {
        guard let z = zoomed, leaves.contains(z) else { return nil }
        return z
    }

    public var isZoomed: Bool { zoomedLeaf != nil }

    /// Leaves on screen: every leaf, or the zoomed one and its preview.
    public var visibleLeaves: [PaneLeafID] {
        guard let z = zoomedLeaf else { return leaves }
        return leaves.filter { $0 == z || content($0) == .preview(of: z) }
    }

    /// Toggle zoom on `id` (default: the focused pane). A preview zooms
    /// its note. False — nothing changes — when there is nothing else to
    /// hide (one pane, or only a source + preview pair).
    @discardableResult
    public mutating func toggleZoom(_ id: PaneLeafID? = nil) -> Bool {
        if zoomedLeaf != nil {
            zoomed = nil
            return true
        }
        zoomed = nil
        var target = id ?? focused
        if case let .preview(of: src)? = content(target), content(src) != nil { target = src }
        guard leaves.contains(target), !Self.isUnit(root, target) else { return false }
        if focused != target {
            previous = focused
            focused = target
        }
        zoomed = target
        return true
    }

    /// Back to the exact previous layout (weights never changed).
    public mutating func unzoom() { zoomed = nil }

    // MARK: Reading

    /// Leaves in visual order (left → right, top → bottom).
    public var leaves: [PaneLeafID] { Self.leaves(root).map(\.0) }

    public var count: Int { leaves.count }

    public func content(_ id: PaneLeafID) -> PaneContent? {
        Self.leaves(root).first { $0.0 == id }?.1
    }

    public var focusedContent: PaneContent { content(focused) ?? .empty }

    /// The primary note pane (falls back to the first note pane).
    public var mainLeaf: PaneLeafID {
        if let primary, let c = content(primary), Self.isNote(c) { return primary }
        return Self.leaves(root).first { Self.isNote($0.1) }?.0 ?? focused
    }

    static func isNote(_ c: PaneContent) -> Bool {
        if case .preview = c { return false }
        return true
    }

    /// Note (and empty) panes in visual order — previews left out.
    public var notePanes: [PaneLeafID] { Self.leaves(root).filter { Self.isNote($0.1) }.map(\.0) }

    /// Make `id` the primary pane (promote on close / focus hand-off).
    public mutating func setPrimary(_ id: PaneLeafID) {
        guard let c = content(id), Self.isNote(c) else { return }
        primary = id
    }

    /// The note path a pane shows, if it shows one.
    public func notePath(_ id: PaneLeafID) -> String? {
        if case let .note(path, _)? = content(id) { return path }
        return nil
    }

    /// The same tree without the preview leaves (their space goes to the
    /// note): the geometry the user sees while the split preview is
    /// hidden (reader / Live).
    public func withoutPreviews(except keep: Set<PaneLeafID> = []) -> PaneTree {
        var t = self
        for (id, c) in Self.leaves(root) {
            if case .preview = c, !keep.contains(id), let r = Self.remove(id, from: t.root) { t.root = r }
        }
        if !t.leaves.contains(t.focused) { t.focused = t.mainLeaf }
        return t
    }

    /// The preview pane following `id`, if any.
    public func preview(of id: PaneLeafID) -> PaneLeafID? {
        Self.leaves(root).first { $0.1 == .preview(of: id) }?.0
    }

    /// Frames of every leaf in unit space.
    public func frames() -> [PaneLeafID: PaneRect] {
        var out: [PaneLeafID: PaneRect] = [:]
        Self.layout(root, in: PaneRect(x: 0, y: 0, width: 1, height: 1), into: &out)
        return out
    }

    /// Weights of the split directly holding `id` and `id`'s index in it.
    public func parentSplit(of id: PaneLeafID) -> (axis: SplitAxis, weights: [Double], index: Int)? {
        Self.parent(of: id, in: root)
    }

    // MARK: Editing the tree

    /// Replace a leaf's content.
    public mutating func setContent(_ content: PaneContent, for id: PaneLeafID) {
        root = Self.map(root) { leafID, old in leafID == id ? content : old }
    }

    /// Split `target` (default: the focused pane) along `axis`. The new
    /// pane holds `content` (default: the same content — vim's `⌃w v`)
    /// and goes after (right / below) the target. Returns its id.
    @discardableResult
    public mutating func split(_ axis: SplitAxis, content: PaneContent? = nil, target: PaneLeafID? = nil,
                               ratio: Double = 0.5, focusNew: Bool = true, before: Bool = false) -> PaneLeafID {
        let t = target ?? focused
        let id = PaneLeafID(nextID)
        nextID += 1
        zoomed = nil
        let newContent = content ?? self.content(t) ?? .empty
        let r = min(1 - Self.minWeight, max(Self.minWeight, ratio))
        root = Self.splitUnit(root, target: t, axis: axis, newLeaf: .leaf(id, newContent), ratio: r, before: before)
        if focusNew { focus(id) }
        return id
    }

    /// Close a pane (`⌃w q`, `:q`). Its previews close with it. Returns
    /// false — and changes nothing — when it is the last note pane.
    @discardableResult
    public mutating func close(_ id: PaneLeafID? = nil) -> Bool {
        let target = id ?? focused
        let dependents = Self.leaves(root).filter { $0.1 == .preview(of: target) }.map(\.0)
        let remaining = Set(leaves).subtracting([target]).subtracting(dependents)
        guard !remaining.isEmpty else { return false }
        zoomed = nil
        for gone in [target] + dependents {
            if let r = Self.remove(gone, from: root) { root = r }
        }
        if !remaining.contains(focused) {
            if let p = previous, remaining.contains(p) { focused = p } else { focused = leaves.first ?? focused }
        }
        if let p = previous, !remaining.contains(p) { previous = nil }
        if let p = primary, !remaining.contains(p) {
            primary = nil
            if let c = content(focused), Self.isNote(c) { primary = focused } else { primary = notePanes.first }
        }
        return true
    }

    /// `⌃w o` with several note panes: keep the focused note pane (and
    /// its source + preview pair). It becomes the primary.
    public mutating func onlyNote() {
        var keep = focused
        if case let .preview(of: src)? = content(focused), content(src) != nil { keep = src }
        let pair = preview(of: keep)
        zoomed = nil
        for id in leaves where id != keep && id != pair {
            if let r = Self.remove(id, from: root) { root = r }
        }
        focused = keep
        previous = nil
        primary = keep
    }

    /// Close every note pane whose note no longer exists (`exists` gets
    /// the pane's path). The primary is never closed here — the app
    /// closes its note itself. Returns the closed panes.
    @discardableResult
    public mutating func prune(_ exists: (String) -> Bool) -> [PaneLeafID] {
        var gone: [PaneLeafID] = []
        for id in notePanes where id != mainLeaf {
            if let path = notePath(id), !exists(path), notePanes.count > 1, close(id) { gone.append(id) }
        }
        return gone
    }

    /// Keep only the focused pane (`⌃w o`); a focused preview keeps its
    /// note instead (a lone preview of nothing makes no sense).
    public mutating func only() {
        var keep = focused
        if case let .preview(of: src)? = content(focused), content(src) != nil { keep = src }
        let c = content(keep) ?? .empty
        zoomed = nil
        root = .leaf(keep, c)
        focused = keep
        previous = nil
        primary = keep
    }

    /// Equal weights everywhere (`⌃w =`).
    public mutating func equalize() {
        root = Self.equalized(root)
    }

    /// Set the weight of `id` inside its parent split (the rest share the
    /// remainder proportionally).
    public mutating func setRatio(_ ratio: Double, for id: PaneLeafID) {
        root = Self.reweighted(root, id: id, ratio: min(1 - Self.minWeight, max(Self.minWeight, ratio)))
    }

    // MARK: Focus

    public mutating func focus(_ id: PaneLeafID) {
        guard id != focused, leaves.contains(id) else { return }
        if zoomedLeaf != nil, !visibleLeaves.contains(id) { zoomed = nil }
        previous = focused
        focused = id
    }

    /// `⌃w h/j/k/l`: the nearest pane that way, overlapping the focused
    /// pane's span (its centre line first). False when none.
    @discardableResult
    public mutating func move(_ direction: PaneDirection) -> Bool {
        guard let target = neighbour(direction) else { return false }
        focus(target)
        return true
    }

    public func neighbour(_ direction: PaneDirection) -> PaneLeafID? {
        let f = frames()
        guard let cur = f[focused] else { return nil }
        let eps = 1e-9
        var best: (PaneLeafID, Double, Bool)?
        for (id, r) in f where id != focused {
            let adjacent: Bool
            let overlap: Double
            let hitsCentre: Bool
            switch direction {
            case .left:
                adjacent = abs(r.maxX - cur.x) < eps
                overlap = min(r.maxY, cur.maxY) - max(r.y, cur.y)
                hitsCentre = r.y <= cur.midY && r.maxY >= cur.midY
            case .right:
                adjacent = abs(r.x - cur.maxX) < eps
                overlap = min(r.maxY, cur.maxY) - max(r.y, cur.y)
                hitsCentre = r.y <= cur.midY && r.maxY >= cur.midY
            case .up:
                adjacent = abs(r.maxY - cur.y) < eps
                overlap = min(r.maxX, cur.maxX) - max(r.x, cur.x)
                hitsCentre = r.x <= cur.midX && r.maxX >= cur.midX
            case .down:
                adjacent = abs(r.y - cur.maxY) < eps
                overlap = min(r.maxX, cur.maxX) - max(r.x, cur.x)
                hitsCentre = r.x <= cur.midX && r.maxX >= cur.midX
            }
            guard adjacent, overlap > eps else { continue }
            if let b = best {
                if (hitsCentre && !b.2) || (hitsCentre == b.2 && overlap > b.1 + eps) || (id == previous && abs(overlap - b.1) < eps) {
                    best = (id, overlap, hitsCentre)
                }
            } else {
                best = (id, overlap, hitsCentre)
            }
        }
        return best?.0
    }

    /// `⌃w w` / `⌃w W`.
    @discardableResult
    public mutating func cycle(_ step: Int) -> Bool {
        let all = leaves
        guard all.count > 1, let i = all.firstIndex(of: focused) else { return false }
        focus(all[((i + step) % all.count + all.count) % all.count])
        return true
    }

    /// `⌃w p`.
    @discardableResult
    public mutating func focusPrevious() -> Bool {
        guard let p = previous, leaves.contains(p) else { return false }
        focus(p)
        return true
    }

    // MARK: Source + preview pair

    /// Show / hide the preview pane beside `id` (default: the main note).
    public mutating func setPreview(_ on: Bool, for id: PaneLeafID? = nil, ratio: Double = 0.5) {
        let src = id ?? mainLeaf
        let existing = preview(of: src)
        if on, existing == nil {
            let id = PaneLeafID(nextID)
            nextID += 1
            let r = min(1 - Self.minWeight, max(Self.minWeight, ratio))
            root = Self.wrapLeaf(root, target: src, newLeaf: .leaf(id, .preview(of: src)), ratio: r)
        } else if !on, let existing {
            close(existing)
        }
    }

    /// The note's share of its source + preview split.
    public func previewRatio(for id: PaneLeafID? = nil) -> Double? {
        let src = id ?? mainLeaf
        guard preview(of: src) != nil, let p = parentSplit(of: src) else { return nil }
        return p.weights[p.index]
    }

    // MARK: Resizing (dividers, `⌃w < > + -`)

    /// Child-index path from the root to the split node directly holding
    /// leaf `id`'s unit, for every split on the way: `[(path, index)]`.
    func ancestry(of id: PaneLeafID) -> [(path: [Int], index: Int)]? {
        func walk(_ n: PaneNode, _ path: [Int]) -> [(path: [Int], index: Int)]? {
            guard case let .split(_, kids, _) = n else { return nil }
            for (i, k) in kids.enumerated() {
                if case let .leaf(l, _) = k, l == id { return [(path, i)] }
                if let rest = walk(k, path + [i]) { return [(path, i)] + rest }
            }
            return nil
        }
        return walk(root, [])
    }

    public func node(at path: [Int]) -> PaneNode? {
        var n = root
        for i in path {
            guard case let .split(_, kids, _) = n, kids.indices.contains(i) else { return nil }
            n = kids[i]
        }
        return n
    }

    private mutating func updateNode(at path: [Int], _ f: (PaneNode) -> PaneNode) {
        func go(_ n: PaneNode, _ rest: ArraySlice<Int>) -> PaneNode {
            guard let i = rest.first else { return f(n) }
            guard case let .split(a, kids, w) = n, kids.indices.contains(i) else { return n }
            var k = kids
            k[i] = go(kids[i], rest.dropFirst())
            return .split(a, k, w)
        }
        root = go(root, path[...])
    }

    /// Drag the divider after child `index` of the split at `path` to
    /// `at` (0…1 along the split, from its start). Both neighbours keep at
    /// least `minSize` (web `resizeSplit`).
    public mutating func resizeDivider(at path: [Int], index: Int, to at: Double) {
        updateNode(at: path) { n in
            guard case let .split(a, kids, sizes) = n, index >= 0, index < kids.count - 1 else { return n }
            let before = sizes[..<index].reduce(0, +)
            let pair = sizes[index] + sizes[index + 1]
            let lo = min(Self.minSize, pair / 2)
            let left = min(pair - lo, max(lo, at - before))
            var w = sizes
            w[index] = left
            w[index + 1] = pair - left
            return .split(a, kids, w)
        }
    }

    /// Grow (`delta` > 0) or shrink pane `id` along `axis` by moving the
    /// nearest divider of the closest enclosing split on that axis (vim
    /// `⌃w >` `<` for `.vertical`, `+` `-` for `.horizontal`). A pane in a
    /// source + preview pair resizes the pair as one unit.
    public mutating func nudge(_ id: PaneLeafID? = nil, axis: SplitAxis, by delta: Double) {
        let target = id ?? focused
        guard let chain = ancestry(of: target) else { return }
        for step in chain.reversed() {
            guard case let .split(a, kids, sizes)? = node(at: step.path), a == axis else { continue }
            // The source + preview pair resizes as one unit.
            if step.path == chain.last?.path, let n = node(at: step.path), Self.isUnit(n, target) { continue }
            let i = step.index
            let before = sizes[..<i].reduce(0, +)
            if i < kids.count - 1 {
                resizeDivider(at: step.path, index: i, to: before + sizes[i] + delta)
            } else {
                resizeDivider(at: step.path, index: i - 1, to: before - delta)
            }
            return
        }
    }

    // MARK: Helpers (pure recursion)

    /// A leaf, or a source + preview pair, holding `target`.
    static func isUnit(_ n: PaneNode, _ target: PaneLeafID) -> Bool {
        switch n {
        case let .leaf(id, _): return id == target
        case let .split(.vertical, kids, _):
            guard kids.count == 2, case let .leaf(l, _) = kids[0], l == target,
                  case .leaf(_, .preview(of: target)) = kids[1] else { return false }
            return true
        default: return false
        }
    }

    /// `before`: the new pane goes left / above the target (a drop on
    /// its left or top edge) instead of right / below.
    static func splitUnit(_ n: PaneNode, target: PaneLeafID, axis: SplitAxis, newLeaf: PaneNode, ratio: Double,
                          before: Bool = false) -> PaneNode {
        if isUnit(n, target) {
            return before ? .split(axis, [newLeaf, n], [1 - ratio, ratio]) : .split(axis, [n, newLeaf], [ratio, 1 - ratio])
        }
        guard case let .split(a, kids, w) = n else { return n }
        if a == axis, let i = kids.firstIndex(where: { isUnit($0, target) }) {
            var k = kids, ws = w
            let share = ws[i]
            ws[i] = share * ratio
            k.insert(newLeaf, at: before ? i : i + 1)
            ws.insert(share * (1 - ratio), at: before ? i : i + 1)
            return .split(a, k, ws)
        }
        return .split(a, kids.map { splitUnit($0, target: target, axis: axis, newLeaf: newLeaf, ratio: ratio, before: before) }, w)
    }

    /// Replace leaf `target` with a nested vertical [target, newLeaf].
    static func wrapLeaf(_ n: PaneNode, target: PaneLeafID, newLeaf: PaneNode, ratio: Double) -> PaneNode {
        switch n {
        case let .leaf(id, _):
            return id == target ? .split(.vertical, [n, newLeaf], [ratio, 1 - ratio]) : n
        case let .split(a, kids, w):
            return .split(a, kids.map { wrapLeaf($0, target: target, newLeaf: newLeaf, ratio: ratio) }, w)
        }
    }

    static func leaves(_ n: PaneNode) -> [(PaneLeafID, PaneContent)] {
        switch n {
        case let .leaf(id, c): return [(id, c)]
        case let .split(_, kids, _): return kids.flatMap(leaves)
        }
    }

    static func map(_ n: PaneNode, _ f: (PaneLeafID, PaneContent) -> PaneContent) -> PaneNode {
        switch n {
        case let .leaf(id, c): return .leaf(id, f(id, c))
        case let .split(a, kids, w): return .split(a, kids.map { map($0, f) }, w)
        }
    }

    static func layout(_ n: PaneNode, in r: PaneRect, into out: inout [PaneLeafID: PaneRect]) {
        switch n {
        case let .leaf(id, _):
            out[id] = r
        case let .split(axis, kids, weights):
            var offset = 0.0
            for (i, kid) in kids.enumerated() {
                let w = i < weights.count ? weights[i] : 1 / Double(kids.count)
                // The last child takes the remainder so edges meet exactly.
                let isLast = i == kids.count - 1
                let sub: PaneRect
                if axis == .vertical {
                    let width = isLast ? r.width - offset : r.width * w
                    sub = PaneRect(x: r.x + offset, y: r.y, width: width, height: r.height)
                    offset += width
                } else {
                    let height = isLast ? r.height - offset : r.height * w
                    sub = PaneRect(x: r.x, y: r.y + offset, width: r.width, height: height)
                    offset += height
                }
                layout(kid, in: sub, into: &out)
            }
        }
    }

    static func splitLeaf(_ n: PaneNode, target: PaneLeafID, axis: SplitAxis, newLeaf: PaneNode, ratio: Double) -> PaneNode {
        switch n {
        case let .leaf(id, _):
            guard id == target else { return n }
            return .split(axis, [n, newLeaf], [ratio, 1 - ratio])
        case let .split(a, kids, w):
            // Same axis: insert as a sibling (vim keeps one row of windows).
            if a == axis, let i = kids.firstIndex(where: { if case let .leaf(id, _) = $0 { return id == target }; return false }) {
                var k = kids, ws = w
                let share = ws[i]
                ws[i] = share * ratio
                k.insert(newLeaf, at: i + 1)
                ws.insert(share * (1 - ratio), at: i + 1)
                return .split(a, k, ws)
            }
            return .split(a, kids.map { splitLeaf($0, target: target, axis: axis, newLeaf: newLeaf, ratio: ratio) }, w)
        }
    }

    /// nil when the whole node goes.
    static func remove(_ target: PaneLeafID, from n: PaneNode) -> PaneNode? {
        switch n {
        case let .leaf(id, _):
            return id == target ? nil : n
        case let .split(a, kids, w):
            var k: [PaneNode] = []
            var ws: [Double] = []
            for (i, kid) in kids.enumerated() {
                if let r = remove(target, from: kid) {
                    k.append(r)
                    ws.append(i < w.count ? w[i] : 0)
                }
            }
            if k.isEmpty { return nil }
            if k.count == 1 { return k[0] }
            let sum = ws.reduce(0, +)
            return .split(a, k, sum > 0 ? ws.map { $0 / sum } : Array(repeating: 1 / Double(k.count), count: k.count))
        }
    }

    static func equalized(_ n: PaneNode) -> PaneNode {
        switch n {
        case .leaf: return n
        case let .split(a, kids, _):
            return .split(a, kids.map(equalized), Array(repeating: 1 / Double(kids.count), count: kids.count))
        }
    }

    static func reweighted(_ n: PaneNode, id: PaneLeafID, ratio: Double) -> PaneNode {
        switch n {
        case .leaf: return n
        case let .split(a, kids, w):
            if let i = kids.firstIndex(where: { if case let .leaf(l, _) = $0 { return l == id }; return false }) {
                let rest = w.enumerated().filter { $0.offset != i }.map(\.element).reduce(0, +)
                var ws = w
                for j in ws.indices where j != i {
                    ws[j] = rest > 0 ? w[j] / rest * (1 - ratio) : (1 - ratio) / Double(ws.count - 1)
                }
                ws[i] = ratio
                return .split(a, kids, ws)
            }
            return .split(a, kids.map { reweighted($0, id: id, ratio: ratio) }, w)
        }
    }

    static func parent(of id: PaneLeafID, in n: PaneNode) -> (axis: SplitAxis, weights: [Double], index: Int)? {
        guard case let .split(a, kids, w) = n else { return nil }
        if let i = kids.firstIndex(where: { if case let .leaf(l, _) = $0 { return l == id }; return false }) {
            return (a, w, i)
        }
        for k in kids { if let p = parent(of: id, in: k) { return p } }
        return nil
    }
}

// MARK: - Persistence (per book, per device)

/// Saves each book's pane layout to one JSON file on this device
/// (`~/.config/lumi/apple-panes.json`). Never synced: a layout is
/// about this screen.
public final class PaneLayoutStore: @unchecked Sendable {
    public static let shared = PaneLayoutStore(url: ConfigPaths.directory.appendingPathComponent("apple-panes.json"))

    private let url: URL
    private let lock = NSLock()
    private var cache: [String: PaneTree]?

    public init(url: URL) {
        self.url = url
    }

    public func layout(forBook id: String) -> PaneTree? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()[id]
    }

    public func save(_ tree: PaneTree, forBook id: String) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        // Zoom is never remembered (SPEC-PARTE2 §3).
        var tree = tree
        tree.unzoom()
        guard all[id] != tree else { return }
        all[id] = tree
        cache = all
        // Cap the file: keep it small even with hundreds of books.
        if all.count > 500 { all = Dictionary(uniqueKeysWithValues: all.prefix(500).map { ($0.key, $0.value) }) }
        if let data = try? JSONEncoder().encode(all) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    public func remove(book id: String) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        guard all.removeValue(forKey: id) != nil else { return }
        cache = all
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }

    private func loadLocked() -> [String: PaneTree] {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: PaneTree].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }
}

// MARK: - Book memory (last opened note, recent notes)

/// Per book, per device: the last opened note (opening a book shows it,
/// SPEC-PARTE2 §2) and the recent notes the empty book home lists.
/// `~/.config/lumi/apple-book-memory.json`; never synced.
public final class BookMemoryStore: @unchecked Sendable {
    public static let shared = BookMemoryStore(url: ConfigPaths.directory.appendingPathComponent("apple-book-memory.json"))
    public static let recentLimit = 8

    public struct Entry: Codable, Equatable, Sendable {
        public var lastNote: String?
        public var recent: [String] = []
    }

    private let url: URL
    private let lock = NSLock()
    private var cache: [String: Entry]?

    public init(url: URL) { self.url = url }

    public func lastNote(forBook id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()[id]?.lastNote
    }

    public func recent(forBook id: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()[id]?.recent ?? []
    }

    /// A note was opened in the book (moves to the front of the recents).
    public func noteOpened(_ path: String, inBook id: String) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        var e = all[id] ?? Entry()
        guard e.lastNote != path || e.recent.first != path else { return }
        e.lastNote = path
        e.recent.removeAll { $0 == path }
        e.recent.insert(path, at: 0)
        if e.recent.count > Self.recentLimit { e.recent.removeLast(e.recent.count - Self.recentLimit) }
        all[id] = e
        saveLocked(all)
    }

    /// The note is gone (deleted / renamed): forget it.
    public func forget(_ path: String, inBook id: String) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        guard var e = all[id] else { return }
        if e.lastNote == path { e.lastNote = nil }
        e.recent.removeAll { $0 == path }
        all[id] = e
        saveLocked(all)
    }

    public func remove(book id: String) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        guard all.removeValue(forKey: id) != nil else { return }
        saveLocked(all)
    }

    private func saveLocked(_ all: [String: Entry]) {
        cache = all
        if let data = try? JSONEncoder().encode(all) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadLocked() -> [String: Entry] {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }
}
