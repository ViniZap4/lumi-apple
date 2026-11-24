import Testing
import Foundation
import CoreGraphics
@testable import LumiKit

@Suite("KanbanBoardModel")
@MainActor
struct KanbanBoardModelTests {
    let base = KanbanFixtures.text("basic.md")

    @Test("keys drive the cursor; a remote edit elsewhere keeps the focused card")
    func focusSurvivesRemote() {
        let lt = MemoryLiveText(base)
        let m = KanbanBoardModel(doc: lt)
        #expect(m.handleKey(StructuredKey("j")))
        #expect(m.handleKey(StructuredKey("j")))
        #expect(m.focusedCard?.card.text.hasPrefix("Multi-line") == true)
        // A peer adds a card above the focused one.
        let b = Kanban.parse(lt.read())
        lt.remote(KanbanEdits.plan(b, .addCard(lane: 0, index: 0, text: "From a peer")))
        #expect(m.lastChangeRemote)
        #expect(m.cur == KanbanCursor(lane: 0, card: 3))
        #expect(m.focusedCard?.card.text.hasPrefix("Multi-line") == true)
    }

    @Test("L moves the focused card to the next lane in one apply and keeps focus on it")
    func moveKeepsFocus() {
        let lt = MemoryLiveText(base)
        var applies = 0
        let sub = lt.subscribe { if !$0 { applies += 1 } }
        let m = KanbanBoardModel(doc: lt)
        _ = m.handleKey(StructuredKey("L"))
        #expect(applies == 1)
        #expect(m.board.lanes[1].cards.map(\.text) == ["Draft the canvas spec", "Kanban parser"])
        #expect(m.cur == KanbanCursor(lane: 1, card: 0))
        _ = m.handleKey(StructuredKey("u"))
        #expect(lt.read() == base)
        sub.cancel()
    }

    @Test("x toggles, dd asks then deletes, a/Enter edit inline, A adds a lane")
    func editing() {
        let lt = MemoryLiveText(base)
        let m = KanbanBoardModel(doc: lt)
        _ = m.handleKey(StructuredKey("x"))
        #expect(m.board.lanes[0].cards[0].checked)
        _ = m.handleKey(StructuredKey("d"))
        _ = m.handleKey(StructuredKey("d"))
        #expect(m.confirmKey != nil)
        _ = m.handleKey(StructuredKey("n"))
        #expect(m.board.lanes[0].cards.count == 3)
        _ = m.handleKey(StructuredKey("d")); _ = m.handleKey(StructuredKey("d")); _ = m.handleKey(StructuredKey("y"))
        #expect(m.board.lanes[0].cards.count == 2)
        _ = m.handleKey(StructuredKey("a"))
        #expect(m.editing == .new(lane: 0, laneStart: nil, index: 2))
        #expect(!m.handleKey(StructuredKey("j"))) // the field owns keys
        m.draft = "Brand new"
        m.commitEdit()
        #expect(m.board.lanes[0].cards.last?.text == "Brand new")
        #expect(m.focusedCard?.card.text == "Brand new")
        _ = m.handleKey(StructuredKey("Enter"))
        m.draft = "Renamed\nsecond line"
        m.commitEdit()
        #expect(m.board.lanes[0].cards.last?.text == "Renamed\nsecond line")
        _ = m.handleKey(StructuredKey("A"))
        m.draft = "Later"
        m.commitEdit()
        #expect(m.board.lanes.map(\.title).last == "Later")
        #expect(lt.read().hasSuffix("```\n%%\n"))
    }

    @Test("an inline card edit lands on the right card after a remote insert above it (anchor)")
    func editAnchor() {
        let lt = MemoryLiveText(base)
        let m = KanbanBoardModel(doc: lt)
        _ = m.handleKey(StructuredKey("j"))
        _ = m.handleKey(StructuredKey("i"))
        lt.remote([TextEdit(from: 0, to: 0, insert: "")]) // no-op
        let b = Kanban.parse(lt.read())
        lt.remote(KanbanEdits.plan(b, .addCard(lane: 0, index: 0, text: "peer")))
        m.draft = "Review tokens"
        m.commitEdit()
        #expect(m.board.lanes[0].cards.map(\.text) == ["peer", "Draft the canvas spec", "Review tokens", "Multi-line card\nwith a second line\nand a [[linked note]]"])
    }

    @Test("filter narrows cards, blocks reordering; Esc clears it, then falls through")
    func filter() {
        let m = KanbanBoardModel(doc: MemoryLiveText(base))
        _ = m.handleKey(StructuredKey("/"))
        #expect(m.filterOpen)
        m.filter = "ship"
        #expect(m.shape == [0, 0, 1])
        _ = m.handleKey(StructuredKey("L"))
        #expect(m.handleKey(StructuredKey("Escape")))
        #expect(m.filter.isEmpty && !m.filterOpen)
        #expect(!m.handleKey(StructuredKey("Escape")))
    }

