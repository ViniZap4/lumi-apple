import Testing
import Foundation
@testable import LumiKit

/// Table-driven engine tests: initial text with `|` at the cursor, keys in
/// vim notation (`<Esc>`, `<CR>`, `<C-v>`), expected text with `|` at
/// the cursor, expected mode.
struct VimCase: CustomTestStringConvertible, Sendable {
    let keys: String
    let before: String
    let after: String
    let mode: VimMode

    init(_ keys: String, _ before: String, _ after: String, _ mode: VimMode = .normal) {
        self.keys = keys
        self.before = before
        self.after = after
        self.mode = mode
    }

    var testDescription: String { "\(keys) on \(before.debugDescription)" }
}

func splitCursor(_ s: String) -> (String, Int) {
    guard let i = s.firstIndex(of: "|") else { return (s, 0) }
    var t = s
    let off = s.distance(from: s.startIndex, to: i)
    t.remove(at: i)
    return (t, off)
}

func vimRun(_ keys: String, _ before: String, state: VimState = .initial) -> (VimState, TextBuffer) {
    let (text, cursor) = splitCursor(before)
    var st = state
    var b = TextBuffer(text: text, cursor: cursor)
    let inputs = VimInput.parse(notation: keys) ?? keys.map { VimInput.character($0) }
    for k in inputs {
        let r = VimEngine.handle(k, state: st, buffer: b)
        st = r.state
        b = r.buffer
    }
    return (st, b)
}

func show(_ b: TextBuffer) -> String {
    var t = b.text
    let i = t.index(t.startIndex, offsetBy: min(b.cursor, t.count))
    t.insert("|", at: i)
    return t
}

func check(_ c: VimCase, sourceLocation: SourceLocation = #_sourceLocation) {
    let (st, b) = vimRun(c.keys, c.before)
    #expect(show(b) == c.after, "\(c.keys) → got \(show(b).debugDescription)", sourceLocation: sourceLocation)
    #expect(st.mode == c.mode, "\(c.keys) → mode \(st.mode)", sourceLocation: sourceLocation)
    // The ranged edit log must reproduce the final text exactly.
    let (start, _) = splitCursor(c.before)
    #expect(TextEdit.apply(b.edits, to: start) == b.text, "\(c.keys) edit log", sourceLocation: sourceLocation)
}

@Suite("Vim table — motions")
struct VimMotionTableTests {
    static let cases: [VimCase] = [
        .init("w", "|foo bar", "foo |bar"),
        .init("w", "|foo.bar", "foo|.bar"),
        .init("W", "|foo.bar baz", "foo.bar |baz"),
        .init("3w", "|a b c d", "a b c |d"),
        .init("w", "fo|o\n\nbar", "foo\n|\nbar"),
        .init("w", "foo\n|\nbar", "foo\n\n|bar"),
        .init("w", "a |b", "a |b"),
        .init("b", "foo |bar", "|foo bar"),
        .init("b", "foo.|bar", "foo|.bar"),
        .init("B", "x foo.|bar", "x |foo.bar"),
        .init("b", "foo\n\n|bar", "foo\n|\nbar"),
        .init("e", "|foo bar", "fo|o bar"),
        .init("e", "fo|o bar", "foo ba|r"),
        .init("E", "|foo.bar baz", "foo.ba|r baz"),
        .init("ge", "foo |bar", "fo|o bar"),
        .init("gE", "a.b |c", "a.|b c"),
        .init("0", "  ab|c", "|  abc"),
        .init("^", "  ab|c", "  |abc"),
        .init("$", "|abc\ndef", "ab|c\ndef"),
        .init("2$", "|abc\ndef", "abc\nde|f"),
        .init("g_", "|abc  ", "ab|c  "),
        .init("3|", "|abcdef", "ab|cdef"),
        .init("j", "ab|cdef\nxy\nabcdef", "abcdef\nx|y\nabcdef"),
        .init("jj", "ab|cdef\nxy\nabcdef", "abcdef\nxy\nab|cdef"),
        .init("$jj", "abc|def\nxy\nabcdefgh", "abcdef\nxy\nabcdefg|h"),
        .init("G", "|a\nb\nc", "a\nb\n|c"),
        .init("2G", "|a\n  b\nc", "a\n  |b\nc"),
        .init("gg", "a\nb\n|c", "|a\nb\nc"),
        .init("+", "|a\n  b", "a\n  |b"),
        .init("-", "  a\n|b", "  |a\nb"),
        .init("<CR>", "|a\n  b", "a\n  |b"),
        .init("fc", "|abcabc", "ab|cabc"),
        .init("2fc", "|abcabc", "abcab|c"),
        .init("tc", "|abcabc", "a|bcabc"),
        .init("Fa", "abcab|c", "abc|abc"),
        .init("Ta", "abcab|c", "abca|bc"),
        .init("fb;", "|abcabc", "abca|bc"),
        .init("fb;,", "|abcabc", "a|bcabc"),
        .init("tb;", "|abcabc", "abc|abc"),
        .init("%", "|(a [b] c)", "(a [b] c|)"),
        .init("%", "(a [b] c|)", "|(a [b] c)"),
        .init("%", "x |a (b)", "x a (b|)"),
        .init("50%", "|1\n2\n3\n4", "1\n|2\n3\n4"),
        .init("}", "|a\nb\n\nc", "a\nb\n|\nc"),
        .init("}}", "|a\n\nb\n\nc", "a\n\nb\n|\nc"),
        .init("{", "a\n\nb\n|c", "a\n|\nb\nc"),
        .init(")", "|One two. Three four.", "One two. |Three four."),
        .init("(", "One two. Three |four.", "One two. |Three four."),
        .init("<Space>", "a|b\ncd", "ab\n|cd"),
        .init("<BS>", "ab\n|cd", "a|b\ncd"),
        .init("l", "ab|c", "ab|c"),
        .init("h", "|abc", "|abc"),
        .init("[(", "f(a, |b)", "f|(a, b)"),
        .init("])", "f(a, |b)", "f(a, b|)"),
    ]

