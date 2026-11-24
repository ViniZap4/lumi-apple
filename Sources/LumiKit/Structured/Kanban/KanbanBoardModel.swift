import Foundation
import CoreGraphics
import Observation

/// View model of the kanban Board view (SPEC-PARTE2 §5) — the logic of
/// web-client `components/kanban/KanbanBoard.svelte`, UI-free.
///
/// The board is DERIVED from the text on every change (local or remote);
/// nothing is cached in a separate model. Every operation re-parses the
/// CURRENT text, finds its target by card key / sticky anchor, and
/// applies the planner's minimal ranged edits in one transaction. Focus
/// follows the focused card's key, so a remote edit elsewhere never moves
/// the cursor.
@MainActor
@Observable
public final class KanbanBoardModel {
    public struct CardVM: Identifiable, Equatable, Sendable {
        public let id: String
        public let card: KanbanCard
    }

    public struct LaneVM: Identifiable, Equatable, Sendable {
        public let id: String
        public let lane: KanbanLane
        public let cards: [CardVM]
        public let total: Int
    }

    public enum Editing: Equatable {
        case card(key: String, anchor: Int?)
        case new(lane: Int, laneStart: Int?, index: Int)
        case lane(lane: Int, laneStart: Int?)
        case newLane

        public static func == (l: Editing, r: Editing) -> Bool {
            switch (l, r) {
            case let (.card(a, _), .card(b, _)): return a == b
            case let (.new(a, _, i), .new(b, _, j)): return a == b && i == j
            case let (.lane(a, _), .lane(b, _)): return a == b
            case (.newLane, .newLane): return true
            default: return false
            }
        }
    }

    public struct Drag: Equatable, Sendable {
        public enum Kind: Sendable { case card, lane }
        public var kind: Kind
        public var key: String
        public var fromLane: Int
        public var fromIndex: Int
        /// Size of the dragged card / lane (for the ghost and placeholder).
        public var size: CGSize
        /// Pointer offset inside the dragged item.
        public var grab: CGPoint
        /// Pointer location (board coordinate space).
        public var location: CGPoint
        public var toLane: Int
        public var toIndex: Int

        public init(kind: Kind, key: String, fromLane: Int, fromIndex: Int, size: CGSize, grab: CGPoint, location: CGPoint) {
            self.kind = kind; self.key = key; self.fromLane = fromLane; self.fromIndex = fromIndex
            self.size = size; self.grab = grab; self.location = location
            self.toLane = kind == .lane ? fromLane : fromLane
            self.toIndex = fromIndex
        }
    }

    /// One slot of a lane as rendered (cards, plus the drop placeholder
    /// while dragging).
    public enum Slot: Identifiable, Equatable {
        case card(CardVM)
        case placeholder(height: Double)
        public var id: String {
            switch self {
            case let .card(c): return c.id
            case .placeholder: return "\u{0}placeholder"
            }
        }
    }

    public private(set) var doc: any LiveText
    public private(set) var text: String
    public private(set) var board: KanbanBoard
    public private(set) var lanes: [LaneVM] = []
    public var filter: String = "" { didSet { if filter != oldValue { rebuild() } } }
    public var filterOpen = false
    public private(set) var cursor = KanbanCursor(lane: 0, card: 0)
    public private(set) var focusKey: String?
    public private(set) var editing: Editing?
    /// The inline editor's text.
    public var draft: String = ""
    public private(set) var confirmKey: String?
    public private(set) var notice: String?
    public private(set) var pending: String?
    public var drag: Drag?
    /// The last text change came from a peer.
    public private(set) var lastChangeRemote = false
    /// Bumped when the view should move keyboard focus back to the board.
    public private(set) var focusRequest = 0

    @ObservationIgnored private var keys = KanbanKeys()
    @ObservationIgnored private var subscription: LiveTextSubscription?
    @ObservationIgnored private var editAnchor: LiveTextAnchor?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Measured frames (board coordinate space), set by the view.
    @ObservationIgnored public var cardFrames: [String: CGRect] = [:]
    @ObservationIgnored public var laneFrames: [String: CGRect] = [:]

    public init(doc: any LiveText) {
        self.doc = doc
        let t = doc.read()
        text = t
        board = Kanban.parse(t)
        rebuild()
        subscribe()
    }

    /// Rebind to another LiveText (REST preview → live replica).
    public func rebind(_ newDoc: any LiveText) {
        guard newDoc !== doc else { return }
        subscription?.cancel()
        doc = newDoc
        reload(remote: true)
        subscribe()
    }

