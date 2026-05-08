import Testing
import Foundation
@testable import LumiKit

/// Helpers to drive the engine in tests via a compact key-string interface.
private func run(_ keys: String, on text: String, cursor: Int = 0) -> VimEngine.Result {
    var state = VimState.initial
    var buffer = TextBuffer(text: text, cursor: cursor)
    for char in keys {
        let input: VimInput
        switch char {
        case "⎋": input = .escape
        case "⏎": input = .return
        case "⌫": input = .backspace
        case "⇥": input = .tab
        case "®": input = .controlR
        default: input = .character(char)
        }
        let result = VimEngine.handle(input, state: state, buffer: buffer)
        state = result.state
        buffer = result.buffer
    }
    return VimEngine.Result(state: state, buffer: buffer)
}

@Suite("Vim — motions")
struct VimMotionTests {
    @Test("hjkl basic movement")
    func hjkl() {
        var r = run("l", on: "hello")
        #expect(r.buffer.cursor == 1)
        r = run("lll", on: "hello")
        #expect(r.buffer.cursor == 3)
        r = run("h", on: "hello", cursor: 3)
        #expect(r.buffer.cursor == 2)
        r = run("j", on: "ab\ncd", cursor: 0)
        #expect(r.buffer.cursor == 3)
        r = run("k", on: "ab\ncd", cursor: 4)
        #expect(r.buffer.cursor == 1)
    }

    @Test("0 and $ jump to line bounds")
    func lineBounds() {
        var r = run("$", on: "hello world")
        #expect(r.buffer.cursor == 10)
        r = run("0", on: "hello world", cursor: 7)
        #expect(r.buffer.cursor == 0)
    }

    @Test("^ jumps to first non-blank")
    func firstNonBlank() {
        let r = run("^", on: "    indented")
        #expect(r.buffer.cursor == 4)
    }

    @Test("w moves to next word")
    func wordForward() {
        let r = run("w", on: "foo bar")
        #expect(r.buffer.cursor == 4)
    }

    @Test("b moves to previous word")
    func wordBack() {
        let r = run("b", on: "foo bar", cursor: 4)
        #expect(r.buffer.cursor == 0)
    }

    @Test("e moves to end of word")
    func wordEnd() {
        let r = run("e", on: "foo bar")
        #expect(r.buffer.cursor == 2)
    }

    @Test("count prefix repeats motion")
    func counts() {
        let r = run("3l", on: "abcdef")
        #expect(r.buffer.cursor == 3)
    }

    @Test("G goes to last line")
    func fileEnd() {
        let r = run("G", on: "a\nb\nc")
        #expect(r.buffer.cursorLine == 2)
    }
}

@Suite("Vim — operators")
struct VimOperatorTests {
    @Test("dw deletes a word")
    func dw() {
        let r = run("dw", on: "foo bar")
        #expect(r.buffer.text == "bar")
        #expect(r.state.defaultRegister.text == "foo ")
    }

    @Test("3dw deletes three words")
    func threeDw() {
        let r = run("3dw", on: "alpha beta gamma delta")
        #expect(r.buffer.text == "delta")
    }

    @Test("dd removes whole line and trailing newline")
    func dd() {
        let r = run("dd", on: "first\nsecond\n", cursor: 0)
        #expect(r.buffer.text == "second\n")
    }

    @Test("yy then p duplicates the line")
    func yyp() {
        let r = run("yyp", on: "hello\n")
        #expect(r.buffer.text == "hello\nhello\n")
    }

    @Test("yw then p inserts the word after the cursor")
    func ywp() {
        let r = run("yw$p", on: "foo")
        #expect(r.buffer.text.hasPrefix("foo"))
        #expect(r.buffer.text.contains("foo"))
    }

    @Test("x deletes the character under the cursor")
    func xDelete() {
        let r = run("x", on: "hello")
        #expect(r.buffer.text == "ello")
    }

    @Test("3x deletes three characters")
    func threeX() {
        let r = run("3x", on: "abcdef")
        #expect(r.buffer.text == "def")
    }

    @Test("cw enters insert mode after deleting word")
    func cw() {
        let r = run("cw", on: "foo bar")
        #expect(r.buffer.text == "bar")
        #expect(r.state.mode == .insert)
    }

    @Test("d$ deletes to end of line")
    func dEndOfLine() {
        let r = run("d$", on: "hello world", cursor: 5)
        #expect(r.buffer.text == "hello")
    }

    @Test("yw stores text in default register")
    func yankRegister() {
        let r = run("yw", on: "foo bar")
        #expect(r.state.defaultRegister.text == "foo ")
        #expect(r.state.defaultRegister.kind == .characterwise)
    }
}

@Suite("Vim — insert mode")
struct VimInsertTests {
    @Test("i inserts at cursor")
    func iInsert() {
        let r = run("ihi⎋", on: "world")
        #expect(r.buffer.text == "hiworld")
        #expect(r.state.mode == .normal)
    }

    @Test("a inserts after cursor")
    func aInsert() {
        let r = run("aX⎋", on: "ab", cursor: 0)
        #expect(r.buffer.text == "aXb")
    }

    @Test("A jumps to end of line and inserts")
    func capitalAInsert() {
        let r = run("AZ⎋", on: "hello")
        #expect(r.buffer.text == "helloZ")
    }

    @Test("o opens a new line below and enters insert")
    func openBelow() {
        let r = run("oworld⎋", on: "hello")
        #expect(r.buffer.text == "hello\nworld")
    }

    @Test("O opens a new line above and enters insert")
    func openAbove() {
        let r = run("Otop⎋", on: "main", cursor: 0)
        #expect(r.buffer.text == "top\nmain")
    }

    @Test("backspace in insert removes a character")
    func backspace() {
        let r = run("ax⌫⎋", on: "ab", cursor: 0)
        #expect(r.buffer.text == "ab")
    }
}

@Suite("Vim — undo / redo")
struct VimUndoTests {
    @Test("u reverts a delete")
    func undoDelete() {
        let r = run("dwu", on: "foo bar")
        #expect(r.buffer.text == "foo bar")
    }

    @Test("Ctrl-R re-applies an undone delete")
    func redoDelete() {
        let r = run("dwu®", on: "foo bar")
        #expect(r.buffer.text == "bar")
    }

    @Test("u reverts an insert session")
    func undoInsert() {
        let r = run("iHELLO⎋u", on: "world")
        #expect(r.buffer.text == "world")
    }
}