    @Test(arguments: cases)
    func motion(_ c: VimCase) { check(c) }

    @Test("H M L use the host viewport")
    func screenLines() {
        var st = VimState()
        st.viewport = VimViewport(firstLine: 1, lastLine: 5)
        let text = "0\n1\n2\n3\n4\n5\n6"
        #expect(show(vimRun("H", "|" + text, state: st).1) == "0\n|1\n2\n3\n4\n5\n6")
        #expect(show(vimRun("L", "|" + text, state: st).1) == "0\n1\n2\n3\n4\n|5\n6")
        #expect(show(vimRun("M", "|" + text, state: st).1) == "0\n1\n2\n|3\n4\n5\n6")
        #expect(show(vimRun("2H", "|" + text, state: st).1) == "0\n1\n|2\n3\n4\n5\n6")
    }

    @Test("gj / gk ask the host to refine by display lines")
    func displayLines() {
        let r = VimEngine.handle(.character("g"), state: .initial, buffer: TextBuffer(text: "abc\ndef", cursor: 1))
        let r2 = VimEngine.handle(.character("j"), state: r.state, buffer: r.buffer)
        #expect(r2.effect == .displayLines(from: 1, count: 1))
        #expect(r2.buffer.cursor == 5)
    }

    @Test("jumps set the previous-context mark: `` returns")
    func previousContext() {
        check(.init("G``", "a\n|b\nc", "a\n|b\nc"))
        check(.init("G''", "a\nb|b\nc", "a\n|bb\nc"))
    }
}