    @Test("drag: frames decide the target, the placeholder shows it, drop applies one move")
    func drag() {
        let lt = MemoryLiveText(base)
        let m = KanbanBoardModel(doc: lt)
        for (i, l) in m.lanes.enumerated() {
            m.laneFrames[l.id] = CGRect(x: Double(i) * 300, y: 0, width: 280, height: 600)
            for (j, c) in l.cards.enumerated() { m.cardFrames[c.id] = CGRect(x: Double(i) * 300 + 8, y: 60 + Double(j) * 70, width: 264, height: 60) }
        }
        let card = m.lanes[0].cards[0]
        m.beginDrag(.init(kind: .card, key: card.id, fromLane: 0, fromIndex: 0, size: CGSize(width: 264, height: 60), grab: .zero, location: CGPoint(x: 100, y: 80)))
        m.updateDrag(to: CGPoint(x: 450, y: 140)) // lane 1, below its only card
        #expect(m.drag?.toLane == 1 && m.drag?.toIndex == 1)
        #expect(m.slots(lane: 1).map(\.id).last == "\u{0}placeholder")
        #expect(!m.slots(lane: 0).contains { $0.id == card.id })
        m.endDrag()
        #expect(m.board.lanes[1].cards.map(\.text) == ["Kanban parser", "Draft the canvas spec"])
        #expect(m.focusedCard?.card.text == "Draft the canvas spec")
        #expect(m.drag == nil)
    }

    @Test("read-only LiveText: operations flash instead of writing")
    func readOnly() {
        let lt = MemoryLiveText(base, editable: false)
        let m = KanbanBoardModel(doc: lt)
        _ = m.handleKey(StructuredKey("x"))
        #expect(lt.read() == base)
        #expect(m.notice == "Read-only")
    }
}

@Suite("CanvasBoardModel")
@MainActor
struct CanvasBoardModelTests {
    let obsidian = (try? Fixtures.text("canvas/obsidian.canvas")) ?? ""

    func model(_ text: String? = nil) -> (CanvasBoardModel, MemoryLiveText) {
        let lt = MemoryLiveText(text ?? obsidian)
        let m = CanvasBoardModel(doc: lt)
        var n = 0
        m.newID = { n += 1; return "new\(n)" }
        m.setSize(CGSize(width: 1000, height: 700))
        return (m, lt)
    }

    @Test("fits on first layout; Tab cycles in reading order")
    func fitAndCycle() {
        let (m, _) = model()
        #expect(m.viewport.zoom <= 1 && m.viewport.zoom > 0.5)
        _ = m.handleKey(StructuredKey("Tab"))
        #expect(m.selection == ["b1c2d3e4f5a6b7c8"])
        _ = m.handleKey(StructuredKey("Tab"))
        #expect(m.selection == ["c2d3e4f5a6b7c8d9"])
        _ = m.handleKey(StructuredKey("Tab", shift: true))
        #expect(m.selection == ["b1c2d3e4f5a6b7c8"])
    }

    @Test("dragging a node moves a draft, then commits once on drop")
    func moveCommitsOnDrop() throws {
        let (m, lt) = model()
        m.setViewport(CanvasViewport(x: 500, y: 350, zoom: 1))
        var applies = 0
        let sub = lt.subscribe { if !$0 { applies += 1 } }
        let n = try #require(m.node("e4f5a6b7c8d9e0f1"))
        let p = CGPoint(x: n.x + 500 + 20, y: n.y + 350 + 20)
        m.pointerDown(at: p)
        m.pointerMove(to: CGPoint(x: p.x + 30, y: p.y + 10))
        m.pointerMove(to: CGPoint(x: p.x + 40, y: p.y + 20))
        #expect(applies == 0)
        #expect(m.node("e4f5a6b7c8d9e0f1")?.x == 100)
        m.pointerUp()
        #expect(applies == 1)
        #expect(lt.read().contains(#""x":100,"y":100,"width":250"#))
        sub.cancel()
    }

    @Test("moving a group carries the nodes inside it")
    func groupMove() {
        let (m, lt) = model()
        m.setViewport(CanvasViewport(x: 500, y: 350, zoom: 1))
        // A point inside the group but outside every node.
        let p = CGPoint(x: -400 + 500, y: 240 + 350)
        m.pointerDown(at: p)
        m.pointerMove(to: CGPoint(x: p.x + 10, y: p.y))
        m.pointerUp()
        let parsed = Canvas.parse(lt.read()).parsed!
        #expect(parsed.nodes.first { $0.id == "8a7c1f0e2b3d4c5a" }?.x == -410)
        #expect(parsed.nodes.first { $0.id == "b1c2d3e4f5a6b7c8" }?.x == -370)
    }

