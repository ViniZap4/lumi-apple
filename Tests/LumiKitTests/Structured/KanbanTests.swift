import Testing
import Foundation
@testable import LumiKit

/// Port of web-client `lib/kanban/kanban.test.ts` over the same fixtures
/// (Tests/Fixtures/kanban, copied from web-client/src/test/fixtures).
enum KanbanFixtures {
    static let names = ["archive.md", "basic.md", "body-only.md", "crlf.md"]
    static func text(_ name: String) -> String { (try? Fixtures.text("kanban/\(name)")) ?? "" }
}

private func run(_ text: String, _ op: KanbanOp) -> String {
    RangedEdits.apply(KanbanEdits.plan(Kanban.parse(text), op), to: text)
}

private func titles(_ text: String) -> [[String]] {
    Kanban.parse(text).lanes.map { [$0.title] + $0.cards.map(\.text) }
}

@Suite("Kanban parse / serialize")
struct KanbanParseTests {
    @Test("round-trips every fixture byte for byte; segments tile the text", arguments: KanbanFixtures.names)
    func roundTrip(name: String) {
        let text = KanbanFixtures.text(name)
        #expect(!text.isEmpty)
        let b = Kanban.parse(text)
        #expect(Kanban.serialize(b) == text)
        var at = 0
        for s in b.segments {
            #expect(s.start == at)
            at = s.end
        }
        #expect(at == text.utf16.count)
    }

    @Test("parses lanes, cards, flags and settings (basic.md)")
    func basic() {
        let b = Kanban.parse(KanbanFixtures.text("basic.md"))
        #expect(b.format == .board)
        #expect(b.lanes.map(\.title) == ["Backlog", "In progress", "Done"])
        #expect(b.lanes[0].cards.map(\.text) == [
            "Draft the canvas spec",
            "Review #design tokens @{2026-12-01}",
            "Multi-line card\nwith a second line\nand a [[linked note]]",
        ])
        #expect(b.lanes[0].cards[2].indent == "\t")
        #expect(b.lanes[2].complete)
        #expect(b.lanes[2].cards.allSatisfy { $0.checked })
        let json = b.settings?.json?.objectValue
        #expect(json?["kanban-plugin"] == "board")
        #expect(json?["lane-width"] == 300)
        #expect(b.slice(b.footerStart, b.text.utf16.count).hasPrefix("%% kanban:settings"))
    }

    @Test("keeps the archive and intro text out of the lanes (archive.md)")
    func archive() {
        let b = Kanban.parse(KanbanFixtures.text("archive.md"))
        #expect(b.format == .basic)
        #expect(b.lanes.map(\.title) == ["To do", "Doing", "Done"])
        #expect(b.slice(0, b.preambleEnd).contains("Some intro text"))
        #expect(b.slice(b.footerStart, b.text.utf16.count).hasPrefix("***\n\n## Archive"))
        #expect(b.lanes[1].cards.isEmpty)
    }

    @Test("handles CRLF, plain items, other markers and no trailing newline")
    func crlf() {
        let b = Kanban.parse(KanbanFixtures.text("crlf.md"))
        #expect(b.eol == "\r\n")
        #expect(b.lanes[0].cards.map(\.text) == ["crlf card\nnested", "done"])
        #expect(b.lanes[1].cards.map(\.marker) == ["-", "*"])
        #expect(b.lanes[1].cards.map(\.hasCheckbox) == [false, true])
        #expect(b.lanes[1].cards.map(\.text) == ["plain item", "star marker"])
    }

    @Test("body without frontmatter: nested lists and blank-line continuations")
    func bodyOnly() {
        let b = Kanban.parse(KanbanFixtures.text("body-only.md"))
        #expect(b.format == nil)
        #expect(b.lanes.map(\.title) == ["Ideas", "Empty"])
        #expect(b.lanes[0].cards[1].text == "card with\n  - [ ] nested subtask\n  - [x] another\n\n> quote after blank line")
        // UTF-16 offsets: the emoji card's text starts right after `- [ ] `.
        let c0 = b.lanes[0].cards[0]
        #expect(b.slice(c0.textStart, c0.textEnd) == "🎉 emoji card")
    }

    @Test("detects boards")
    func detects() {
        #expect(Kanban.isKanbanText(KanbanFixtures.text("basic.md")))
        #expect(!Kanban.isKanbanText("# plain\n"))
        #expect(Kanban.format(frontmatter: ["kanban-plugin": "basic"]) == .basic)
        #expect(Kanban.format(frontmatter: ["kanban-plugin": "nope"]) == nil)
    }

    @Test("build writes the plugin layout and parses back")
    func build() {
        let text = Kanban.build(lanes: [
            .init("A", cards: [.init("x"), .init("two\nlines", checked: true)]),
            .init("B"),
        ])
        #expect(text == "---\n\nkanban-plugin: board\n\n---\n\n## A\n\n- [ ] x\n- [x] two\n\tlines\n\n\n## B\n\n\n\n\n\n%% kanban:settings\n```\n{\"kanban-plugin\":\"board\"}\n```\n%%")
        #expect(titles(text) == [["A", "x", "two\nlines"], ["B"]])
    }
}

