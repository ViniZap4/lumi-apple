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

@Suite("Vim — search: /, ?, n, N")
struct VimSearchTests {
    @Test("/<pattern><CR> moves cursor to first forward match")
    func forwardSearch() {
        let r = run("/bar⏎", on: "foo bar baz")
        #expect(r.buffer.cursor == 4)
        #expect(r.state.mode == .normal)
        #expect(r.state.lastSearch?.pattern == "bar")
        #expect(r.state.lastSearch?.direction == .forward)
    }

    @Test("?<pattern><CR> moves cursor to last backward match before cursor")
    func backwardSearch() {
        // 'bar' at offsets 0 and 8 in "bar foo bar". From cursor 10 (the 'r')
        // the last 'bar' starting before cursor is at offset 8.
        let r = run("?bar⏎", on: "bar foo bar", cursor: 10)
        #expect(r.buffer.cursor == 8)
        #expect(r.state.lastSearch?.direction == .backward)
    }

    @Test("n repeats the last search forward; wraps at EOF")
    func nRepeats() {
        // 'bar' at 0, 8. From cursor 1, /bar⏎ jumps to 8; n wraps back to 0.
        let r = run("/bar⏎n", on: "bar foo bar", cursor: 1)
        #expect(r.buffer.cursor == 0)
    }

    @Test("N reverses last search direction")
    func nReverses() {
        // /bar⏎ from cursor 1 → 8. N reverses to backward, finds 'bar' before 8 → 0.
        let r = run("/bar⏎N", on: "bar foo bar", cursor: 1)
        #expect(r.buffer.cursor == 0)
    }

    @Test("3n advances forward through three matches")
    func countRepeat() {
        // 'a' at 0, 2, 4, 6, 8 in "aXaXaXaXa". From cursor 0, /a⏎ jumps to next
        // 'a' at offset 2. 3n advances three more times → 4, 6, 8.
        let r = run("/a⏎3n", on: "aXaXaXaXa")
        #expect(r.buffer.cursor == 8)
    }

    @Test("d/<pattern><CR> deletes up to but not including the match")
    func deleteToMatch() {
        let r = run("d/baz⏎", on: "foo bar baz")
        #expect(r.buffer.text == "baz")
        #expect(r.buffer.cursor == 0)
        #expect(r.state.mode == .normal)
    }

    @Test("c/<pattern><CR> deletes and enters insert mode")
    func changeToMatch() {
        let r = run("c/bar⏎", on: "foo bar baz")
        #expect(r.buffer.text == "bar baz")
        #expect(r.buffer.cursor == 0)
        #expect(r.state.mode == .insert)
    }

    @Test("y/<pattern><CR> yanks up to match, leaves buffer unchanged")
    func yankToMatch() {
        let r = run("y/baz⏎", on: "foo bar baz")
        #expect(r.buffer.text == "foo bar baz")
        #expect(r.state.defaultRegister.text == "foo bar ")
    }

    @Test("typing / starts command-line mode without moving cursor")
    func commandLineInProgress() {
        let r = run("/ba", on: "foo bar")
        if case let .commandLine(prefix, buffer) = r.state.mode {
            #expect(prefix == "/")
            #expect(buffer == "ba")
        } else {
            Issue.record("expected commandLine mode, got \(r.state.mode)")
        }
        #expect(r.buffer.cursor == 0)
    }

    @Test("ESC mid-pattern cancels search, leaves cursor and lastSearch alone")
    func escMidPattern() {
        let r = run("/ba⎋", on: "foo bar")
        #expect(r.state.mode == .normal)
        #expect(r.buffer.cursor == 0)
        #expect(r.state.lastSearch == nil)
    }

    @Test("ESC during d/<pattern> cancels pending operator")
    func escClearsPendingOperator() {
        let r = run("d/bar⎋", on: "foo bar baz")
        #expect(r.state.mode == .normal)
        #expect(r.state.pendingOperator == nil)
        #expect(r.buffer.text == "foo bar baz")
        #expect(r.buffer.cursor == 0)
    }

    @Test("backspace past empty pattern exits command-line mode")
    func backspacePastEmpty() {
        let r = run("/f⌫⌫", on: "abc")
        #expect(r.state.mode == .normal)
        #expect(r.buffer.cursor == 0)
    }

    @Test("no match leaves cursor unchanged and lastSearch nil")
    func noMatch() {
        let r = run("/qux⏎", on: "foo bar")
        #expect(r.buffer.cursor == 0)
        #expect(r.state.mode == .normal)
        #expect(r.state.lastSearch == nil)
    }

    @Test("empty-pattern <CR> repeats lastSearch using current prefix's direction")
    func emptyPatternRepeats() {
        // /bar⏎ from cursor 0 → 4. n → wraps... actually from cursor 4 forward,
        // next 'bar' is at 12 in "foo bar baz bar qux".
        // Then /⏎ (empty pattern) repeats forward from cursor 12; scans past
        // EOF and wraps back to first match at 4.
        let r = run("/bar⏎n/⏎", on: "foo bar baz bar qux")
        #expect(r.buffer.cursor == 4)
    }

    @Test("dot-repeat of bare search is a no-op (buffer unchanged → not captured)")
    func dotAfterBareSearch() {
        let r = run("/foo⏎.", on: "foo bar foo")
        // /foo⏎ from cursor 0: forward, skip cursor itself, next 'foo' at 8.
        // . then has no lastChange (search didn't modify the buffer).
        #expect(r.buffer.cursor == 8)
    }

    @Test("dot-repeat of d/<pattern> replays the full delete-to-search sequence")
    func dotAfterDeleteSearch() {
        let r = run("d/bar⏎.", on: "foo bar baz bar qux")
        // First d/bar⏎ deletes [0..4) → "bar baz bar qux", cursor 0.
        // Dot replays d/bar⏎ from cursor 0: next 'bar' is at 8 → delete [0..8) →
        // "bar qux", cursor 0.
        #expect(r.buffer.text == "bar qux")
        #expect(r.buffer.cursor == 0)
    }
}