@Suite("Vim table — operators")
struct VimOperatorTableTests {
    static let cases: [VimCase] = [
        .init("dw", "|foo bar", "|bar"),
        .init("dw", "foo |bar\nbaz", "foo| \nbaz"),
        .init("d2w", "|a b c", "|c"),
        .init("2dw", "|a b c", "|c"),
        .init("de", "|foo bar", "| bar"),
        .init("db", "foo |bar", "|bar"),
        .init("dge", "foo b|ar", "fo|r"),
        .init("cwX<Esc>", "|foo bar", "|X bar"),
        .init("cwX<Esc>", "|f bar", "|X bar"),
        .init("c2wX<Esc>", "|a b c", "|X c"),
        .init("cWX<Esc>", "|a.b c", "|X c"),
        .init("d$", "a|bc\nd", "|a\nd"),
        .init("D", "a|bc\nd", "|a\nd"),
        .init("2D", "a|bc\ndef\ng", "|a\ng"),
        .init("C!<Esc>", "a|bc", "a|!"),
        .init("d0", "ab|c", "|c"),
        .init("d^", "  ab|c", "  |c"),
        .init("dd", "a\n|b\nc", "a\n|c"),
        .init("dd", "a\nb\n|c", "a\n|b"),
        .init("2dd", "|a\nb\nc", "|c"),
        .init("d2d", "|a\nb\nc", "|c"),
        .init("dj", "|a\nb\nc", "|c"),
        .init("dk", "a\n|b\nc", "|c"),
        .init("dG", "a\n|b\nc", "|a"),
        .init("dgg", "a\n|b\nc", "|c"),
        .init("ccX<Esc>", "a\n  |b\nc", "a\n  |X\nc"),
        .init("SX<Esc>", "|abc", "|X"),
        .init("sX<Esc>", "|abc", "|Xbc"),
        .init("3sX<Esc>", "|abcd", "|Xd"),
        .init("x", "a|bc", "a|c"),
        .init("3x", "|abcd", "|d"),
        .init("x", "ab|c", "a|b"),
        .init("X", "ab|c", "a|c"),
        .init("2X", "abc|d", "a|d"),
        .init("dfc", "|abcd", "|d"),
        .init("dtc", "|abcd", "|cd"),
        .init("dFa", "abc|d", "|d"),
        .init("dTa", "abc|d", "a|d"),
        .init("d}", "|a\nb\n\nc", "|\nc"),
        .init("d}", "a|b\nc\n\nd", "|a\n\nd"),
        .init("d%", "x|(a)y", "x|y"),
        .init("yyp", "|a\nb", "a\n|a\nb"),
        .init("yyP", "a\n|b", "a\n|b\nb"),
        .init("ywP", "|foo bar", "foo| foo bar"),
        .init("yiwp", "|foo bar", "ffo|ooo bar"),
        .init("xp", "|ab", "b|a"),
        .init("ddp", "|a\nb", "b\n|a"),
        .init("x3p", "|ab", "baa|a"),
        .init("yl3p", "|ab", "aaa|ab"),
        .init("yyj2p", "|a\nb", "a\nb\n|a\na"),
        .init("ylgp", "|ab", "aa|b"),
        .init("yygP", "|a\nb", "a\n|a\nb"),
        .init("J", "|a\n  b", "a| b"),
        .init("3J", "|a\nb\nc\nd", "a b| c\nd"),
        .init("gJ", "|a\n  b", "a|  b"),
        .init("J", "|a \nb", "a |b"),
        .init("J", "|a\n\nb", "|a\nb"),
        .init("~", "|abc", "A|bc"),
        .init("3~", "|abcd", "ABC|d"),
        .init("g~w", "|abc def", "|ABC def"),
        .init("gUiw", "a|bc def", "|ABC def"),
        .init("guu", "A|BC\nDEF", "|abc\nDEF"),
        .init("gUU", "a|bc", "|ABC"),
        .init("g??", "|abc", "|nop"),
        .init("rX", "a|bc", "a|Xc"),
        .init("3rX", "|abcd", "XX|Xd"),
        .init("5rX", "|abc", "|abc"),
        .init("r<CR>", "a|bc", "a\n|c"),
        .init(">>", "|a", "    |a"),
        .init("2>>", "|a\nb", "    |a\n    b"),
        .init(">j", "|a\nb\nc", "    |a\n    b\nc"),
        .init("<<", "      |a", "  |a"),
        .init("<<", "\t|a", "|a"),
        .init(">ip", "|a\nb\n\nc", "    |a\n    b\n\nc"),
        .init("==", "  |a", "  |a"),
        .init("<C-a>", "x |9 y", "x 1|0 y"),
        .init("5<C-a>", "|x 1", "x |6"),
        .init("<C-x>", "|x 0", "x -|1"),
        .init("<C-a>", "a-|5", "a-|4"),
        .init("Rxy<Esc>", "|abc", "x|yc"),
        .init("Rxyz<Esc>", "|a\nb", "xy|z\nb"),
        .init("Rxy<BS><BS><Esc>", "|abc", "|abc"),
        .init("ixx<Esc>", "a|b", "ax|xb"),
        .init("3ia<Esc>", "|b", "aa|ab"),
        .init("ax<Esc>", "|ab", "a|xb"),
        .init("Ax<Esc>", "|ab", "ab|x"),
        .init("Ix<Esc>", "  a|b", "  |xab"),
        .init("gIx<Esc>", "  a|b", "|x  ab"),
        .init("ox<Esc>", "|a\nb", "a\n|x\nb"),
        .init("Ox<Esc>", "a\n|b", "a\n|x\nb"),
        .init("ox<Esc>", "  |a", "  a\n  |x"),
        .init("2ox<Esc>", "|a", "a\nx\n|x"),
    ]

    @Test(arguments: cases)
    func op(_ c: VimCase) { check(c) }
}

@Suite("Vim table — text objects")
struct VimObjectTableTests {
    static let cases: [VimCase] = [
        .init("diw", "foo b|ar baz", "foo | baz"),
        .init("daw", "foo b|ar baz", "foo |baz"),
        .init("daw", "foo b|ar", "fo|o"),
        .init("daw", "foo| bar", "fo|o"),
        .init("d3iw", "|a b c d", "| c d"),
        .init("ciwX<Esc>", "foo b|ar", "foo |X"),
        .init("diW", "x a.|b y", "x | y"),
        .init("daW", "x a.|b y", "x |y"),
        .init("di\"", "say \"he|llo\" now", "say \"|\" now"),
        .init("da\"", "say \"he|llo\" now", "say |now"),
        .init("di\"", "|x \"a\" y", "x \"|\" y"),
        .init("ci'X<Esc>", "a 'b|c' d", "a '|X' d"),
        .init("di`", "use `co|de` here", "use `|` here"),
        .init("di(", "f(a, |b)", "f(|)"),
        .init("da(", "f(a, |b) x", "f| x"),
        .init("dib", "f(a|b)", "f(|)"),
        .init("di)", "f(a|b)", "f(|)"),
        .init("di(", "f|(ab)", "f(|)"),
        .init("di(", "f(ab|)", "f(|)"),
        .init("d2i(", "((a|b) c)", "(|)"),
        .init("di(", "|x", "|x"),
        .init("di[", "[1, |2]", "[|]"),
        .init("da[", "x[1|]y", "x|y"),
        .init("di{", "{\n  a|\n  b\n}", "{\n|}"),
        .init("diB", "{a|b}", "{|}"),
        .init("di<", "<a|b>", "<|>"),
        .init("dit", "<p>he|llo</p>", "<p>|</p>"),
        .init("dat", "x<p>he|llo</p>y", "x|y"),
        .init("dit", "<a><b>x|y</b></a>", "<a><b>|</b></a>"),
        .init("d2it", "<a><b>x|y</b></a>", "<a>|</a>"),
        .init("dip", "a\n|b\n\nc", "|\nc"),
        .init("dap", "a\n|b\n\nc", "|c"),
        .init("dap", "a\n\nb\n|c", "|a"),
        .init("yipP", "|a\nb\n\nc", "|a\nb\na\nb\n\nc"),
        .init("dis", "One. Tw|o three. Four.", "One. | Four."),
        .init("das", "One. Tw|o three. Four.", "One. |Four."),
    ]