@Suite("Kanban edit planner")
struct KanbanEditsTests {
    let base = KanbanFixtures.text("basic.md")
    var settings: String {
        let r = base.range(of: "%% kanban:settings")!
        return String(base[r.lowerBound...])
    }

    @Test("adds a card at a position, end, and into an empty lane")
    func addCard() {
        var t = run(base, .addCard(lane: 1, index: 0, text: "First"))
        #expect(titles(t)[1] == ["In progress", "First", "Kanban parser"])
        t = run(base, .addCard(lane: 0, index: 99, text: "Last"))
        #expect(titles(t)[0].last == "Last")
        let a = KanbanFixtures.text("archive.md")
        t = run(a, .addCard(lane: 1, index: 0, text: "Now"))
        #expect(titles(t)[1] == ["Doing", "Now"])
        #expect(t.contains("## Doing\n\n- [ ] Now\n\n## Done"))
        // Into the complete lane: after the **Complete** flag.
        t = run(base, .addCard(lane: 2, index: 0, text: "z"))
        #expect(t.contains("**Complete**\n- [ ] z\n- [x] Ship"))
    }

    @Test("every op keeps the settings block and other lanes untouched")
    func untouched() {
        let ops: [KanbanOp] = [
            .addCard(lane: 0, index: 1, text: "n"),
            .editCard(lane: 0, card: 0, text: "Draft the canvas SPEC"),
            .toggleCard(lane: 0, card: 1),
            .deleteCard(lane: 0, card: 2),
            .moveCard(lane: 0, card: 2, toLane: 2, toIndex: 1),
            .addLane(index: 3, title: "Later"),
            .renameLane(lane: 1, title: "Doing"),
            .moveLane(lane: 0, toIndex: 2),
            .deleteLane(lane: 1),
        ]
        for op in ops {
            let t = run(base, op)
            #expect(t.hasSuffix(settings), "\(op.name)")
            #expect(t.hasPrefix("---\n\nkanban-plugin: board\n\n---\n\n"), "\(op.name)")
            #expect(Kanban.serialize(Kanban.parse(t)) == t)
        }
    }

