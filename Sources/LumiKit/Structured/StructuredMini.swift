import Foundation

// MARK: - Kind glyphs and labels

extension NoteKind {
    /// SF Symbol for the kind (explorer rows, palette, pane headers,
    /// breadcrumbs, hover cards).
    public var symbol: String {
        switch self {
        case .markdown: return "doc.text"
        case .kanban: return "rectangle.split.3x1"
        case .canvas: return "rectangle.3.group"
        }
    }

    /// Short suffix that tells two same-titled items apart ("test · canvas").
    public var suffix: String {
        switch self {
        case .markdown: return "note"
        case .kanban: return "board"
        case .canvas: return "canvas"
        }
    }

    /// Display names for a list of (title, kind): a title shared by items
    /// of different kinds gets a subtle kind suffix; unique ones stay as
    /// they are.
    public static func disambiguated(_ items: [(title: String, kind: NoteKind)]) -> [String] {
        var kinds: [String: Set<NoteKind>] = [:]
        for i in items { kinds[i.title.lowercased(), default: []].insert(i.kind) }
        return items.map { i in
            (kinds[i.title.lowercased()]?.count ?? 0) > 1 ? "\(i.title) · \(i.kind.suffix)" : i.title
        }
    }
}

// MARK: - Mini renders (explorer preview, hover cards)

/// A read-only, simplified picture of a structured note: what the
/// explorer's preview column and hover cards draw instead of raw text.
public enum StructuredMini: Sendable, Equatable {
    case canvas(CanvasMini)
    case board(KanbanMini)

    public var kind: NoteKind {
        switch self {
        case .canvas: return .canvas
        case .board: return .kanban
        }
    }

    /// The mini for a note, when it is a canvas or a board (else nil).
    public static func make(path: String, text: String, kind: NoteKind? = nil) -> StructuredMini? {
        switch kind ?? NoteKind.resolve(path: path, text: text) {
        case .canvas: return CanvasMini.make(text).map(StructuredMini.canvas)
        case .kanban: return .board(KanbanMini.make(text))
        case .markdown: return nil
        }
    }
}

/// A canvas reduced for a thumbnail: capped node / edge counts, text
/// nodes as a few plain lines, file nodes as titled cards (contents are
/// never loaded).
public struct CanvasMini: Sendable, Equatable {
    public struct Node: Sendable, Equatable, Identifiable {
        public var id: String
        public var type: CanvasNodeType
        public var rect: CGRect
        public var color: CanvasColor?
        /// Group label, file title, link host, or the text's first line.
        public var title: String
        /// A few plain lines of a text node (markdown syntax stripped).
        public var lines: [String]
    }

    public struct Edge: Sendable, Equatable {
        public var from: CGPoint
        public var to: CGPoint
        public var color: CanvasColor?
        public var arrow: Bool
    }

    public var nodes: [Node]
    public var edges: [Edge]
    /// Union of every drawn node.
    public var bounds: CGRect
    /// Nodes / edges left out by the caps.
    public var hiddenNodes: Int
    public var hiddenEdges: Int

    public static let maxNodes = 150
    public static let maxEdges = 300
    public static let maxLines = 4

    /// nil when the text is not a canvas.
    public static func make(_ text: String, maxNodes: Int = maxNodes, maxEdges: Int = maxEdges) -> CanvasMini? {
        guard let parsed = Canvas.parse(text).parsed else { return nil }
        // Groups first (drawn under), then the biggest nodes win the cap.
        let ordered = parsed.nodes.sorted { a, b in
            if (a.type == .group) != (b.type == .group) { return a.type == .group }
            return a.width * a.height > b.width * b.height
        }
        let kept = Array(ordered.prefix(maxNodes))
        var byID: [String: CGRect] = [:]
        var nodes: [Node] = []
        for n in kept {
            let r = CGRect(x: n.x, y: n.y, width: max(1, n.width), height: max(1, n.height))
            byID[n.id] = r
            nodes.append(Node(id: n.id, type: n.type, rect: r, color: Canvas.color(n.color),
                              title: title(n), lines: n.type == .text ? plainLines(n.text, max: maxLines) : []))
        }
        var edges: [Edge] = []
        var dropped = 0
        for e in parsed.edges {
            guard let a = byID[e.fromNode], let b = byID[e.toNode] else { dropped += 1; continue }
            guard edges.count < maxEdges else { dropped += 1; continue }
            edges.append(Edge(from: anchor(a, e.fromSide, toward: b), to: anchor(b, e.toSide, toward: a),
                              color: Canvas.color(e.color), arrow: e.arrowAtEnd))
        }
        let bounds = nodes.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        return CanvasMini(nodes: nodes, edges: edges, bounds: bounds.isNull ? .zero : bounds,
                          hiddenNodes: parsed.nodes.count - kept.count, hiddenEdges: dropped)
    }

