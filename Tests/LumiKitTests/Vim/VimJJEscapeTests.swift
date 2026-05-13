import Testing
import Foundation
@testable import LumiKit

private func run(_ keys: String, on text: String, cursor: Int = 0, jjEscape: Bool = true) -> VimEngine.Result {
    var state = VimState(jjEscapeEnabled: jjEscape)
    var buffer = TextBuffer(text: text, cursor: cursor)
    for char in keys {
        let input: VimInput
        switch char {
        case "⎋": input = .escape
        case "⏎": input = .return
        case "⌫": input = .backspace
        case "⇥": input = .tab
        default: input = .character(char)
        }
        let result = VimEngine.handle(input, state: state, buffer: buffer)
        state = result.state
        buffer = result.buffer
    }
    return VimEngine.Result(state: state, buffer: buffer)
}

@Suite("Vim — jj → Esc mapping")
struct VimJJEscapeTests {
    @Test("ijj exits insert mode and removes the buffered first j")
    func basicJJ() {
        // Start in normal, enter insert with `i`, type `j` then `j`.
        // Buffer should remain "abc" (the first j is removed by the mapping).
        let r = run("ijj", on: "abc", cursor: 0)
        #expect(r.state.mode == .normal)
        #expect(r.buffer.text == "abc")
    }

    @Test("ijoke leaves text intact (j followed by non-j keeps the j)")
    func singleJNoMap() {
        let r = run("ijoke", on: "", cursor: 0)
        #expect(r.state.mode == .insert)
        #expect(r.buffer.text == "joke")
    }

    @Test("ijajbjj exits with cleanly-typed content")
    func interruptedJJ() {
        // ijaj: insert j, a, j. Then bj: another j followed by 'b' — that
        // 'b' would be inserted, not consumed. Wait, the run continues `jj`
        // at the end which now triggers the mapping (deletes the prior j,
        // exits insert). Test that the intermediate text survives.
        let r = run("ijajbjj", on: "", cursor: 0)
        #expect(r.state.mode == .normal)
        #expect(r.buffer.text == "jajb")
    }

    @Test("jjEscape disabled inserts both j's verbatim")
    func disabled() {
        let r = run("ijj", on: "", cursor: 0, jjEscape: false)
        #expect(r.state.mode == .insert)
        #expect(r.buffer.text == "jj")
    }

    @Test("ESC clears the jj-armed flag so a later j doesn't escape early")
    func escClearsArm() {
        // Type ij, ESC, ij — should NOT auto-escape on the third j.
        let r = run("ij⎋ij", on: "", cursor: 0)
        #expect(r.state.mode == .insert)
        #expect(r.buffer.text == "jj")
    }

    @Test("intervening character clears the arm")
    func interveningClears() {
        // ija j — second j shouldn't trigger because 'a' came in between.
        let r = run("ijaj", on: "", cursor: 0)
        #expect(r.state.mode == .insert)
        #expect(r.buffer.text == "jaj")
    }
}
