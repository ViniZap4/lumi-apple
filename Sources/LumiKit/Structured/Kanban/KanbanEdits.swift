import Foundation

// Kanban edit planner: board operations → minimal ranged text edits.
// Port of web-client `lib/kanban/kanban-edits.ts`.
//
// Pure: takes a parsed board and an operation, returns disjoint
// `TextEdit`s in the coordinates of `board.text`. The caller applies them
// right to left in ONE transaction (`LiveText.apply`), so a move is a
// delete plus an insert in the same Yjs transaction (SPEC-PARTE2 §5).
// Nothing outside the touched card/lane changes, so the settings block
// and unknown content survive byte for byte.

public enum KanbanOp: Sendable, Equatable {
    case addCard(lane: Int, index: Int, text: String, checked: Bool = false)
    case editCard(lane: Int, card: Int, text: String)
    case toggleCard(lane: Int, card: Int)
    case deleteCard(lane: Int, card: Int)
    /// `toIndex` counts positions in the target lane with the card removed.
    case moveCard(lane: Int, card: Int, toLane: Int, toIndex: Int)
    case addLane(index: Int, title: String)
    case renameLane(lane: Int, title: String)
    case deleteLane(lane: Int)
    /// `toIndex` counts positions with the lane removed.
    case moveLane(lane: Int, toIndex: Int)

    public var name: String {
        switch self {
        case .addCard: return "addCard"
        case .editCard: return "editCard"
        case .toggleCard: return "toggleCard"
        case .deleteCard: return "deleteCard"
        case .moveCard: return "moveCard"
        case .addLane: return "addLane"
        case .renameLane: return "renameLane"
        case .deleteLane: return "deleteLane"
        case .moveLane: return "moveLane"
        }
    }
}

public enum KanbanEdits {
    static let lineBreaks = Rx("[\\r\\n]+")
    static let trailingWS = Rx("\\s+$")

