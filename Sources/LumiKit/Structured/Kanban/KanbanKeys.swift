import Foundation

/// A key press as the structured views see it (the web's `KeyboardEvent`
/// subset): `key` is the printed character (`"j"`, `"G"`, `"+"`) or a
/// DOM key name (`"Enter"`, `"Escape"`, `"Tab"`, `"Backspace"`,
/// `"Delete"`, `"ArrowLeft"` …).
public struct StructuredKey: Sendable, Equatable {
    public var key: String
    public var shift: Bool
    public var ctrl: Bool
    public var meta: Bool
    public var alt: Bool

    public init(_ key: String, shift: Bool = false, ctrl: Bool = false, meta: Bool = false, alt: Bool = false) {
        self.key = key
        self.shift = shift
        self.ctrl = ctrl
        self.meta = meta
        self.alt = alt
    }

    /// From a shell `KeyStroke` (+ the shift state, which `KeyStroke`
    /// does not carry for special keys).
    public init?(stroke: KeyStroke, shift: Bool = false) {
        let name: String
        if let s = stroke.special {
            switch s {
            case .up: name = "ArrowUp"
            case .down: name = "ArrowDown"
            case .left: name = "ArrowLeft"
            case .right: name = "ArrowRight"
            case .enter: name = "Enter"
            case .escape: name = "Escape"
            case .backspace: name = "Backspace"
            case .tab: name = "Tab"
            default: return nil
            }
        } else if let c = stroke.chars, !c.isEmpty {
            if c == "\u{7F}" { name = "Delete" } else { name = c }
        } else {
            return nil
        }
        self.init(name, shift: shift, ctrl: stroke.control, meta: stroke.command, alt: stroke.option)
    }
}

// Board keyboard model (SPEC-PARTE2 §5), pure — port of
// web-client `lib/kanban/kanban-keys.ts`.
//
//   h/l ←/→   previous/next column      j/k ↓/↑  next/previous card
//   gg / G    first / last card         H/L      move card to prev/next column
//   J/K       move card down/up         a        new card at end of column
//   o / O     new card below / above    A        new column
//   Enter / i edit card inline          x        toggle done
//   dd        delete card (confirm)     /        filter
//   r         rename column             < / >    move column left/right
//   u / C-r   undo / redo               Esc      clear pending / filter

public struct KanbanCursor: Sendable, Equatable {
    public var lane: Int
    /// -1 when the lane has no (visible) cards.
    public var card: Int
    public init(lane: Int, card: Int) { self.lane = lane; self.card = card }
}

public enum KanbanKeyAction: Sendable, Equatable {
    case cursor(KanbanCursor)
    case moveCard(toLane: Int, toIndex: Int)
    case newCard(lane: Int, index: Int)
    case newLane
    case edit
    case toggle
    case delete
    case filter
    case rename
    case moveLane(toIndex: Int)
    case undo
    case redo
    case escape
}

public func clampKanbanCursor(_ c: KanbanCursor, _ shape: [Int]) -> KanbanCursor {
    guard !shape.isEmpty else { return KanbanCursor(lane: 0, card: -1) }
    let lane = max(0, min(c.lane, shape.count - 1))
    let n = shape[lane]
    return KanbanCursor(lane: lane, card: n == 0 ? -1 : max(0, min(c.card < 0 ? 0 : c.card, n - 1)))
}

public struct KanbanKeys: Sendable {
    /// Pending prefix (`d`, `g`) or nil.
    public var pending: String?

    public init() {}

    public mutating func reset() { pending = nil }

    public mutating func feed(_ e: StructuredKey, _ cursor: KanbanCursor, _ shape: [Int]) -> KanbanKeyAction? {
        if e.meta || e.alt { return nil }
        let cur = clampKanbanCursor(cursor, shape)
        let lanes = shape.count
        let n = lanes > 0 ? shape[cur.lane] : 0
        let k = e.key

        if e.ctrl {
            pending = nil
            return k == "r" ? .redo : nil
        }

        let p = pending
        pending = nil
        if p == "d" { return k == "d" && cur.card >= 0 ? .delete : nil }
        if p == "g" { return k == "g" && n > 0 ? .cursor(KanbanCursor(lane: cur.lane, card: 0)) : nil }

        switch k {
        case "h", "ArrowLeft":
            return lanes > 0 ? .cursor(clampKanbanCursor(KanbanCursor(lane: cur.lane - 1, card: cur.card), shape)) : nil
        case "l", "ArrowRight":
            return lanes > 0 ? .cursor(clampKanbanCursor(KanbanCursor(lane: cur.lane + 1, card: cur.card), shape)) : nil
        case "j", "ArrowDown":
            return n > 0 ? .cursor(KanbanCursor(lane: cur.lane, card: min(n - 1, cur.card + 1))) : nil
        case "k", "ArrowUp":
            return n > 0 ? .cursor(KanbanCursor(lane: cur.lane, card: max(0, cur.card - 1))) : nil
        case "G":
            return n > 0 ? .cursor(KanbanCursor(lane: cur.lane, card: n - 1)) : nil
        case "g":
            pending = "g"
            return nil
        case "H":
            if cur.card < 0 || cur.lane == 0 { return nil }
            return .moveCard(toLane: cur.lane - 1, toIndex: min(cur.card, shape[cur.lane - 1]))
        case "L":
            if cur.card < 0 || cur.lane >= lanes - 1 { return nil }
            return .moveCard(toLane: cur.lane + 1, toIndex: min(cur.card, shape[cur.lane + 1]))
        case "J":
            if cur.card < 0 || cur.card >= n - 1 { return nil }
            return .moveCard(toLane: cur.lane, toIndex: cur.card + 1)
        case "K":
            if cur.card <= 0 { return nil }
            return .moveCard(toLane: cur.lane, toIndex: cur.card - 1)
        case "a":
            return lanes > 0 ? .newCard(lane: cur.lane, index: n) : .newLane
        case "o":
            return lanes > 0 ? .newCard(lane: cur.lane, index: cur.card < 0 ? 0 : cur.card + 1) : .newLane
        case "O":
            return lanes > 0 ? .newCard(lane: cur.lane, index: max(0, cur.card)) : .newLane
        case "A":
            return .newLane
        case "Enter", "i":
            return cur.card >= 0 ? .edit : nil
        case "x":
            return cur.card >= 0 ? .toggle : nil
        case "d":
            if cur.card < 0 { return nil }
            pending = "d"
            return nil
        case "/":
            return .filter
        case "r":
            return lanes > 0 ? .rename : nil
        case "<":
            return cur.lane > 0 ? .moveLane(toIndex: cur.lane - 1) : nil
        case ">":
            return cur.lane < lanes - 1 ? .moveLane(toIndex: cur.lane + 1) : nil
        case "u":
            return .undo
        case "Escape":
            return .escape
        default:
            return nil
        }
    }
}