    private func subscribe() {
        subscription = doc.subscribe { [weak self] remote in self?.reload(remote: remote) }
    }

    private func reload(remote: Bool) {
        let t = doc.read()
        lastChangeRemote = remote
        guard t != text else { return }
        text = t
        board = Kanban.parse(t)
        rebuild()
    }

    // MARK: - Derived

    /// Stable keys: source text + occurrence (moves keep their key).
    public static func keys(of b: KanbanBoard) -> (lanes: [String], cards: [[String]]) {
        var seen: [String: Int] = [:]
        func k(_ s: String) -> String {
            let n = (seen[s] ?? 0) + 1
            seen[s] = n
            return "\(n)\u{1}\(s)"
        }
        let lanes = b.lanes.map { k("L\u{2}" + b.slice($0.start, $0.headingEnd)) }
        let cards = b.lanes.map { l in
            l.cards.map { c -> String in
                var raw = c.raw
                if raw.hasSuffix("\r\n") { raw.removeLast(1) } else if raw.hasSuffix("\n") { raw.removeLast() }
                return k("C\u{2}" + raw)
            }
        }
        return (lanes, cards)
    }

    private func rebuild() {
        let ks = Self.keys(of: board)
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lanes = board.lanes.enumerated().map { li, lane in
            LaneVM(
                id: ks.lanes[li], lane: lane,
                cards: lane.cards.enumerated()
                    .map { ci, c in CardVM(id: ks.cards[li][ci], card: c) }
                    .filter { needle.isEmpty || $0.card.text.lowercased().contains(needle) },
                total: lane.cards.count
            )
        }
    }

    public var shape: [Int] { lanes.map(\.cards.count) }

    public var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The focused (lane, card): follows `focusKey` through any change.
    public var cur: KanbanCursor {
        if let focusKey {
            for (li, l) in lanes.enumerated() {
                if let ci = l.cards.firstIndex(where: { $0.id == focusKey }) { return KanbanCursor(lane: li, card: ci) }
            }
        }
        return clampKanbanCursor(cursor, shape)
    }

    public var focusedCard: CardVM? {
        let c = cur
        guard lanes.indices.contains(c.lane), lanes[c.lane].cards.indices.contains(c.card) else { return nil }
        return lanes[c.lane].cards[c.card]
    }

    /// Reading mode (SPEC-PARTE2 §5a): navigate, focus, follow links —
    /// never an edit, a move, a delete or a checkbox toggle.
    public var readOnly = false
    public var isEditable: Bool { doc.isEditable && !readOnly }
    var readOnlyNotice: String { readOnly ? "Reading — e to edit" : "Read-only" }

    public func setCursor(_ c: KanbanCursor) {
        let cl = clampKanbanCursor(c, shape)
        cursor = cl
        focusKey = cl.card >= 0 ? lanes[cl.lane].cards[cl.card].id : nil
    }

    // MARK: - Operations

