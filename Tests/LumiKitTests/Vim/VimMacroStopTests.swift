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

@Suite("Vim — mode-independent macro `q` stop")
struct VimMacroStopTests {
    @Test("q in insert mode stops recording and leaves user in insert")
    func qStopsFromInsert() {
        // qa i hello q — record `i hello` (the `q` is trimmed by finalize),
        // stop, stay in insert. The `q` is NOT inserted into the buffer.
        let r = run("qaihelloq", on: "")
        if let inputs = r.state.macros["a"] {
            #expect(inputs == [.character("i"), .character("h"), .character("e"), .character("l"), .character("l"), .character("o")])
        } else {
            Issue.record("expected macro a to be recorded")
        }
        #expect(r.state.recordingMacro == nil)
        #expect(r.state.mode == .insert)
        #expect(r.buffer.text == "hello")
    }

    @Test("playing the macro recorded from insert replays the insert session")
    func playInsertMacro() {
        // Record qa i X ⎋ q on empty buffer → macro is [i, X, ⎋].
        // Reset to normal, then @a should insert 'X' and exit to normal.
        let r = run("qaiX⎋q@a", on: "")
        #expect(r.buffer.text == "XX")
        #expect(r.state.mode == .normal)
    }

    @Test("q in visual mode stops recording without consuming the selection")
    func qStopsFromVisual() {
        // qa v l q — start record, enter visual, move right once, stop.
        // Macro should be [v, l]. Mode remains visual.
        let r = run("qavlq", on: "hello", cursor: 0)
        if let inputs = r.state.macros["a"] {
            #expect(inputs == [.character("v"), .character("l")])
        } else {
            Issue.record("expected macro a to be recorded")
        }
        if case .visual = r.state.mode { } else {
            Issue.record("expected to remain in visual mode, got \(r.state.mode)")
        }
    }

    @Test("q in normal mode still works (regression)")
    func qStillStopsFromNormal() {
        let r = run("qadwq", on: "foo bar")
        #expect(r.state.macros["a"] == [.character("d"), .character("w")])
        #expect(r.state.mode == .normal)
    }

    @Test("typing a literal q while not recording inserts a q (no special handling)")
    func qLiteralWhenNotRecording() {
        // Without an active recording, `i q ⎋` should insert 'q'.
        let r = run("iq⎋", on: "")
        #expect(r.buffer.text == "q")
    }

    @Test("q inside a played macro does not stop an outer recording")
    func playedQDoesNotStopOuterRecording() {
        // First record macro b as just `q` would not work (recording stops),
        // so record `iX⎋` into b. Then start recording a outer macro and play
        // b inside it; the outer recording should still be active until we
        // press `q` ourselves.
        // Record b: i X ⎋ q.
        // Then record a: q a @b q — start a, play b (which inserts X and exits
        // insert), then `q` stops a. Outer macro a should contain [@,b].
        // (finalize trims the trailing q.)
        let r = run("qbiX⎋qqa@bq", on: "")
        #expect(r.state.macros["b"] == [.character("i"), .character("X"), .escape])
        #expect(r.state.macros["a"] == [.character("@"), .character("b")])
        // First `qbiX⎋q` leaves buffer = "X". Then `qa@b` plays b again,
        // which inserts another 'X' at cursor 0 → "XX".
        #expect(r.buffer.text == "XX")
    }
}