    static func oneLine(_ s: String) -> String {
        lineBreaks.replace(s, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func u16(_ s: String, _ i: Int) -> UInt16? {
        let ns = s as NSString
        return i >= 0 && i < ns.length ? ns.character(at: i) : nil
    }

    /// Card lines without their trailing line break.
    static func cardBody(_ b: KanbanBoard, _ c: KanbanCard) -> String { b.slice(c.start, c.textEnd) }

    /// Range that removes a card, line break included (EOF cards eat the previous break).
    static func cardDeleteRange(_ b: KanbanBoard, _ c: KanbanCard) -> (from: Int, to: Int) {
        if c.end > c.textEnd { return (c.start, c.end) }
        var from = c.start
        if from > 0, u16(b.text, from - 1) == 10 {
            from -= (from > 1 && u16(b.text, from - 2) == 13) ? 2 : 1
        }
        return (from, c.end)
    }

    /// Where a card line goes for (lane, index), ignoring `skip`.
    static func cardInsertion(_ b: KanbanBoard, _ lane: KanbanLane, _ index: Int, skip: KanbanCard?) -> (at: Int, before: String, after: String) {
        let eol = b.eol
        let t = b.text as NSString
        let n = t.length
        let list = lane.cards.filter { c in skip.map { !($0.start == c.start && $0.end == c.end) } ?? true }
        let i = max(0, min(index, list.count))
        if i < list.count { return (list[i].start, "", eol) }
        if let last = list.last {
            if last.end > last.textEnd { return (last.end, "", eol) }
            return (last.end, eol, "")
        }
        // Empty lane: after the heading, one blank line and the **Complete** flag.
        var at = lane.headingEnd
        let endsWithNL = n > 0 && t.character(at: n - 1) == 10
        if at == lane.start || (at == n && !endsWithNL) {
            return (n, eol + eol, "")
        }
        func lineAt(_ p: Int) -> (s: String, end: Int) {
            let r = t.range(of: "\n", options: .literal, range: NSRange(location: p, length: n - p))
            let nl = r.location == NSNotFound ? -1 : r.location
            let end = nl < 0 ? n : nl + 1
            var s = t.substring(with: NSRange(location: p, length: (nl < 0 ? n : nl) - p))
            if s.hasSuffix("\r") { s.removeLast() }
            return (s, end)
        }
        var blank = false
        if at < lane.end {
            let l = lineAt(at)
            if Kanban.blank.test(l.s) {
                blank = true
                at = l.end
            }
        }
        if at < lane.end {
            let l = lineAt(at)
            if Kanban.complete.test(l.s) { at = l.end }
        }
        let atEOFNoBreak = at == n && n > 0 && !endsWithNL
        return (at, (atEOFNoBreak ? eol : "") + (blank ? "" : eol), atEOFNoBreak ? "" : eol)
    }

    /// Where a lane goes for `index` (with `skip` removed).
    static func laneInsertion(_ b: KanbanBoard, _ index: Int, skip: KanbanLane?) -> (at: Int, prefix: String) {
        let list = b.lanes.filter { l in skip.map { $0.start != l.start } ?? true }
        let i = max(0, min(index, list.count))
        if i < list.count { return (list[i].start, "") }
        let at = list.last?.end ?? b.preambleEnd
        let before = b.slice(0, at)
        let eol = b.eol
        let prefix = before.isEmpty || before.hasSuffix(eol + eol) ? "" : before.hasSuffix("\n") ? eol : eol + eol
        return (at, prefix)
    }

    /// Lane text normalized to end with a blank line (for re-insertion).
    static func laneBlock(_ b: KanbanBoard, _ lane: KanbanLane) -> String {
        let eol = b.eol
        var raw = b.slice(lane.start, lane.end)
        if !raw.hasSuffix("\n") { raw += eol }
        if !raw.hasSuffix(eol + eol) { raw += eol }
        return raw
    }

    public static func plan(_ b: KanbanBoard, _ op: KanbanOp) -> [TextEdit] {
        let eol = b.eol
        func lane(_ i: Int) -> KanbanLane? { b.lanes.indices.contains(i) ? b.lanes[i] : nil }
        func card(_ l: Int, _ c: Int) -> KanbanCard? {
            guard let ln = lane(l), ln.cards.indices.contains(c) else { return nil }
            return ln.cards[c]
        }

        switch op {
        case let .addCard(l, index, text, checked):
            guard let ln = lane(l) else { return [] }
            let ins = cardInsertion(b, ln, index, skip: nil)
            let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let body = Kanban.cardLines(trimmed, checked: checked, marker: b.marker, indent: b.indent, eol: eol)
            return [TextEdit(from: ins.at, to: ins.at, insert: ins.before + body + ins.after)]

        case let .editCard(l, c, text):
            guard let cd = card(l, c) else { return [] }
            let norm = trailingWS.replace(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), with: "")
            let parts = norm.components(separatedBy: "\n")
            let ind = cd.indent.isEmpty ? b.indent : cd.indent
            let next = ([parts[0]] + parts.dropFirst().map { $0.isEmpty ? ind : ind + $0 }).joined(separator: eol)
            guard let e = RangedEdits.diff(b.slice(cd.textStart, cd.textEnd), next, offset: cd.textStart) else { return [] }
            return [e]

        case let .toggleCard(l, c):
            guard let cd = card(l, c) else { return [] }
            if cd.hasCheckbox {
                return [TextEdit(from: cd.checkOffset, to: cd.checkOffset + 1, insert: cd.checked ? " " : "x")]
            }
            return [TextEdit(from: cd.textStart, to: cd.textStart, insert: "[x] ")]

        case let .deleteCard(l, c):
            guard let cd = card(l, c) else { return [] }
            let r = cardDeleteRange(b, cd)
            return [TextEdit(from: r.from, to: r.to, insert: "")]

        case let .moveCard(l, c, toLane, toIndex):
            guard let cd = card(l, c), let from = lane(l), let to = lane(toLane) else { return [] }
            if toLane == l && toIndex == c { return [] }
            let ins = cardInsertion(b, to, toIndex, skip: cd)
            let del = cardDeleteRange(b, cd)
            // Same place after all (adjacent slot in the same lane).
            if to.start == from.start, ins.at >= del.from, ins.at <= del.to { return [] }
            return [
                TextEdit(from: del.from, to: del.to, insert: ""),
                TextEdit(from: ins.at, to: ins.at, insert: ins.before + cardBody(b, cd) + ins.after),
            ]

        case let .addLane(index, title):
            let t = oneLine(title)
            let ins = laneInsertion(b, index, skip: nil)
            let tail = ins.at < (b.text as NSString).length ? eol + eol + eol : eol + eol
            return [TextEdit(from: ins.at, to: ins.at, insert: ins.prefix + "## \(t)" + tail)]

        case let .renameLane(l, title):
            guard let ln = lane(l) else { return [] }
            let t = oneLine(title)
            if ln.title.isEmpty && ln.titleStart == ln.titleEnd {
                // `##` with no text: add the separating space too.
                return [TextEdit(from: ln.titleStart, to: ln.titleEnd, insert: t.isEmpty ? "" : " " + t)]
            }
            guard let e = RangedEdits.diff(ln.title, t, offset: ln.titleStart) else { return [] }
            return [e]

        case let .deleteLane(l):
            guard let ln = lane(l) else { return [] }
            return [TextEdit(from: ln.start, to: ln.end, insert: "")]

        case let .moveLane(l, toIndex):
            guard let ln = lane(l) else { return [] }
            if toIndex == l { return [] }
            let ins = laneInsertion(b, toIndex, skip: ln)
            if ins.at == ln.start { return [] }
            return [
                TextEdit(from: ln.start, to: ln.end, insert: ""),
                TextEdit(from: ins.at, to: ins.at, insert: ins.prefix + laneBlock(b, ln)),
            ]
        }
    }
}