    @Test("connect by dragging a side handle onto another node")
    func connect() throws {
        let (m, lt) = model()
        m.setViewport(CanvasViewport(x: 500, y: 350, zoom: 1))
        m.select(["d3e4f5a6b7c8d9e0"])
        let n = try #require(m.node("d3e4f5a6b7c8d9e0"))
        let right = CanvasGeometry.toScreen(m.viewport, CanvasGeometry.sidePoint(n.rect, .right))
        #expect(m.hitTest(right) == .handle(id: n.id, side: .right))
        m.pointerDown(at: right)
        m.pointerMove(to: CGPoint(x: 60 + 500 + 5, y: 110 + 350))
        m.pointerUp()
        let e = try #require(Canvas.parse(lt.read()).parsed?.edges.last)
        #expect(e.id == "new1" && e.fromNode == n.id && e.fromSide == .right && e.toNode == "e4f5a6b7c8d9e0f1" && e.toSide == .left)
        #expect(m.selectedEdge == "new1")
    }

    @Test("a / double-click add a text node in edit mode; an empty new node is removed")
    func addText() {
        let (m, lt) = model()
        _ = m.handleKey(StructuredKey("a"))
        #expect(m.editing == .text(id: "new1", isNew: true))
        m.finishEdit()
        #expect(!lt.read().contains("new1"))
        m.doubleClick(at: CGPoint(x: 5, y: 650))
        m.draft = "**hello**"
        m.finishEdit()
        #expect(Canvas.parse(lt.read()).parsed?.nodes.last?.text == "**hello**")
    }

    @Test("colors, delete, file picker, open file / split, undo")
    func keysOps() {
        let (m, lt) = model()
        var opened: [(String, Bool)] = []
        m.onOpenFile = { opened.append(($0, $1)) }
        m.notes = [CanvasNoteRef(path: "Projects/Roadmap.md"), CanvasNoteRef(path: "Inbox.md", title: "Inbox")]
        m.select(["c2d3e4f5a6b7c8d9"])
        _ = m.handleKey(StructuredKey("g")); _ = m.handleKey(StructuredKey("f"))
        _ = m.handleKey(StructuredKey("w", ctrl: true)); _ = m.handleKey(StructuredKey("f"))
        #expect(opened.map(\.0) == ["Projects/Roadmap.md", "Projects/Roadmap.md"] && opened.map(\.1) == [false, true])
        _ = m.handleKey(StructuredKey("c")); _ = m.handleKey(StructuredKey("2"))
        #expect(m.node("c2d3e4f5a6b7c8d9")?.color == "2")
        _ = m.handleKey(StructuredKey("c")); _ = m.handleKey(StructuredKey("0"))
        #expect(m.node("c2d3e4f5a6b7c8d9")?.color == nil)
        _ = m.handleKey(StructuredKey("d"))
        #expect(m.node("c2d3e4f5a6b7c8d9") == nil)
        #expect(Canvas.parse(lt.read()).parsed?.edges.count == 1)
        _ = m.handleKey(StructuredKey("u"))
        #expect(m.node("c2d3e4f5a6b7c8d9") != nil)
        _ = m.handleKey(StructuredKey("f"))
        m.picker?.query = "inbox"
        #expect(m.pickList.map(\.path) == ["Inbox.md"])
        _ = m.handleKey(StructuredKey("Enter"))
        #expect(Canvas.parse(lt.read()).parsed?.nodes.last?.file == "Inbox.md")
    }

    @Test("invalid JSON keeps the last good parse, read-only")
    func invalidJSON() {
        let (m, lt) = model()
        lt.remote([TextEdit(from: 0, to: 1, insert: "")]) // a peer breaks the JSON
        #expect(m.invalid != nil)
        #expect(m.nodes.count == 5)
        #expect(!m.isEditable)
        _ = m.handleKey(StructuredKey("a"))
        #expect(m.notice == "Invalid JSON: fix it in Source")
        lt.remote([TextEdit(from: 0, to: 0, insert: "{")])
        #expect(m.invalid == nil && m.isEditable)
    }

    @Test("zoom keys and wheel; links open only over http(s)")
    func zoomAndLinks() {
        let (m, _) = model()
        let z = m.viewport.zoom
        _ = m.handleKey(StructuredKey("+"))
        #expect(abs(m.viewport.zoom - z * 1.2) < 1e-9)
        m.wheel(.init(deltaX: 0, deltaY: 30), at: .zero)
        _ = m.handleKey(StructuredKey("0"))
        #expect(abs(m.viewport.zoom - z) < 1e-9)
        #expect(CanvasBoardModel.safeURL("https://jsoncanvas.org") != nil)
        #expect(CanvasBoardModel.safeURL("javascript:alert(1)") == nil)
        #expect(CanvasBoardModel.safeURL("file:///etc/passwd") == nil)
    }
}
