import Testing
import Foundation
@testable import LumiKit

@Suite("Vim — block cursor selection (engine contract)")
struct VimBlockCursorContractTests {
    /// The controller side of block-cursor rendering relies on an invariant
    /// from the engine: in normal mode the cursor sits ON a character, not
    /// past the end. These tests pin that contract.
    @Test("cursor never past last character in normal after motion")
    func cursorOnCharacter() {
        var state = VimState.initial
        var buffer = TextBuffer(text: "abc", cursor: 0)
        for char: Character in ["l", "l", "l", "l"] {
            let r = VimEngine.handle(.character(char), state: state, buffer: buffer)
            state = r.state
            buffer = r.buffer
        }
        // 4 ls on "abc" → clamped to last character (index 2).
        #expect(buffer.cursor == 2)
        #expect(state.mode == .normal)
    }

    @Test("insert mode allows cursor past end")
    func insertPastEnd() {
        var state = VimState.initial
        var buffer = TextBuffer(text: "abc", cursor: 0)
        for input: VimInput in [.character("A"), .character("d")] {
            let r = VimEngine.handle(input, state: state, buffer: buffer)
            state = r.state
            buffer = r.buffer
        }
        // Ad → A jumps to end of line + insert; cursor is past 'c' (offset 4
        // because we appended 'd' to "abc").
        #expect(buffer.text == "abcd")
        #expect(buffer.cursor == 4)
        #expect(state.mode == .insert)
    }
}