    @Test(arguments: cases)
    func object(_ c: VimCase) { check(c) }
}

@Suite("Vim table — visual")
struct VimVisualTableTests {
    static let cases: [VimCase] = [
        .init("vld", "|abc", "|c"),
        .init("vjd", "a|b\ncd", "|a"),
        .init("Vd", "a\n|b\nc", "a\n|c"),
        .init("Vjd", "|a\nb\nc", "|c"),
        .init("vey", "|foo bar", "|foo bar"),
        .init("vecX<Esc>", "|foo bar", "|X bar"),
        .init("viwd", "a f|oo b", "a | b"),
        .init("vawd", "a f|oo b", "a |b"),
        .init("vi(d", "(a|b)", "(|)"),
        .init("vi(i(d", "((a|b))", "(|)"),
        .init("vipd", "a\n|b\n\nc", "|\nc"),
        .init("vlU", "|abc", "|ABc"),
        .init("Vu", "A|BC", "|abc"),
        .init("v~", "|aB", "|AB"),
        .init("vlrx", "|abc", "|xxc"),
        .init("V>", "|a", "    |a"),
        .init("Vj>", "|a\nb", "    |a\n    b"),
        .init("V2>", "|a", "        |a"),
        .init("VjJ", "|a\nb", "a| b"),
        .init("vlohd", "a|bcd", "|d"),
        .init("vllx", "|abcd", "|d"),
        .init("vlX", "a|b\nc", "|c"),
        .init("vlD", "a|bc\nd", "|d"),
        .init("vlY", "|ab\nc", "|ab\nc"),
        .init("ylvlp", "|abc", "|ac"),
        .init("yyjVp", "|a\nb", "a\n|a"),
        .init("v$d", "a|b\ncd", "a|cd"),
        .init("vjv", "a|b\ncd", "ab\nc|d"),
        .init("vV<Esc>", "a|b", "a|b"),
        .init("vl<Esc>gvd", "|abc", "|c"),
        .init("v3<C-a>", "|x 1", "|x 4"),
        .init("vIx<Esc>", "a|bc", "a|xbc"),
        .init("vlAx<Esc>", "|abc", "ab|xc"),
    ]

    @Test(arguments: cases)
    func visual(_ c: VimCase) { check(c) }

    @Test("visual mode keys and marks")
    func marks() {
        let (st, _) = vimRun("vl<Esc>", "a|bcd")
        #expect(st.marks["<"] == 1)
        #expect(st.marks[">"] == 2)
        #expect(st.lastVisual?.kind == .characterwise)
    }
}

@Suite("Vim table — visual block")
struct VimBlockTableTests {
    static let cases: [VimCase] = [
        .init("<C-v>jld", "|abc\ndef", "|c\nf"),
        .init("<C-v>jly", "|abc\ndef", "|abc\ndef"),
        .init("<C-v>jIX<Esc>", "|abc\ndef", "|Xabc\nXdef"),
        .init("l<C-v>jIX<Esc>", "|abc\ndef", "a|Xbc\ndXef"),
        .init("<C-v>jAX<Esc>", "|abc\ndef", "a|Xbc\ndXef"),
        .init("<C-v>j$AX<Esc>", "|ab\ncdef", "ab|X\ncdefX"),
        .init("<C-v>jlcX<Esc>", "|abc\ndef", "|Xc\nXf"),
        .init("<C-v>jrx", "|ab\ncd", "|xb\nxd"),
        .init("<C-v>jU", "|ab\ncd", "|Ab\nCd"),
        .init("<C-v>jldP", "|abc\ndef", "|abc\ndef"),
        .init("<C-v>j$d", "a|bc\ndef", "|a\nd"),
        .init("<C-v>jlyP", "|abc\ndef", "|ababc\ndedef"),
        .init("ll<C-v>2jIX<Esc>", "|abc\nd\nefg", "ab|Xc\nd\nefXg"),
        .init("ll<C-v>jIX<Esc>", "|abc\nd", "|Xabc\nXd"),
        .init("<C-v>jlo<Esc>", "|abc\ndef", "|abc\ndef"),
    ]

    @Test(arguments: cases)
    func block(_ c: VimCase) { check(c) }

    @Test("block yank stores a blockwise register")
    func blockRegister() {
        let (st, _) = vimRun("<C-v>jly", "|abc\ndef")
        #expect(st.defaultRegister == Register(text: "ab\nde", kind: .blockwise))
    }
}