    @Test("edits are minimal")
    func minimal() {
        let b = Kanban.parse(base)
        let e = KanbanEdits.plan(b, .editCard(lane: 0, card: 0, text: "Draft the canvas SPEC"))
        let s = b.lanes[0].cards[0].textStart
        #expect(e == [TextEdit(from: s + 17, to: s + 21, insert: "SPEC")])
        let tg = KanbanEdits.plan(b, .toggleCard(lane: 0, card: 0))
        #expect(RangedEdits.cost(tg) == 2)
        #expect(RangedEdits.apply(tg, to: base).contains("- [x] Draft the canvas spec"))
        let rn = KanbanEdits.plan(b, .renameLane(lane: 1, title: "In review"))
        #expect(rn.count == 1)
        #expect(RangedEdits.cost(rn) <= "progress".count + "review".count)
        // A move is exactly one delete of the card lines plus one insert of them.
        let mv = KanbanEdits.plan(b, .moveCard(lane: 0, card: 2, toLane: 1, toIndex: 1))
        let card = b.lanes[0].cards[2]
        #expect(mv.count == 2)
        #expect(RangedEdits.cost(mv) == 2 * card.raw.utf16.count)
    }

    @Test("edits a multi-line card, keeping its indentation")
    func multiLine() {
        let t = run(base, .editCard(lane: 0, card: 2, text: "Multi-line card\nwith a 2nd line\nand a [[linked note]]\nplus one"))
        #expect(t.contains("- [ ] Multi-line card\n\twith a 2nd line\n\tand a [[linked note]]\n\tplus one\n"))
        #expect(titles(t)[0][3] == "Multi-line card\nwith a 2nd line\nand a [[linked note]]\nplus one")
    }

    @Test("moves cards within and between lanes")
    func moves() {
        var t = run(base, .moveCard(lane: 0, card: 0, toLane: 0, toIndex: 2))
        #expect(Array(titles(t)[0][1...2]) == ["Review #design tokens @{2026-12-01}", "Multi-line card\nwith a second line\nand a [[linked note]]"])
        #expect(titles(t)[0][3] == "Draft the canvas spec")
        t = run(base, .moveCard(lane: 0, card: 2, toLane: 2, toIndex: 2))
        #expect(titles(t)[2] == ["Done", "Ship v0.1.0", "Write release notes", "Multi-line card\nwith a second line\nand a [[linked note]]"])
        t = run(base, .moveCard(lane: 1, card: 0, toLane: 0, toIndex: 0))
        #expect(titles(t)[0][1] == "Kanban parser")
        #expect(titles(t)[1] == ["In progress"])
        #expect(KanbanEdits.plan(Kanban.parse(base), .moveCard(lane: 0, card: 1, toLane: 0, toIndex: 1)).isEmpty)
    }

    @Test("moves the last card of a file without a trailing newline")
    func eofMove() {
        let t0 = KanbanFixtures.text("crlf.md")
        var t = run(t0, .moveCard(lane: 1, card: 1, toLane: 0, toIndex: 0))
        #expect(titles(t) == [["A", "star marker", "crlf card\nnested", "done"], ["B", "plain item"]])
        // CRLF kept: every LF is preceded by CR.
        let u = Array(t.utf16)
        #expect(u.contains(10) && u.indices.allSatisfy { u[$0] != 10 || ($0 > 0 && u[$0 - 1] == 13) })
        t = run(t0, .moveCard(lane: 0, card: 0, toLane: 1, toIndex: 2))
        #expect(titles(t)[1] == ["B", "plain item", "star marker", "crlf card\nnested"])
        t = run(t0, .deleteCard(lane: 1, card: 1))
        #expect(t.hasSuffix("- plain item"))
    }

    @Test("toggles a checkbox-less item by adding one")
    func toggleAdds() {
        #expect(run(KanbanFixtures.text("crlf.md"), .toggleCard(lane: 1, card: 0)).contains("- [x] plain item"))
    }

