import Foundation
import Testing
@testable import LumiKit

/// A LiveText that counts every write (Reading must never emit one).
private final class CountingText: LiveText {
    let inner: MemoryLiveText
    var applies = 0
    var undos = 0
    init(_ t: String) { inner = MemoryLiveText(t) }
    var text: String { inner.read() }
    func read() -> String { inner.read() }
    func apply(_ edits: [TextEdit]) {
        applies += 1
        inner.apply(edits)
    }
    func subscribe(_ fn: @escaping (Bool) -> Void) -> LiveTextSubscription { inner.subscribe(fn) }
    var isEditable: Bool { true }
    func anchor(_ index: Int) -> LiveTextAnchor { inner.anchor(index) }
    var canUndo: Bool { true }
    func undo() { undos += 1 }
    func redo() { undos += 1 }
}

@Suite("Reading | Edit | Source for boards and canvases (SPEC-PARTE2 §5a)")
@MainActor
struct StructuredModesTests {
    static let everyKey: [StructuredKey] = {
        let names = ["j", "k", "h", "l", "J", "K", "H", "L", "Tab", "Enter", " ", "x", "d", "y", "D", "a", "A", "o", "O",
                     "e", "i", "r", "R", "u", "c", "f", "g", "G", "p", "<", ">", "Backspace", "Delete", "Escape",
                     "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "1", "2", "3", "+", "-", "0", "/", "n", "m", "q"]
        var out: [StructuredKey] = []
        for n in names {
            out.append(StructuredKey(n))
            out.append(StructuredKey(n, shift: true))
            out.append(StructuredKey(n, ctrl: true))
            out.append(StructuredKey(n, meta: true))
        }
        out.append(StructuredKey("z", meta: true))
        out.append(StructuredKey("z", shift: true, meta: true))
        return out
    }()

    @Test("a board in Reading never emits an edit, whatever the keys and calls")
    func kanbanReadingNeverEdits() throws {
        let text = try Fixtures.text("kanban/basic.md")
        let doc = CountingText(text)
        let m = KanbanBoardModel(doc: doc)
        m.readOnly = true
        #expect(!m.isEditable && !m.canDrag())
        for lane in 0..<max(1, m.lanes.count) {
            for card in -1..<3 {
                m.setCursor(KanbanCursor(lane: lane, card: card))
                for k in Self.everyKey {
                    m.handleKey(k)
                    if m.confirmKey != nil { m.handleKey(StructuredKey("y")) }
                }
            }
        }
        if let vm = m.lanes.first?.cards.first {
            m.toggle(vm)
            m.requestDelete(vm)
            m.handleKey(StructuredKey("y"))
            m.startEdit(vm)
            m.moveCard(key: vm.id, toLane: 1, toIndex: 0)
        }
        m.moveLane(from: 0, toIndex: 1)
        m.commitEdit()
        #expect(doc.applies == 0 && doc.undos == 0)
        #expect(doc.text == text)
        #expect(m.editing == nil)
    }

    @Test("the same board in Edit does edit (the guard is the mode)")
    func kanbanEditEdits() throws {
        let doc = CountingText(try Fixtures.text("kanban/basic.md"))
        let m = KanbanBoardModel(doc: doc)
        m.readOnly = false
        if let vm = m.lanes.first?.cards.first { m.toggle(vm) }
        #expect(doc.applies == 1)
    }

    @Test("a canvas in Reading never emits an edit")
    func canvasReadingNeverEdits() throws {
        let text = try Fixtures.text("canvas/obsidian.canvas")
        let doc = CountingText(text)
        let m = CanvasBoardModel(doc: doc)
        m.readOnly = true
        #expect(!m.isEditable)
        let ids = m.nodes.map(\.id)
        for id in ids.prefix(4) {
            m.select([id])
            for k in Self.everyKey { _ = m.handleKey(k) }
        }
        m.addText(at: CGPoint(x: 10, y: 10))
        m.select(ids)
        m.deleteSelection()
        #expect(doc.applies == 0 && doc.undos == 0)
        #expect(doc.text == text)
    }

    @Test("mode keys: i / e in Reading ask for Edit; unhandled Esc / q in Edit go back")
    func modeKeys() {
        #expect(StructuredModeKeys.before(StructuredKey("e"), reading: true) == .edit)
        #expect(StructuredModeKeys.before(StructuredKey("i"), reading: true) == .edit)
        #expect(StructuredModeKeys.before(StructuredKey("e"), reading: false) == nil)
        #expect(StructuredModeKeys.before(StructuredKey("e", meta: true), reading: true) == nil)
        #expect(StructuredModeKeys.after(StructuredKey("Escape"), reading: false, handled: false) == .reading)
        #expect(StructuredModeKeys.after(StructuredKey("q"), reading: false, handled: false) == .reading)
        // Something selected / a filter open: the board consumed Esc.
        #expect(StructuredModeKeys.after(StructuredKey("Escape"), reading: false, handled: true) == nil)
        #expect(StructuredModeKeys.after(StructuredKey("Escape"), reading: true, handled: false) == nil)
    }

    @Test("edit views per kind")
    func editViews() {
        #expect(NoteViewMode.editView(for: .kanban, markdown: .live) == .board)
        #expect(NoteViewMode.editView(for: .canvas, markdown: .live) == .canvas)
        #expect(NoteViewMode.editView(for: .markdown, markdown: .source) == .source)
        #expect(NoteViewMode.board.isStructuredEdit && !NoteViewMode.reading.isStructuredEdit)
    }
}

@Suite("Mini canvas / board, kind glyphs")
struct StructuredMiniTests {
    @Test("canvas mini: nodes, groups first, edges, file titles, bounds")
    func canvasMini() throws {
        let mini = try #require(CanvasMini.make(try Fixtures.text("canvas/obsidian.canvas")))
        #expect(!mini.nodes.isEmpty)
        if let firstNonGroup = mini.nodes.firstIndex(where: { $0.type != .group }),
           let lastGroup = mini.nodes.lastIndex(where: { $0.type == .group }) {
            #expect(lastGroup < firstNonGroup)
        }
        for n in mini.nodes { #expect(mini.bounds.contains(CGPoint(x: n.rect.midX, y: n.rect.midY))) }
        for n in mini.nodes where n.type == .file { #expect(!n.title.contains("/") && !n.title.hasSuffix(".md")) }
        #expect(mini.hiddenNodes == 0)
        #expect(CanvasMini.make("not json") == nil)
    }

    @Test("huge canvases are capped")
    func caps() {
        var nodes: [String] = []
        var edges: [String] = []
        for i in 0..<400 {
            nodes.append(##"{"id":"n\##(i)","type":"text","text":"# Node \##(i)\nbody","x":\##(i * 10),"y":0,"width":100,"height":60}"##)
            if i > 0 { edges.append(#"{"id":"e\#(i)","fromNode":"n\#(i - 1)","toNode":"n\#(i)"}"#) }
        }
        let text = #"{"nodes":[\#(nodes.joined(separator: ","))],"edges":[\#(edges.joined(separator: ","))]}"#
        let mini = CanvasMini.make(text)!
        #expect(mini.nodes.count == CanvasMini.maxNodes)
        #expect(mini.hiddenNodes == 400 - CanvasMini.maxNodes)
        #expect(mini.edges.count <= CanvasMini.maxEdges)
        #expect(mini.nodes.first?.lines.first == "Node 0" || mini.nodes.first?.lines.isEmpty == false)
    }

    @Test("fit: the canvas fits the box, centred, never enlarged")
    func fit() {
        let (s, o) = CanvasMini.fit(CGRect(x: -100, y: -50, width: 1000, height: 500), into: CGSize(width: 300, height: 300), padding: 10)
        #expect(abs(s - 0.28) < 1e-9)
        let minX = -100 * s + o.x, maxX = 900 * s + o.x
        #expect(abs(minX - 10) < 1e-9 && abs(maxX - 290) < 1e-9)
        let small = CanvasMini.fit(CGRect(x: 0, y: 0, width: 10, height: 10), into: CGSize(width: 300, height: 300))
        #expect(small.scale == 1)
    }

    @Test("plain lines strip markdown")
    func plain() {
        #expect(CanvasMini.plainLines("# Title\n\n- [ ] task **bold** [link](x.md)\n```\ncode", max: 4) == ["Title", "☐ task bold link", "code"])
    }

    @Test("kanban mini: lanes and first cards")
    func kanbanMini() throws {
        let text = try Fixtures.text("kanban/basic.md")
        let mini = KanbanMini.make(text, maxLanes: 6, cardsPerLane: 2)
        let board = Kanban.parse(text)
        #expect(mini.lanes.count == min(6, board.lanes.count))
        for (l, lane) in zip(mini.lanes, board.lanes) {
            #expect(l.title == lane.title && l.count == lane.cards.count && l.cards.count == min(2, lane.cards.count))
        }
        #expect(StructuredMini.make(path: "b.md", text: text)?.kind == .kanban)
        #expect(StructuredMini.make(path: "a.md", text: "# plain") == nil)
    }

    @Test("kind glyphs and the same-title suffix")
    func kinds() {
        #expect(NoteKind.canvas.symbol == "rectangle.3.group")
        #expect(NoteKind.kanban.symbol == "rectangle.split.3x1")
        #expect(NoteKind.markdown.symbol == "doc.text")
        let names = NoteKind.disambiguated([("test", .markdown), ("test", .canvas), ("plan", .kanban), ("Test", .kanban)])
        #expect(names == ["test · note", "test · canvas", "plan", "Test · board"])
        #expect(NoteKind.disambiguated([("a", .markdown), ("a", .markdown)]) == ["a", "a"])
    }
}
