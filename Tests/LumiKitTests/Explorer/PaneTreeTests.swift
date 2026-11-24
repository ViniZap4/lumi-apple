import Foundation
import Testing
@testable import LumiKit

@Suite("Pane tree")
struct PaneTreeTests {
    private let a = PaneContent.note(path: "a.md", view: .live)
    private let b = PaneContent.note(path: "b.md", view: .reading)
    private let c = PaneContent.note(path: "c.md", view: .source)

    @Test("vsplit / split build the tree; new pane goes right / below and takes focus")
    func splits() {
        var t = PaneTree(a)
        let one = t.focused
        let two = t.split(.vertical, content: b)
        #expect(t.leaves == [one, two])
        #expect(t.focused == two && t.previous == one)
        let three = t.split(.horizontal, content: c)
        #expect(t.leaves == [one, two, three])
        let f = t.frames()
        #expect(f[one] == PaneRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(f[two] == PaneRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(f[three] == PaneRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        // Same-axis split adds a sibling instead of nesting.
        t.focus(one)
        let four = t.split(.vertical)
        #expect(t.content(four) == a, "⌃w v duplicates the note")
        if case let .split(axis, kids, weights) = t.root {
            #expect(axis == .vertical && kids.count == 3)
            #expect(abs(weights.reduce(0, +) - 1) < 1e-9)
        } else { Issue.record("root should be a split") }
    }

    @Test("close: siblings take the space, previews go with their note, the last pane stays")
    func close() {
        var t = PaneTree(a)
        let one = t.focused
        let n9 = t.close()
        #expect(!n9, "the last pane cannot close")
        t.setPreview(true)
        let preview = t.preview(of: one)
        #expect(preview != nil && t.count == 2)
        let two = t.split(.horizontal, content: b, target: one)
        #expect(t.count == 3)
        let r1 = t.close(one)
        #expect(r1)
        #expect(t.leaves == [two], "closing the note closes its preview")
        #expect(t.focused == two)
        #expect(t.frames()[two] == PaneRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("only keeps the focused pane; a focused preview keeps its note")
    func only() {
        var t = PaneTree(a)
        let one = t.focused
        t.setPreview(true)
        t.split(.vertical, content: b)
        t.focus(t.preview(of: one)!)
        t.only()
        #expect(t.leaves == [one] && t.focusedContent == a)
    }

    @Test("equalise and ratios")
    func weights() {
        var t = PaneTree(a)
        let one = t.focused
        t.setPreview(true, ratio: 0.7)
        #expect(abs((t.previewRatio() ?? 0) - 0.7) < 1e-9)
        t.setRatio(0.3, for: one)
        #expect(abs((t.previewRatio() ?? 0) - 0.3) < 1e-9)
        t.setRatio(0.01, for: one)
        #expect(abs((t.previewRatio() ?? 0) - PaneTree.minWeight) < 1e-9)
        t.equalize()
        #expect(abs((t.previewRatio() ?? 0) - 0.5) < 1e-9)
        t.setPreview(false)
        #expect(t.count == 1 && t.previewRatio() == nil)
    }

    @Test("directional focus follows geometry; w / W cycle; p goes back")
    func focus() {
        // [ one | two ]
        // [ one | three ]
        var t = PaneTree(a)
        let one = t.focused
        let two = t.split(.vertical, content: b)
        let three = t.split(.horizontal, content: c)
        #expect(t.focused == three)
        let r2 = t.move(.up)
        #expect(r2 && t.focused == two)
        let r3 = t.move(.left)
        #expect(r3 && t.focused == one)
        let n13 = t.move(.left)
        #expect(!n13, "nothing left of the leftmost pane")
        let r4 = t.move(.right)
        #expect(r4)
        #expect(t.focused == two || t.focused == three)
        t.focus(one)
        let r5 = t.cycle(1)
        #expect(r5 && t.focused == two)
        let r6 = t.cycle(1)
        #expect(r6 && t.focused == three)
        let r7 = t.cycle(1)
        #expect(r7 && t.focused == one)
        let r8 = t.cycle(-1)
        #expect(r8 && t.focused == three)
        let r9 = t.focusPrevious()
        #expect(r9 && t.focused == one)
    }

    @Test("round-trips through JSON and the per-book store")
    func persistence() throws {
        var t = PaneTree(a)
        t.setPreview(true, ratio: 0.6)
        t.split(.horizontal, content: b)
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(PaneTree.self, from: data) == t)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("panes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("apple-panes.json")
        PaneLayoutStore(url: url).save(t, forBook: "book-1")
        let reread = PaneLayoutStore(url: url)
        #expect(reread.layout(forBook: "book-1") == t)
        #expect(reread.layout(forBook: "book-2") == nil)
        reread.remove(book: "book-1")
        #expect(PaneLayoutStore(url: url).layout(forBook: "book-1") == nil)
    }

    @Test("note kinds pick their views")
    func kinds() {
        #expect(NoteKind.detect(path: "x/board.canvas") == .canvas)
        #expect(NoteKind.detect(path: "a.md", text: "---\nkanban-plugin: board\n---\n## Todo\n") == .kanban)
        #expect(NoteKind.detect(path: "a.md", text: "---\nkanban-plugin: 'basic'\n---\n") == .kanban)
        #expect(NoteKind.detect(path: "a.md", text: "---\ntitle: x\n---\nkanban-plugin: board\n") == .markdown)
        #expect(NoteKind.detect(path: "a.md", text: "# hi") == .markdown)
        #expect(NoteKind.markdown.views == [.reading, .live, .source])
        // Reading | Edit | Source (SPEC-PARTE2 §5a): Reading first.
        #expect(NoteKind.kanban.defaultView == .reading)
        #expect(NoteKind.kanban.views == [.reading, .board, .source])
        #expect(NoteKind.canvas.views == [.reading, .canvas, .source])
        #expect(NoteViewMode.board.label == "Edit" && NoteViewMode.canvas.label == "Edit")
        #expect(NoteViewMode.live.isEditing && !NoteViewMode.reading.isEditing)
    }
}

@Suite("Note view registry")
struct NoteViewRegistryTests {
    enum Route: Equatable { case reader, editor(live: Bool), board }

    @Test("routes by kind; unsupported views coerce; unregistered kinds fall back")
    func registry() {
        var r = NoteViewRegistry<Route>()
        r.register(.markdown, views: [.reading, .live, .source]) { v in
            v == .reading ? .reader : .editor(live: v == .live)
        }
        #expect(r.resolve(.markdown, .live)?.route == .editor(live: true))
        #expect(r.resolve(.markdown, .board)?.view == .reading)
        let kanban = r.resolve(.kanban, .source)
        #expect(kanban?.isFallback == true && kanban?.route == .editor(live: false))
        #expect(r.views(for: .canvas) == [.reading, .live, .source])
        r.register(.kanban, views: [.board, .source]) { $0 == .board ? .board : .editor(live: false) }
        #expect(r.resolve(.kanban, .live)?.route == .board)
        #expect(r.resolve(.kanban, .live)?.isFallback == false)
        #expect(r.views(for: .kanban) == [.board, .source])
    }
}