    /// Scale + offset that fit `bounds` into `size` with `padding`
    /// (never enlarging past 1×).
    public static func fit(_ bounds: CGRect, into size: CGSize, padding: CGFloat = 12) -> (scale: CGFloat, offset: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return (1, CGPoint(x: padding, y: padding)) }
        let w = max(1, size.width - 2 * padding), h = max(1, size.height - 2 * padding)
        let s = min(1, min(w / bounds.width, h / bounds.height))
        let ox = padding + (w - bounds.width * s) / 2 - bounds.minX * s
        let oy = padding + (h - bounds.height * s) / 2 - bounds.minY * s
        return (s, CGPoint(x: ox, y: oy))
    }

    static func title(_ n: CanvasNode) -> String {
        switch n.type {
        case .group: return n.label ?? ""
        case .file:
            let stem = (n.file as NSString).lastPathComponent
            return n.file.lowercased().hasSuffix(".md") ? String(stem.dropLast(3)) : stem
        case .link: return URL(string: n.url)?.host ?? n.url
        case .text: return plainLines(n.text, max: 1).first ?? ""
        }
    }

    /// Markdown → a few plain lines (headings, emphasis, links, list
    /// markers and code fences stripped).
    public static func plainLines(_ text: String, max: Int) -> [String] {
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("```") { continue }
            while l.hasPrefix("#") || l.hasPrefix(">") { l = String(l.dropFirst()).trimmingCharacters(in: .whitespaces) }
            for p in ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ "] where l.hasPrefix(p) {
                l = (p.contains("[") ? (p.contains(" ] ") ? "☐ " : "☑ ") : "• ") + l.dropFirst(p.count)
                break
            }
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            if let r = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\([^)]*\\)") {
                l = r.stringByReplacingMatches(in: l, range: NSRange(l.startIndex..., in: l), withTemplate: "$1")
            }
            if l.isEmpty { continue }
            out.append(l.count > 80 ? String(l.prefix(79)) + "…" : l)
            if out.count >= max { break }
        }
        return out
    }

    static func anchor(_ r: CGRect, _ side: CanvasSide?, toward other: CGRect) -> CGPoint {
        let s = side ?? {
            let dx = other.midX - r.midX, dy = other.midY - r.midY
            return abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .bottom : .top)
        }()
        switch s {
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        }
    }
}

/// A kanban board reduced for a thumbnail: lanes with their first cards.
public struct KanbanMini: Sendable, Equatable {
    public struct Lane: Sendable, Equatable {
        public var title: String
        public var count: Int
        public var cards: [String]
        public var checked: [Bool]
        public var complete: Bool
    }

    public var lanes: [Lane]
    public var hiddenLanes: Int

    public static func make(_ text: String, maxLanes: Int = 6, cardsPerLane: Int = 4) -> KanbanMini {
        let board = Kanban.parse(text)
        let lanes = board.lanes.prefix(maxLanes).map { lane in
            let cards = lane.cards.prefix(cardsPerLane)
            return Lane(title: lane.title, count: lane.cards.count,
                        cards: cards.map { CanvasMini.plainLines($0.text, max: 1).first ?? "" },
                        checked: cards.map(\.checked), complete: lane.complete)
        }
        return KanbanMini(lanes: Array(lanes), hiddenLanes: max(0, board.lanes.count - maxLanes))
    }
}

// MARK: - Reading | Edit | Source keys (SPEC-PARTE2 §5a)

/// Mode keys around a board / canvas. Pure.
public enum StructuredModeKeys {
    public enum Request: Sendable, Equatable { case edit, reading }

    /// Before the board sees the key: `i` / `e` in Reading ask for Edit.
    public static func before(_ k: StructuredKey, reading: Bool) -> Request? {
        guard reading, !k.ctrl, !k.meta, !k.alt, k.key == "i" || k.key == "e" else { return nil }
        return .edit
    }

    /// After the board left the key unhandled: `Esc` / `q` in Edit (with
    /// nothing selected — the board would have consumed it otherwise)
    /// go back to Reading.
    public static func after(_ k: StructuredKey, reading: Bool, handled: Bool) -> Request? {
        guard !reading, !handled, !k.ctrl, !k.meta, !k.alt, k.key == "Escape" || k.key == "q" else { return nil }
        return .reading
    }
}
