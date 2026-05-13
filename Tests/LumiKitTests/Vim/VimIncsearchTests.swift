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

@Suite("Vim — incsearch (live preview while typing)")
struct VimIncsearchTests {
    @Test("cursor previews first match as the pattern grows")
    func previewGrows() {
        // 'foo bar baz' — typing /b should preview at offset 4 ('b' in 'bar').
        let r = run("/b", on: "foo bar baz")
        #expect(r.buffer.cursor == 4)
        // After typing /ba, preview is still at 'ba' which starts at 4.
        let r2 = run("/ba", on: "foo bar baz")
        #expect(r2.buffer.cursor == 4)
    }

    @Test("backspace shrinks pattern and reruns preview from snapshot")
    func backspaceShrinks() {
        // 'foo bar baz' — /baz → preview at 8. ⌫ to /ba → preview at 4.
        let r = run("/baz⌫", on: "foo bar baz")
        #expect(r.buffer.cursor == 4)
    }

    @Test("no match while typing leaves cursor at the snapshot")
    func noMatchKeepsSnapshot() {
        // 'foo bar' has no 'q'. Typing /q leaves cursor at the original 0.
        let r = run("/q", on: "foo bar", cursor: 0)
        #expect(r.buffer.cursor == 0)
    }

    @Test("ESC during incsearch restores the entry cursor")
    func escRestores() {
        // Type /baz to preview at 8, then ESC — cursor returns to entry (0).
        let r = run("/baz⎋", on: "foo bar baz")
        #expect(r.buffer.cursor == 0)
        #expect(r.state.mode == .normal)
    }

    @Test("backspace past empty restores the entry cursor")
    func backspacePastEmptyRestores() {
        // /b previews at 4. ⌫ to empty resets cursor to snapshot 0. Another ⌫
        // exits to normal at 0.
        let r = run("/b⌫⌫", on: "foo bar baz", cursor: 0)
        #expect(r.buffer.cursor == 0)
        #expect(r.state.mode == .normal)
    }

    @Test("<CR> commits at the preview position")
    func enterCommitsPreview() {
        let r = run("/bar⏎", on: "foo bar baz", cursor: 0)
        #expect(r.buffer.cursor == 4)
        #expect(r.state.lastSearch?.pattern == "bar")
    }

    @Test("d/foo<CR> deletes from the snapshot, not the live preview")
    func operatorUsesSnapshot() {
        // Without the snapshot-restore on <CR>, the live cursor would have
        // moved to 4 while typing /baz, and the delete would collapse to a
        // zero-length range. Verify the delete spans [0, 8).
        let r = run("d/baz⏎", on: "foo bar baz", cursor: 0)
        #expect(r.buffer.text == "baz")
        #expect(r.buffer.cursor == 0)
    }

    @Test("? backward search previews the last match before the cursor")
    func backwardPreview() {
        // 'bar' at 0, 8. From cursor 10, ?bar previews at 8.
        let r = run("?bar", on: "bar foo bar", cursor: 10)
        #expect(r.buffer.cursor == 8)
    }

    @Test("ex commands do not preview (cursor stays put while typing :w)")
    func exNoPreview() {
        let r = run(":w", on: "foo bar baz", cursor: 5)
        #expect(r.buffer.cursor == 5)
    }
}
