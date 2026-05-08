import Testing
import Foundation
@testable import LumiKit

private func run(_ keys: String, on text: String, cursor: Int = 0) -> VimEngine.Result {
    var state = VimState.initial
    var buffer = TextBuffer(text: text, cursor: cursor)
    for char in keys {
        let input: VimInput
        switch char {
        case "⎋": input = .escape
        default: input = .character(char)
        }
        let result = VimEngine.handle(input, state: state, buffer: buffer)
        state = result.state
        buffer = result.buffer
    }
    return VimEngine.Result(state: state, buffer: buffer)
}

@Suite("Vim — marks")
struct VimMarkTests {
    @Test("ma stores the cursor position under mark a")
    func setMark() {
        let r = run("llma", on: "hello")
        #expect(r.state.marks["a"] == 2)
    }

    @Test("`a jumps to the exact saved position")
    func exactJump() {
        // cursor=0, ll moves to 2, ma stores, llll moves further, `a returns to 2.
        let r = run("llmallll`a", on: "hello world")
        #expect(r.buffer.cursor == 2)
    }

    @Test("'a jumps to the start of the marked line")
    func lineJump() {
        // "first\nsecond" — go to second line, mark, return to start, jump to 'a.
        let r = run("jllmagg'a", on: "first\nsecond")
        #expect(r.buffer.cursor == 6) // start of "second"
    }

    @Test("jump to unset mark is a no-op")
    func unsetMark() {
        let r = run("`z", on: "hello", cursor: 2)
        #expect(r.buffer.cursor == 2)
    }

    @Test("ESC clears awaiting mark state")
    func escClearsAwaiting() {
        let r = run("m⎋", on: "abc")
        #expect(r.state.awaitingMarkSet == false)
    }

    @Test("d`a deletes characterwise to the marked position")
    func deleteToExactMark() {
        // "abcdefg" cursor=2, ma → mark 'a' at 2.
        // h h moves to 0. d`a deletes [0..3) → "defg".
        let r = run("llmahhd`a", on: "abcdefg")
        #expect(r.buffer.text == "defg")
    }

    @Test("d'a deletes the entire marked line linewise")
    func deleteToLineMark() {
        // "alpha\nbeta\ngamma" — go to "beta", mark, jump to start, d'a.
        // Should delete from start through "beta" line linewise.
        let r = run("jmagg'a", on: "alpha\nbeta\ngamma")
        // After 'a we're at line 1 (beta). Now do d'a from cursor at 0 (line 0).
        // We need a fresh sequence; the above run ends with cursor on line 1.
        // Use a separate sequence:
        let r2 = run("jmaggd'a", on: "alpha\nbeta\ngamma")
        // Cursor at start of "alpha" (0). Mark 'a' at start of "beta" (line 1).
        // d'a deletes lines 0..1 inclusive linewise.
        #expect(r2.buffer.text == "gamma")
        _ = r // silence warning
    }

    @Test("marks survive unrelated operations")
    func marksPersist() {
        let r = run("llmallll", on: "hello world")
        #expect(r.state.marks["a"] == 2)
    }
}