@Suite("Vim table — registers")
struct VimRegisterTableTests {
    @Test("delete shifts the numbered registers; small deletes go to \"-")
    func numbered() {
        let (st, _) = vimRun("dddd", "|a\nb\nc")
        #expect(st.registers["1"]?.text == "b\n")
        #expect(st.registers["2"]?.text == "a\n")
        let (s2, _) = vimRun("x", "|ab")
        #expect(s2.registers["-"]?.text == "a")
        #expect(s2.registers["1"] == nil)
    }

    @Test("yank fills \"0; a delete doesn't touch it")
    func zero() {
        let (st, b) = vimRun("yyjdd\"0p", "|a\nb\nc")
        #expect(st.registers["0"]?.text == "a\n")
        #expect(show(b) == "a\nc\n|a")
    }

    @Test("black hole register keeps the unnamed register")
    func blackHole() {
        let (st, _) = vimRun("yw\"_dw", "|foo bar")
        #expect(st.defaultRegister.text == "foo ")
    }

    @Test("\"1p then . pastes \"2 (numbered increment)")
    func numberedDot() {
        let (_, b) = vimRun("dddd\"1p.", "|a\nb\nc")
        #expect(b.text == "c\nb\na")
    }

    @Test("\"+ reads the host-provided clipboard")
    func clipboard() {
        var st = VimState()
        st.clipboard = "CLIP"
        let (_, b) = vimRun("\"+p", "|x", state: st)
        #expect(show(b) == "xCLI|P")
        #expect(VimEngine.wantsClipboard(vimRun("\"+", "|x").0))
    }

    @Test("\". \": \"/ are readable")
    func readOnly() {
        let (_, b) = vimRun("ihi<Esc>\".p", "|")
        #expect(b.text == "hihi")
        let (_, b2) = vimRun("/b<CR>\"/P", "|ab")
        #expect(b2.text == "abb")
    }

    @Test("Ctrl-R in insert inserts a register")
    func insertRegister() {
        let (_, b) = vimRun("yiwA <C-r>\"<Esc>", "|foo")
        #expect(show(b) == "foo fo|o")
    }
}

@Suite("Vim table — dot repeat and counts")
struct VimDotTableTests {
    static let cases: [VimCase] = [
        .init("dw.", "|a b c", "|c"),
        .init("dw2.", "|a b c d", "|d"),
        .init("2dw.", "|a b c d e", "|e"),
        .init("ciwX<Esc>w.", "|foo bar", "X |X"),
        .init("Ax<Esc>j.", "|a\nb", "ax\nb|x"),
        .init("3ix<Esc>j.", "|a\nb", "xxxa\nxx|xb"),
        .init("ix<Esc>3.", "|a", "xx|xxa"),
        .init("x..", "|abcd", "|d"),
        .init("ddj.", "|a\nb\nc\nd", "b\n|d"),
        .init(">>j.", "|a\nb", "    a\n    |b"),
        .init("~.", "|ab", "A|B"),
        .init("rxl.", "|ab", "x|x"),
        .init("vld.", "|abcde", "|e"),
        .init("Jj.", "|a\nb\nc\nd", "a b\nc| d"),
        .init("<C-a>.", "|1", "|3"),
        .init("cwx<C-w>y<Esc>.", "|ab cd", "|y cd"),
        .init("ox<Esc>u.", "|a", "a\n|x"),
    ]

    @Test(arguments: cases)
    func dot(_ c: VimCase) { check(c) }

    @Test("undo and redo with counts")
    func undoCount() {
        check(.init("xxx2u", "|abcd", "|bcd"))
        check(.init("xxuu<C-r>", "|abc", "|bc"))
    }

    @Test(". after an ex command repeats the last normal change, not the ex line")
    func exNotRepeated() {
        check(.init("x:s/b/X/<CR>.", "|abc", "|c"))
    }
}

@Suite("Vim table — macros")
struct VimMacroTableTests {
    static let cases: [VimCase] = [
        .init("qaxq@a", "|abc", "|c"),
        .init("qaxq2@a", "|abcd", "|d"),
        .init("qaxq@a@@", "|abcd", "|d"),
        .init("qaA!<Esc>jq@a", "|a\nb\nc", "a!\nb!\n|c"),
        .init("qaA!<Esc>jq2@a", "|a\nb\nc", "a!\nb!\nc|!"),
        .init("qa0<C-a>jq2@a", "|1\n1\n1", "2\n2\n|2"),
        .init("qaxqqAxq@a", "|abcd", "|"),
    ]

    @Test(arguments: cases)
    func macro(_ c: VimCase) { check(c) }

    @Test("@: repeats the last ex command")
    func atColon() {
        check(.init(":s/a/b/<CR>j@:", "|a\na", "b\n|b"))
    }

    @Test("recording stores the keys in the register too")
    func recordedRegister() {
        let (st, _) = vimRun("qadwq", "|a b")
        #expect(st.registers["a"]?.text == "dw")
    }
}

