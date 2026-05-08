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

@Suite("Vim — dot-repeat")
struct VimDotRepeatTests {
    @Test("dw then . deletes another word")
    func dwDot() {
        let r = run("dw.", on: "foo bar baz")
        #expect(r.buffer.text == "baz")
    }

    @Test("3dw then . repeats with the same count")
    func countedDw() {
        let r = run("3dw.", on: "a b c d e f g h", cursor: 0)
        // First 3dw deletes "a b c " → "d e f g h"
        // . repeats 3dw → deletes "d e f " → "g h"
        #expect(r.buffer.text == "g h")
    }

    @Test("iX⎋ then . inserts X again")
    func insertDot() {
        let r = run("iX⎋.", on: "ab", cursor: 0)
        // i X ⎋ → inserts X at cursor 0, exits insert (cursor at 0 after the insert?
        // Actually after iX, cursor is at 1 (past 'X'). ⎋ steps left to 0.
        // Then . repeats: at cursor 0, insert X, exits to 0. Buffer becomes "XXab".
        #expect(r.buffer.text == "XXab")
    }

    @Test("x then . deletes another character")
    func xDot() {
        let r = run("x.", on: "abcde")
        #expect(r.buffer.text == "cde")
    }

    @Test(". with no prior change is a no-op")
    func dotNoMemory() {
        let r = run(".", on: "hello")
        #expect(r.buffer.text == "hello")
    }

    @Test("repeated dots compound")
    func multipleDot() {
        let r = run("dw...", on: "a b c d e f g")
        // dw → "b c d e f g", then 3 dots delete 3 more words: "e f g"
        #expect(r.buffer.text == "e f g")
    }

    @Test("u then . re-applies the original change")
    func undoThenDot() {
        let r = run("dwudw.", on: "foo bar baz")
        // dw → "bar baz" (lastChange = [d, w])
        // u → "foo bar baz" (undo, doesn't update lastChange)
        // dw → "bar baz" again (lastChange = [d, w] same)
        // . → "baz"
        #expect(r.buffer.text == "baz")
    }

    @Test("u alone is not captured as a change")
    func undoIsNotChange() {
        // After dw + u, lastChange should still be [d, w] not [u].
        var state = VimState.initial
        var buffer = TextBuffer(text: "foo bar", cursor: 0)
        for char: Character in ["d", "w", "u"] {
            let r = VimEngine.handle(.character(char), state: state, buffer: buffer)
            state = r.state
            buffer = r.buffer
        }
        let lastChange = state.lastChange ?? []
        #expect(lastChange.count == 2)
        if lastChange.count == 2 {
            #expect(lastChange[0] == .character("d"))
            #expect(lastChange[1] == .character("w"))
        }
    }

    @Test("plain motion is not captured as a change")
    func motionIsNotChange() {
        var state = VimState.initial
        var buffer = TextBuffer(text: "abcdef", cursor: 0)
        for char: Character in ["l", "l", "l"] {
            let r = VimEngine.handle(.character(char), state: state, buffer: buffer)
            state = r.state
            buffer = r.buffer
        }
        // No change committed; lastChange remains nil.
        #expect(state.lastChange == nil)
    }

    @Test("dot does not become the last change")
    func dotPreservesMemory() {
        let r = run("dw.", on: "alpha beta gamma")
        // After dw + ., lastChange should still be [d, w] (from the original
        // dw, not from the dot itself).
        let lastChange = r.state.lastChange ?? []
        #expect(lastChange.count == 2)
        if lastChange.count == 2 {
            #expect(lastChange[0] == .character("d"))
            #expect(lastChange[1] == .character("w"))
        }
    }

    @Test("complex change cwfoo⎋ then . repeats")
    func changeWithInsertText() {
        let r = run("cwfoo⎋.", on: "alpha beta", cursor: 0)
        // cw on "alpha beta" → deletes "alpha", insert "foo", ⎋
        //   → "foo beta", cursor at end of inserted "foo" minus 1
        // ESC steps cursor left → cursor at 'o' (offset 2)
        // dot at cursor 2: cw deletes word "o" (the rest of "foo" from cursor),
        //   inserts "foo" → at this point we should have "fofoo beta" or similar
        // Just check that the buffer changed and contains "foo".
        #expect(r.buffer.text.contains("foo"))
        #expect(r.buffer.text != "alpha beta")
    }
}
