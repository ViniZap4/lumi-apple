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
        case .kanban: return [.board, .source]
        case .canvas: return [.canvas, .source]
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
        case .board: return "Board"
        case .canvas: return "Canvas"
        }
    }

    /// The view edits text (vim editor mounted).
    public var isEditing: Bool { self == .live || self == .source }
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

    /// Weight bounds for a resized split child.
    public static let minWeight = 0.15

    public init(_ content: PaneContent = .empty) {
        let id = PaneLeafID(1)
        root = .leaf(id, content)
        focused = id
        nextID = 2
    }

    // MARK: Reading

    /// Leaves in visual order (left → right, top → bottom).
    public var leaves: [PaneLeafID] { Self.leaves(root).map(\.0) }

    public var count: Int { leaves.count }

    public func content(_ id: PaneLeafID) -> PaneContent? {
        Self.leaves(root).first { $0.0 == id }?.1
    }

    public var focusedContent: PaneContent { content(focused) ?? .empty }

    /// The first note pane (the main note while splits are not exposed).
    public var mainLeaf: PaneLeafID {
        Self.leaves(root).first { if case .note = $0.1 { return true }; if case .empty = $0.1 { return true }; return false }?.0 ?? focused
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
                               ratio: Double = 0.5, focusNew: Bool = true) -> PaneLeafID {
        let t = target ?? focused
        let id = PaneLeafID(nextID)
        nextID += 1
        let newContent = content ?? self.content(t) ?? .empty
        let r = min(1 - Self.minWeight, max(Self.minWeight, ratio))
        root = Self.splitLeaf(root, target: t, axis: axis, newLeaf: .leaf(id, newContent), ratio: r)
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
        for gone in [target] + dependents {
            if let r = Self.remove(gone, from: root) { root = r }
        }
        if !remaining.contains(focused) {
            if let p = previous, remaining.contains(p) { focused = p } else { focused = leaves.first ?? focused }
        }
        if let p = previous, !remaining.contains(p) { previous = nil }
        return true
    }

    /// Keep only the focused pane (`⌃w o`); a focused preview keeps its
    /// note instead (a lone preview of nothing makes no sense).
    public mutating func only() {
        var keep = focused
        if case let .preview(of: src)? = content(focused), content(src) != nil { keep = src }
        let c = content(keep) ?? .empty
        root = .leaf(keep, c)
        focused = keep
        previous = nil
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
            split(.vertical, content: .preview(of: src), target: src, ratio: ratio, focusNew: false)
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

    // MARK: Helpers (pure recursion)

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