@Suite("Vim table — search")
struct VimSearchTableTests {
    static let cases: [VimCase] = [
        .init("/b<CR>", "|abab", "a|bab"),
        .init("/b<CR>n", "|abab", "aba|b"),
        .init("/b<CR>nN", "|abab", "a|bab"),
        .init("?a<CR>", "ab|ab", "|abab"),
        .init("2/b<CR>", "|abab", "aba|b"),
        .init("*", "|foo x foo", "foo x |foo"),
        .init("#", "foo x |foo", "|foo x foo"),
        .init("*", "|foo foobar foo", "foo foobar |foo"),
        .init("g*", "|foo foobar", "foo |foobar"),
        .init("d/c<CR>", "|abcd", "|cd"),
        .init("/\\<is\\><CR>", "|this is", "this |is"),
        .init("/a\\+b<CR>", "|x aab", "x |aab"),
        .init("/\\(ab\\)\\{2}<CR>", "|ab abab", "ab |abab"),
        .init("/\\vab+<CR>", "|a abb", "a |abb"),
        .init("/^b<CR>", "|a\nb", "a\n|b"),
        .init("/x<CR>", "|abc", "|abc"),
        .init("vl/c<CR>d", "|abcd", "|d"),
    ]

    @Test(arguments: cases)
    func search(_ c: VimCase) { check(c) }

    @Test("ignorecase / smartcase options")
    func caseOptions() {
        var st = VimState()
        st.options.ignorecase = false
        #expect(show(vimRun("/foo<CR>", "|x Foo foo", state: st).1) == "x Foo |foo")
        #expect(show(vimRun("/foo<CR>", "|x Foo foo").1) == "x |Foo foo")
        #expect(show(vimRun(":set noic<CR>/foo<CR>", "|x Foo foo").1) == "x Foo |foo")
    }

    @Test("not found sets an error message; :noh suspends highlight")
    func messages() {
        let (st, _) = vimRun("/zz<CR>", "|abc")
        #expect(st.message?.isError == true)
        #expect(st.message?.text.contains("E486") == true)
        let (s2, _) = vimRun("/b<CR>:noh<CR>", "|abc")
        #expect(s2.hlsearchSuspended)
    }
}

@Suite("Vim table — insert keys")
struct VimInsertKeyTableTests {
    static let cases: [VimCase] = [
        .init("A<C-w><Esc>", "|foo bar", "foo| "),
        .init("A<C-w><C-w><Esc>", "|foo bar", "|"),
        .init("A<C-u><Esc>", "  |foo", " | "),
        .init("A<C-h><Esc>", "|ab", "|a"),
        .init("i<C-t><Esc>", "|a", "   | a"),
        .init("A<C-d><Esc>", "    |a", "|a"),
        .init("ix<C-o>$y<Esc>", "|ab", "xab|y"),
        .init("i<C-r>a<Esc>", "|x", "|x"),
        .init("ihi<Esc>A<C-a><Esc>", "|", "hih|i"),
        .init("A<CR>x<Esc>", "  |a", "  a\n  |x"),
        .init("i<Tab><Esc>", "|a", "   | a"),
        .init("A<C-e><Esc>", "|a\nab", "a|b\nab"),
        .init("ia<Left>b<Esc>", "|", "|ba"),
        .init("A<Del><Esc>", "|a\nb", "|ab"),
    ]

    @Test(arguments: cases)
    func insertKey(_ c: VimCase) { check(c) }
}