    @Test("adds, renames, moves and deletes lanes")
    func lanes() {
        var t = run(base, .addLane(index: 3, title: "Later"))
        #expect(titles(t).map { $0[0] } == ["Backlog", "In progress", "Done", "Later"])
        t = run(base, .addLane(index: 0, title: "Inbox"))
        #expect(titles(t).map { $0[0] } == ["Inbox", "Backlog", "In progress", "Done"])
        t = run(base, .moveLane(lane: 2, toIndex: 0))
        #expect(titles(t).map { $0[0] } == ["Done", "Backlog", "In progress"])
        #expect(titles(t)[0] == ["Done", "Ship v0.1.0", "Write release notes"])
        t = run(base, .moveLane(lane: 0, toIndex: 2))
        #expect(titles(t).map { $0[0] } == ["In progress", "Done", "Backlog"])
        #expect(titles(t)[2].count == 4)
        t = run(base, .deleteLane(lane: 1))
        #expect(titles(t).map { $0[0] } == ["Backlog", "Done"])
        t = run(KanbanFixtures.text("body-only.md"), .addLane(index: 9, title: "Z"))
        #expect(titles(t).map { $0[0] } == ["Ideas", "Empty", "Z"])
        t = run("", .addLane(index: 0, title: "First"))
        #expect(t == "## First\n\n")
        t = run(t, .addCard(lane: 0, index: 0, text: "c"))
        #expect(titles(t) == [["First", "c"]])
    }

    @Test("a long sequence of random ops always keeps the board parseable")
    func fuzz() {
        var t = base
        var seed = 7
        func rnd(_ n: Int) -> Int {
            seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff
            return n > 0 ? seed % n : 0
        }
        func cards(_ s: String) -> [String] {
            titles(s).flatMap { $0 }.filter { $0.hasPrefix("c") && $0.dropFirst().first?.isNumber == true }.sorted()
        }
        for i in 0..<300 {
            let b = Kanban.parse(t)
            let L = b.lanes.count
            let lane = rnd(L)
            let n = L > 0 ? b.lanes[lane].cards.count : 0
            let pick = rnd(6)
            let op: KanbanOp
            if L == 0 || pick == 0 { op = .addLane(index: rnd(L + 1), title: "L\(i)") }
            else if pick == 1 || n == 0 { op = .addCard(lane: lane, index: rnd(n + 1), text: "c\(i)") }
            else if pick == 2 { op = .moveCard(lane: lane, card: rnd(n), toLane: rnd(L), toIndex: rnd(n + 1)) }
            else if pick == 3 { op = .deleteCard(lane: lane, card: rnd(n)) }
            else if pick == 4 { op = .moveLane(lane: lane, toIndex: rnd(L)) }
            else { op = .toggleCard(lane: lane, card: rnd(n)) }
            let before = cards(t)
            let next = run(t, op)
            #expect(Kanban.serialize(Kanban.parse(next)) == next)
            #expect(next.hasSuffix(settings))
            switch op {
            case .moveCard, .moveLane, .toggleCard: #expect(cards(next) == before, "\(i) \(op.name)")
            default: break
            }
            t = next
        }
    }
}

@Suite("Kanban keys")
struct KanbanKeysTests {
    let shape = [3, 0, 2]
    func at(_ l: Int, _ c: Int) -> KanbanCursor { KanbanCursor(lane: l, card: c) }
    func k(_ s: String, ctrl: Bool = false, meta: Bool = false) -> StructuredKey { StructuredKey(s, ctrl: ctrl, meta: meta) }

    @Test("moves the cursor and clamps")
    func cursor() {
        var keys = KanbanKeys()
        #expect(keys.feed(k("j"), at(0, 0), shape) == .cursor(at(0, 1)))
        #expect(keys.feed(k("k"), at(0, 0), shape) == .cursor(at(0, 0)))
        #expect(keys.feed(k("l"), at(0, 2), shape) == .cursor(at(1, -1)))
        #expect(keys.feed(k("l"), at(1, -1), shape) == .cursor(at(2, 0)))
        #expect(keys.feed(k("G"), at(0, 0), shape) == .cursor(at(0, 2)))
        #expect(keys.feed(k("g"), at(0, 2), shape) == nil)
        #expect(keys.feed(k("g"), at(0, 2), shape) == .cursor(at(0, 0)))
        #expect(clampKanbanCursor(at(9, 9), shape) == at(2, 1))
    }

