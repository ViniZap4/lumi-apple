import Testing
import Foundation
@testable import LumiKit

@Suite("Vim cursor shape (mode → shape)")
struct VimCursorStyleTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let keys: String
        let shape: VimCursorShape
        let blinks: Bool
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        .init(name: "normal → steady block", keys: "", shape: .block, blinks: false),
        .init(name: "insert → blinking bar", keys: "i", shape: .bar, blinks: true),
        .init(name: "replace → blinking underline", keys: "R", shape: .underline, blinks: true),
        .init(name: "visual → block at head", keys: "v", shape: .block, blinks: false),
        .init(name: "visual line → block", keys: "V", shape: .block, blinks: false),
        .init(name: "visual block → block", keys: "<C-v>", shape: .block, blinks: false),
        .init(name: "operator-pending → half block", keys: "d", shape: .halfBlock, blinks: false),
        .init(name: "g~ pending → half block", keys: "g~", shape: .halfBlock, blinks: false),
        .init(name: "after r → underline", keys: "r", shape: .underline, blinks: false),
        .init(name: "count only → block", keys: "3", shape: .block, blinks: false),
        .init(name: "command line → hidden", keys: ":", shape: .hidden, blinks: false),
        .init(name: "search → hidden", keys: "/", shape: .hidden, blinks: false),
        .init(name: "Ctrl-O in insert → block", keys: "i<C-o>", shape: .block, blinks: false),
    ]

    @Test(arguments: rows)
    func shape(_ row: Row) {
        let st = vimRun(row.keys, "|abc").0
        let s = VimCursorStyle.resolve(mode: st.mode, pending: st.pending)
        #expect(s.shape == row.shape)
        #expect(s.blinks == row.blinks)
        #expect(!s.usesSystemCaret)
    }

    @Test("reduce motion stops blinking")
    func reduceMotion() {
        #expect(VimCursorStyle.resolve(mode: .insert, reduceMotion: true) == VimCursorStyle(shape: .bar, blinks: false))
        #expect(VimCursorStyle.resolve(mode: .replace, reduceMotion: true).blinks == false)
    }

    @Test("IME marked text and plain editing use the system bar caret")
    func systemCaret() {
        let ime = VimCursorStyle.resolve(mode: .normal, hasMarkedText: true)
        #expect(ime.shape == .bar)
        #expect(ime.usesSystemCaret)
        #expect(VimCursorStyle.resolve(mode: .insert, vimEnabled: false).usesSystemCaret)
    }

    @Test("unfocused editor: hollow block; insert keeps a steady bar")
    func unfocused() {
        #expect(VimCursorStyle.resolve(mode: .normal, isFocused: false).shape == .hollowBlock)
        #expect(VimCursorStyle.resolve(mode: .visual(.characterwise, anchor: 0), isFocused: false).shape == .hollowBlock)
        #expect(VimCursorStyle.resolve(mode: .insert, isFocused: false) == VimCursorStyle(shape: .bar, blinks: false))
    }

    @Test("block-cursor preference off keeps a bar in normal mode")
    func preference() {
        #expect(VimCursorStyle.resolve(mode: .normal, blockCursor: false).shape == .bar)
        #expect(VimCursorStyle.resolve(mode: .normal, blockCursor: false).blinks == false)
    }
}

@Suite("Command legend")
struct CommandLegendTests {
    func keys(_ items: [LegendItem]) -> [String] { items.map(\.keys) }

    @Test("every context has a non-empty legend")
    func allContexts() {
        for ctx in LegendContext.allCases {
            #expect(!CommandLegend.items(ctx).isEmpty, "\(ctx)")
        }
    }

    @Test("explorer and reader mirror the web legend; chords and counts complete")
    func shell() {
        #expect(keys(CommandLegend.shellItems(.explorer)).prefix(3) == ["j k", "h l", "⏎"])
        #expect(keys(CommandLegend.shellItems(.reader)).first == "j k")
        #expect(keys(CommandLegend.shellItems(.explorer, pending: "g")) == ["gg", "ge", "gf", "gb", "gh", "g1–9"])
        #expect(keys(CommandLegend.shellItems(.explorer, pending: "z")) == ["zp", "zh"])
        #expect(keys(CommandLegend.shellItems(.explorer, pending: "5")) == ["5j", "5k", "Esc"])
        #expect(keys(CommandLegend.shellItems(.reader, pending: "12")) == ["12j", "12k"])
    }

    @Test("which-key completions for pending editor keys")
    func whichKey() {
        func legend(_ k: String) -> [LegendItem] {
            let st = vimRun(k, "|abc").0
            let ctx: LegendContext = VimEngine.isOperatorPending(st) ? .operatorPending : .normal
            return CommandLegend.items(ctx, pending: st.pending)
        }
        #expect(keys(legend("g")).contains("gg"))
        #expect(keys(legend("g")).contains("gu gU g~"))
        #expect(keys(legend("z")).first == "zz")
        #expect(keys(legend("Z")) == ["ZZ", "ZQ"])
        #expect(keys(legend("\"")).contains("+ *"))
        #expect(keys(legend("d")).first == "dd")
        #expect(keys(legend("g~")).first == "g~~")
        #expect(keys(legend("di")).contains("w W"))
        #expect(keys(legend("f")).first == "{char}")
        #expect(keys(legend("q")).first == "a–z")
        #expect(keys(legend("@")).contains("@"))
        #expect(keys(legend("m")).first == "a–z")
        #expect(keys(legend("'")).contains("' `"))
        #expect(keys(legend("4")).first == "4j 4k")
    }

    @Test("leader shows the leader mappings")
    func leader() {
        var st = VimState()
        st.apply(vimrc: Vimrc.parse("let mapleader=\",\"\nnnoremap <leader>w :w<CR>\nnnoremap <leader>n :noh<CR>"))
        let r = VimEngine.handle(.character(","), state: st, buffer: TextBuffer(text: "a"))
        let extras = CommandLegend.Extras(leader: ",", leaderMaps: [.init("w", ":w<CR>"), .init("n", ":noh<CR>")])
        let items = CommandLegend.items(.normal, pending: r.state.pending, extras: extras)
        #expect(items == [.init(",w", "save"), .init(",n", "clear search")])
        #expect(CommandLegend.displayLeader("<Space>") == "␣")
    }

    @Test("insert legend lists escape sequences; normal shows recording")
    func extras() {
        let ins = CommandLegend.items(.insert, extras: .init(escapeSequences: ["jj", "jk"]))
        #expect(ins.first?.keys == "Esc jj jk" && ins.first?.label == "normal")
        let normal = CommandLegend.items(.normal, extras: .init(recording: "a"))
        #expect(normal.first?.keys == "q" && normal.first?.label == "stop recording @a")
    }

    @Test("describeRhs names common ex commands")
    func describe() {
        #expect(CommandLegend.describeRhs(":w<CR>") == "save")
        #expect(CommandLegend.describeRhs(":noh<CR>") == "clear search")
        #expect(CommandLegend.describeRhs(":set wrap<CR>") == ":set wrap")
        #expect(CommandLegend.describeRhs("dddddddddddddddddd") == "ddddddddddddd…")
    }
}