@Suite("Vim table — ex commands")
struct VimExTableTests {
    static let cases: [VimCase] = [
        .init(":s/a/X/<CR>", "|aaa\naaa", "|Xaa\naaa"),
        .init(":s/a/X/g<CR>", "|aaa\naaa", "|XXX\naaa"),
        .init(":%s/a/X/<CR>", "|ab\nab", "Xb\n|Xb"),
        .init(":%s/a/X/g<CR>", "|aa\naa", "XX\n|XX"),
        .init(":2,3s/a/X/<CR>", "|a\na\na\na", "a\nX\n|X\na"),
        .init(":.,$s/a/X/<CR>", "a\n|a\na", "a\nX\n|X"),
        .init(":.,.+1s/a/X/<CR>", "|a\na\na", "X\n|X\na"),
        .init("ma:'a,$s/a/X/<CR>", "a\n|a\na", "a\nX\n|X"),
        .init("Vj:s/a/X/<CR>", "|a\na\na", "X\n|X\na"),
        .init(":%s/\\(a\\)\\(b\\)/\\2\\1/<CR>", "|ab ab", "|ba ab"),
        .init(":s/b/[&]/g<CR>", "|abab", "|a[b]a[b]"),
        .init(":s/a/\\U&x/<CR>", "|ab", "|AXb"),
        .init(":s/a/\\u&x/<CR>", "|ab", "|Axb"),
        .init(":s/, /\\r/g<CR>", "|a, b, c", "a\nb\n|c"),
        .init(":s/x/y/<CR>", "|abc", "|abc"),
        .init(":s/a/b/<CR>j&", "|a\na", "b\n|b"),
        .init(":%s/a/b/<CR>u", "|a\na", "|a\na"),
        .init(":2<CR>", "|a\n  b\nc", "a\n  |b\nc"),
        .init(":$<CR>", "|a\nb", "a\n|b"),
        .init(":2d<CR>", "|a\nb\nc", "a\n|c"),
        .init(":1,2d<CR>", "|a\nb\nc", "|c"),
        .init(":d 2<CR>", "|a\nb\nc", "|c"),
        .init(":2y<CR>P", "|a\nb", "|b\na\nb"),
        .init(":%norm Ax<CR>", "|a\nb", "ax\nb|x"),
        .init(":2,3norm! I-<CR>", "|a\nb\nc", "a\n-b\n|-c"),
        .init(":g/x/d<CR>", "|a\nx1\nb\nx2", "a\n|b"),
        .init(":g/x/s/x/y/<CR>", "|x\na\nx", "y\na\n|y"),
        .init(":v/x/d<CR>", "|a\nx\nb", "|x"),
        .init(":g!/x/d<CR>", "|a\nx\nb", "|x"),
        .init(":g/^/m0<CR>", "|a\nb\nc", "|c\nb\na"),
        .init(":g/a/norm Ax<CR>", "|a\nb\na", "ax\nb\na|x"),
        .init(":2m0<CR>", "|a\nb", "|b\na"),
        .init(":1t$<CR>", "|a\nb", "a\nb\n|a"),
        .init(":1,2j<CR>", "|a\nb\nc", "a| b\nc"),
        .init(":>><CR>", "|a", "        |a"),
        .init(":sort<CR>", "|c\na\nb", "|a\nb\nc"),
        .init(":sort!<CR>", "|a\nc\nb", "|c\nb\na"),
        .init(":sort n<CR>", "|10\n9\n100", "|9\n10\n100"),
        .init(":sort u<CR>", "|b\na\nb", "|a\nb"),
        .init("yy:put<CR>", "|a", "a\n|a"),
        .init(":s/a/b/c<CR>yn", "|a a\na", "b |a\na"),
        .init(":%s/a/b/gc<CR>nya", "|a a\na a", "a b\n|b b"),
        .init(":%s/a/b/gc<CR>q", "|a a", "|a a"),
        .init(":%s/a/b/gc<CR>l", "|a a", "|b a"),
    ]

    @Test(arguments: cases)
    func ex(_ c: VimCase) { check(c) }

    @Test(":w :q :wq :x emit host effects")
    func effects() {
        func eff(_ cmd: String) -> VimEffect? {
            var st = VimState(), b = TextBuffer(text: "a")
            var last: VimEffect?
            for k in VimInput.parse(notation: cmd)! {
                let r = VimEngine.handle(k, state: st, buffer: b)
                st = r.state; b = r.buffer
                if let e = r.effect { last = e }
            }
            return last
        }
        #expect(eff(":w<CR>") == .save(force: false))
        #expect(eff(":w!<CR>") == .save(force: true))
        #expect(eff(":wq<CR>") == .saveAndClose(force: false))
        #expect(eff(":x<CR>") == .saveAndClose(force: false))
        #expect(eff(":q!<CR>") == .close(force: true))
        #expect(eff("ZZ") == .saveAndClose(force: false))
        #expect(eff("ZQ") == .close(force: true))
        #expect(eff("zz") == .scrollCursor(.center))
    }

    @Test(":s over many lines is one ranged edit per match (CRDT stays minimal)")
    func substituteEdits() {
        let text = (0..<50).map { "line \($0) a" }.joined(separator: "\n")
        var st = VimState(), b = TextBuffer(text: text)
        for k in VimInput.parse(notation: ":%s/a/XY/<CR>")! {
            let r = VimEngine.handle(k, state: st, buffer: b)
            st = r.state; b = r.buffer
        }
        #expect(b.edits.count == 50)
        #expect(b.edits.allSatisfy { $0.length == 1 && $0.replacement == "XY" })
        #expect(TextEdit.apply(b.edits, to: text) == b.text)
        #expect(st.history.undo.count == 1)
        #expect(st.message?.text == "50 substitutions on 50 lines")
    }

    @Test(":set options and queries")
    func setOptions() {
        let (st, _) = vimRun(":set ts=2 sw=2 noet nu<CR>", "|a")
        #expect(st.options.tabstop == 2)
        #expect(st.options.shiftwidth == 2)
        #expect(st.options.expandtab == false)
        #expect(st.options.number == true)
        let (s2, _) = vimRun(":set sw?<CR>", "|a")
        #expect(s2.message?.text == "  shiftwidth=4")
        let (s3, _) = vimRun(":set bogus<CR>", "|a")
        #expect(s3.message?.isError == true)
        check(.init(":set noet ts=4 sw=4<CR>>>", "|a", "\t|a"))
    }

    @Test(":map family and :unmap")
    func mapping() {
        check(.init(":nnoremap Q dd<CR>Q", "|a\nb", "|b"))
        check(.init(":inoremap jk <lt>Esc><CR>ixjk", "|a", "|xa"))
        check(.init(":nmap Q dd<CR>:nunmap Q<CR>Q", "|a\nb", "|a\nb"))
        check(.init(":let mapleader=\",\"<CR>:nnoremap <lt>leader>d dd<CR>,d", "|a\nb", "|b"))
        let (st, _) = vimRun(":nnoremap Q dd<CR>:map<CR>", "|a")
        #expect(st.message?.text.contains("Q") == true)
    }