    @Test("moves cards with H/L/J/K")
    func moves() {
        var keys = KanbanKeys()
        #expect(keys.feed(k("L"), at(0, 2), shape) == .moveCard(toLane: 1, toIndex: 0))
        #expect(keys.feed(k("H"), at(0, 2), shape) == nil)
        #expect(keys.feed(k("J"), at(0, 0), shape) == .moveCard(toLane: 0, toIndex: 1))
        #expect(keys.feed(k("J"), at(0, 2), shape) == nil)
        #expect(keys.feed(k("K"), at(2, 1), shape) == .moveCard(toLane: 2, toIndex: 0))
    }

    @Test("creates, edits, toggles and deletes (dd)")
    func editing() {
        var keys = KanbanKeys()
        #expect(keys.feed(k("a"), at(0, 0), shape) == .newCard(lane: 0, index: 3))
        #expect(keys.feed(k("o"), at(0, 0), shape) == .newCard(lane: 0, index: 1))
        #expect(keys.feed(k("O"), at(0, 1), shape) == .newCard(lane: 0, index: 1))
        #expect(keys.feed(k("o"), at(1, -1), shape) == .newCard(lane: 1, index: 0))
        #expect(keys.feed(k("A"), at(0, 0), shape) == .newLane)
        #expect(keys.feed(k("Enter"), at(0, 0), shape) == .edit)
        #expect(keys.feed(k("i"), at(1, -1), shape) == nil)
        #expect(keys.feed(k("x"), at(0, 0), shape) == .toggle)
        #expect(keys.feed(k("d"), at(0, 0), shape) == nil)
        #expect(keys.pending == "d")
        #expect(keys.feed(k("d"), at(0, 0), shape) == .delete)
        _ = keys.feed(k("d"), at(0, 0), shape)
        #expect(keys.feed(k("j"), at(0, 0), shape) == nil)
        #expect(keys.feed(k("/"), at(0, 0), shape) == .filter)
        #expect(keys.feed(k(">"), at(0, 0), shape) == .moveLane(toIndex: 1))
        #expect(keys.feed(k("r", ctrl: true), at(0, 0), shape) == .redo)
        #expect(keys.feed(k("j", meta: true), at(0, 0), shape) == nil)
    }

    @Test("StructuredKey from shell strokes")
    func fromStroke() {
        #expect(StructuredKey(stroke: .key(.tab), shift: true) == StructuredKey("Tab", shift: true))
        #expect(StructuredKey(stroke: .char("r", control: true)) == StructuredKey("r", ctrl: true))
        #expect(StructuredKey(stroke: .key(.enter)) == StructuredKey("Enter"))
    }
}

@Suite("Note kind routing (noteViewKind)")
struct NoteKindResolverTests {
    @Test("routes by DTO kind, extension and kanban frontmatter / settings block")
    func routes() {
        #expect(NoteKind.resolve(path: "x.canvas") == .canvas)
        #expect(NoteKind.resolve(path: "x.md", kind: "canvas") == .canvas)
        #expect(NoteKind.resolve(path: "x.canvas", kind: "markdown") == .markdown)
        #expect(NoteKind.resolve(path: "b.md", frontmatterText: "kanban-plugin: board") == .kanban)
        #expect(NoteKind.resolve(path: "b.md", text: "---\nkanban-plugin: basic\n---\n## A\n") == .kanban)
        #expect(NoteKind.resolve(path: "n.md", frontmatterText: "title: x") == .markdown)
        #expect(NoteKind.resolve(path: nil) == .markdown)
        // A server CRDT body (no frontmatter) with the plugin's settings block.
        let body = KanbanFixtures.text("basic.md").components(separatedBy: "---\n\n").last!
        #expect(NoteKind.resolve(path: "b.md", text: body) == .kanban)
        #expect(NoteKind.resolve(path: "b.md", text: "## A\n\n- [ ] x\n") == .markdown)
    }
}