    public func flash(_ msg: String) {
        notice = msg
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Plan against the CURRENT text and apply in one transaction.
    @discardableResult
    func exec(_ build: (KanbanBoard) -> KanbanOp?) -> Bool {
        guard isEditable else {
            flash(readOnlyNotice)
            return false
        }
        let b = Kanban.parse(doc.read())
        guard let op = build(b) else { return false }
        let edits = KanbanEdits.plan(b, op)
        if !edits.isEmpty { doc.apply(edits) }
        return !edits.isEmpty
    }

    func findByKey(_ b: KanbanBoard, _ key: String) -> KanbanCard? {
        let ks = Self.keys(of: b)
        for (li, row) in ks.cards.enumerated() {
            if let ci = row.firstIndex(of: key) { return b.lanes[li].cards[ci] }
        }
        return nil
    }

    private func keyAt(_ lane: Int, _ index: Int) -> String? {
        let ks = Self.keys(of: Kanban.parse(doc.read()))
        guard ks.cards.indices.contains(lane), ks.cards[lane].indices.contains(index) else { return nil }
        return ks.cards[lane][index]
    }

    private func focusAfter(_ lane: Int, _ index: Int) {
        cursor = KanbanCursor(lane: lane, card: index)
        focusKey = keyAt(lane, index)
    }

    private func needsNoFilter() -> Bool {
        if isFiltering { flash("Clear the filter (Esc) to reorder or add") }
        return !isFiltering
    }

    /// Move a card (by key) to (toLane, toIndex) — keys, drag and drop.
    public func moveCard(key: String, toLane: Int, toIndex: Int) {
        guard needsNoFilter() else { return }
        exec { b in
            guard let c = findByKey(b, key) else { return nil }
            return .moveCard(lane: c.lane, card: c.index, toLane: toLane, toIndex: toIndex)
        }
        focusKey = key
        cursor = KanbanCursor(lane: toLane, card: toIndex)
    }

    public func moveLane(from: Int, toIndex: Int) {
        guard needsNoFilter() else { return }
        exec { _ in .moveLane(lane: from, toIndex: toIndex) }
        cursor = KanbanCursor(lane: toIndex, card: cur.card)
    }

    public func toggle(_ vm: CardVM) {
        guard exec({ b in
            guard let c = findByKey(b, vm.id) else { return nil }
            return .toggleCard(lane: c.lane, card: c.index)
        }) else { return }
        // The raw (and so the key) changed: refocus by position.
        focusAfter(vm.card.lane, vm.card.index)
    }

    public func requestDelete(_ vm: CardVM) {
        guard isEditable else { return flash(readOnlyNotice) }
        confirmKey = vm.id
    }

    public func confirmDelete(_ yes: Bool) {
        guard let key = confirmKey else { return }
        confirmKey = nil
        guard yes else { return }
        let pos = cur
        exec { b in
            guard let c = findByKey(b, key) else { return nil }
            return .deleteCard(lane: c.lane, card: c.index)
        }
        focusKey = nil
        cursor = pos
    }

    // MARK: - Inline editing

    public func startEdit(_ vm: CardVM) {
        guard isEditable else { return flash(readOnlyNotice) }
        editAnchor = doc.anchor(vm.card.start)
        editing = .card(key: vm.id, anchor: vm.card.start)
        draft = vm.card.text
        focusKey = vm.id
    }

    public func startNew(lane: Int, index: Int) {
        guard isEditable else { return flash(readOnlyNotice) }
        guard needsNoFilter(), board.lanes.indices.contains(lane) else { return }
        editAnchor = doc.anchor(board.lanes[lane].start)
        editing = .new(lane: lane, laneStart: board.lanes[lane].start, index: index)
        draft = ""
    }

    public func startRename(lane: Int) {
        guard isEditable else { return flash(readOnlyNotice) }
        guard board.lanes.indices.contains(lane) else { return }
        editAnchor = doc.anchor(board.lanes[lane].start)
        editing = .lane(lane: lane, laneStart: board.lanes[lane].start)
        draft = board.lanes[lane].title
    }

    public func startNewLane() {
        guard isEditable else { return flash(readOnlyNotice) }
        editAnchor = nil
        editing = .newLane
        draft = ""
    }

    private func laneByAnchor(_ b: KanbanBoard, _ fallback: Int) -> KanbanLane? {
        let at = editAnchor?.position
        return b.lanes.first { $0.start == at } ?? (b.lanes.indices.contains(fallback) ? b.lanes[fallback] : nil)
    }

    public func commitEdit() {
        guard let e = editing else { return }
        editing = nil
        defer { editAnchor = nil; focusRequest += 1 }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch e {
        case let .card(key, _):
            let at = editAnchor?.position
            var lane = -1, index = -1
            exec { b in
                guard let c = b.lanes.flatMap(\.cards).first(where: { $0.start == at }) ?? findByKey(b, key) else { return nil }
                lane = c.lane
                index = c.index
                return .editCard(lane: c.lane, card: c.index, text: text)
            }
            if lane >= 0 { focusAfter(lane, index) }
        case let .new(laneIdx, _, index):
            var li = -1
            exec { b in
                guard let l = laneByAnchor(b, laneIdx) else { return nil }
                li = l.index
                return .addCard(lane: l.index, index: index, text: text)
            }
            if li >= 0 {
                let n = Kanban.parse(doc.read()).lanes[li].cards.count
                focusAfter(li, min(index, max(0, n - 1)))
            }
        case let .lane(laneIdx, _):
            exec { b in
                guard let l = laneByAnchor(b, laneIdx) else { return nil }
                return .renameLane(lane: l.index, title: text)
            }
        case .newLane:
            var at = 0
            exec { b in
                at = b.lanes.count
                return .addLane(index: b.lanes.count, title: text)
            }
            cursor = KanbanCursor(lane: at, card: -1)
            focusKey = nil
        }
    }

    public func cancelEdit() {
        editing = nil
        editAnchor = nil
        focusRequest += 1
    }

    // MARK: - Keyboard

    /// Feed a key; true when the board consumed it (so the shell must not).
    @discardableResult
    public func handleKey(_ e: StructuredKey) -> Bool {
        if editing != nil { return false }
        if confirmKey != nil {
            confirmDelete(e.key == "y" || e.key == "Y" || e.key == "Enter")
            return true
        }
        let had = keys.pending
        let action = keys.feed(e, cur, shape)
        pending = keys.pending
        guard let action else { return keys.pending != nil || had != nil }
        let vm = focusedCard
        switch action {
        case let .cursor(c): setCursor(c)
        case let .moveCard(toLane, toIndex):
            if let vm { moveCard(key: vm.id, toLane: toLane, toIndex: toIndex) }
        case let .newCard(lane, index): startNew(lane: lane, index: index)
        case .newLane: startNewLane()
        case .edit: if let vm { startEdit(vm) }
        case .toggle:
            if !isEditable { flash(readOnlyNotice) } else if let vm { toggle(vm) }
        case .delete:
            if let vm { requestDelete(vm) }
        case .filter: filterOpen = true
        case .rename: startRename(lane: cur.lane)
        case let .moveLane(toIndex): moveLane(from: cur.lane, toIndex: toIndex)
        case .undo: if isEditable { doc.undo() } else { flash(readOnlyNotice) }
        case .redo: if isEditable { doc.redo() } else { flash(readOnlyNotice) }
        case .escape:
            if !filter.isEmpty || filterOpen {
                filter = ""
                filterOpen = false
            } else {
                return false // the shell gets Esc
            }
        }
        return true
    }

    /// Enter in the filter field: keep the filter, go to the first match.
    public func submitFilter() {
        if filter.isEmpty { filterOpen = false }
        setCursor(KanbanCursor(lane: cur.lane, card: 0))
        focusRequest += 1
    }

    public func clearFilter() {
        filter = ""
        filterOpen = false
        focusRequest += 1
    }

    // MARK: - Drag and drop

    /// Press on a card / lane header: focus it; a drag starts on movement.
    public func canDrag() -> Bool { isEditable && !isFiltering && editing == nil }

    public func beginDrag(_ d: Drag) {
        guard canDrag() else { return }
        drag = d
    }

    /// Pointer moved: recompute the drop target from the measured frames
    /// (the web's `dropTarget`).
    public func updateDrag(to p: CGPoint) {
        guard var d = drag else { return }
        d.location = p
        let laneList = lanes.enumerated().filter { $0.element.id != d.key }
        if d.kind == .lane {
            var index = 0
            for (_, l) in laneList {
                guard let r = laneFrames[l.id] else { continue }
                if r.midX < p.x { index += 1 }
            }
            d.toLane = index
            d.toIndex = index
        } else {
            var best = -1
            var bestDist = Double.infinity
            for (li, l) in laneList {
                guard let r = laneFrames[l.id] else { continue }
                let dist = p.x < r.minX ? r.minX - p.x : p.x > r.maxX ? p.x - r.maxX : 0
                if dist < bestDist { best = li; bestDist = dist }
            }
            if best >= 0 {
                var index = 0
                for c in lanes[best].cards where c.id != d.key {
                    guard let r = cardFrames[c.id] else { continue }
                    if r.midY < p.y { index += 1 }
                }
                d.toLane = best
                d.toIndex = index
            }
        }
        drag = d
    }

    /// Drop: one move (delete + insert in one transaction) when the slot changed.
    public func endDrag(cancelled: Bool = false) {
        guard let d = drag else { return }
        drag = nil
        guard !cancelled else { return }
        switch d.kind {
        case .card:
            if !(d.toLane == d.fromLane && d.toIndex == d.fromIndex) {
                moveCard(key: d.key, toLane: d.toLane, toIndex: d.toIndex)
            }
        case .lane:
            if d.toIndex != d.fromLane { moveLane(from: d.fromLane, toIndex: d.toIndex) }
        }
    }

    /// Cards of lane `li` as rendered: the dragged card leaves its slot
    /// and a placeholder marks the drop target.
    public func slots(lane li: Int) -> [Slot] {
        guard lanes.indices.contains(li) else { return [] }
        let cards = lanes[li].cards
        guard let d = drag, d.kind == .card else { return cards.map(Slot.card) }
        var out = cards.filter { $0.id != d.key }.map(Slot.card)
        if d.toLane == li { out.insert(.placeholder(height: d.size.height), at: min(d.toIndex, out.count)) }
        return out
    }

    /// Lanes as rendered while a lane is dragged (`nil` = placeholder).
    public var laneOrder: [LaneVM?] {
        guard let d = drag, d.kind == .lane else { return lanes }
        var out: [LaneVM?] = lanes.filter { $0.id != d.key }
        out.insert(nil, at: min(d.toIndex, out.count))
        return out
    }
}