    @Test(":registers and :marks list")
    func listings() {
        let (st, _) = vimRun("yw:reg<CR>", "|foo bar")
        #expect(st.message?.text.contains("\"0   foo ") == true)
        let (s2, _) = vimRun("ma:marks<CR>", "a|bc")
        #expect(s2.message?.text.contains(" a      1    1 abc") == true)
        let (s3, _) = vimRun("ma:delm a<CR>", "|a")
        #expect(s3.marks["a"] == nil)
    }

    @Test("unknown command reports E492")
    func unknown() {
        let (st, _) = vimRun(":frob<CR>", "|a")
        #expect(st.message?.text.hasPrefix("E492") == true)
    }

    @Test("count before : prefills a range")
    func countRange() {
        check(.init("2:s/a/b/<CR>", "|a\na\na", "b\n|b\na"))
    }
}

@Suite("Vim — mappings and leader")
struct VimMappingTests {
    @Test("vimrc mappings drive the engine")
    func vimrcMaps() {
        var st = VimState()
        st.apply(vimrc: Vimrc.parse("let mapleader=\" \"\nnnoremap <leader>x dd\ninoremap jj <Esc>\nnmap Y y$\nvnoremap < <gv"))
        #expect(show(vimRun(" x", "|a\nb", state: st).1) == "|b")
        #expect(show(vimRun("ijjx", "|ab", state: st).1) == "|b")
        #expect(show(vimRun("ia<Esc>", "|b", state: st).1) == "|ab")
        let (s2, _) = vimRun("lY", "|abc", state: st)
        #expect(s2.defaultRegister.text == "bc")
    }

    @Test("pending mapping shows in the pending info; timeout flushes")
    func pendingAndTimeout() {
        var st = VimState()
        st.apply(vimrc: Vimrc.parse("nnoremap gx dd"))
        let r = VimEngine.handle(.character("g"), state: st, buffer: TextBuffer(text: "abc"))
        #expect(VimEngine.pendingInfo(r.state).awaiting == .mapping)
        #expect(r.state.pending.display == "g")
        // `gg` is not mapped: the pending `g` replays and `gg` runs.
        let r2 = VimEngine.handle(.character("g"), state: r.state, buffer: TextBuffer(text: "a\nb", cursor: 2))
        #expect(r2.buffer.cursor == 0)
    }

    @Test("insert mapping types its first key until the mapping completes")
    func tentative() {
        var st = VimState()
        st.apply(vimrc: Vimrc.parse("inoremap jk <Esc>"))
        let (s1, b1) = vimRun("ij", "|a", state: st)
        #expect(b1.text == "ja")
        #expect(s1.mode == .insert)
        let (s2, b2) = vimRun("ijk", "|a", state: st)
        #expect(b2.text == "a")
        #expect(s2.mode == .normal)
        let (_, b3) = vimRun("ijx<Esc>", "|a", state: st)
        #expect(b3.text == "jxa")
    }

    @Test("ex alias from vimrc")
    func exAlias() {
        var st = VimState()
        st.apply(vimrc: Vimrc.parse("map :W :write"))
        var b = TextBuffer(text: "a")
        var last: VimEffect?
        for k in VimInput.parse(notation: ":W<CR>")! {
            let r = VimEngine.handle(k, state: st, buffer: b)
            st = r.state; b = r.buffer
            if let e = r.effect { last = e }
        }
        #expect(last == .save(force: false))
    }
}

@Suite("Vim — pending info (legend / which-key)")
struct VimPendingInfoTests {
    func info(_ keys: String) -> VimPendingInfo { vimRun(keys, "|abc").0.pending }

    @Test("awaiting kinds")
    func awaiting() {
        #expect(info("g").awaiting == .gPrefix)
        #expect(info("z").awaiting == .zPrefix)
        #expect(info("Z").awaiting == .bigZPrefix)
        #expect(info("\"").awaiting == .register)
        #expect(info("m").awaiting == .markSet)
        #expect(info("'").awaiting == .markJump)
        #expect(info("f").awaiting == .findChar)
        #expect(info("r").awaiting == .replaceChar)
        #expect(info("q").awaiting == .macroRecord)
        #expect(info("@").awaiting == .macroPlay)
        #expect(info("d").awaiting == .motion)
        #expect(info("d").op == .delete)
        #expect(info("di").awaiting == .textObject)
        #expect(info("g~").op == .swapCase)
        #expect(info("\"a2d3").count == 6)
        #expect(info("\"a2d").register == "a")
        #expect(info("\"a2d").display == "\"a2d")
        #expect(info("12").count == 12)
        #expect(info("12").awaiting == .none)
    }

    @Test("operator-pending is visible to the host")
    func operatorPending() {
        #expect(VimEngine.isOperatorPending(vimRun("c", "|a").0))
        #expect(!VimEngine.isOperatorPending(vimRun("cw", "|a").0))
    }
}
