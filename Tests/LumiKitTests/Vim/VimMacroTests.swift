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

@Suite("Vim — macros")
struct VimMacroTests {
    @Test("qa…q records into register a")
    func recordingStores() {
        let r = run("qadwq", on: "foo bar")
        // dw deletes "foo " → "bar". The macro a should hold [d, w].
        #expect(r.buffer.text == "bar")
        #expect(r.state.macros["a"]?.count == 2)
    }

    @Test("@a plays the recorded macro")
    func playOnce() {
        // Record dw, then play it once: deletes another word.
        let r = run("qadwq@a", on: "foo bar baz")
        #expect(r.buffer.text == "baz")
    }

    @Test("count repeats macro: 2@a")
    func countedPlay() {
        let r = run("qadwq2@a", on: "alpha beta gamma delta")
        // qadwq removes "alpha " → "beta gamma delta"
        // 2@a plays twice: removes "beta " and "gamma " → "delta"
        #expect(r.buffer.text == "delta")
    }

    @Test("@@ replays the last macro")
    func replayLast() {
        let r = run("qadwq@a@@", on: "a b c d")
        // qadwq → "b c d". @a → "c d". @@ → "d".
        #expect(r.buffer.text == "d")
    }

    @Test("playing a missing macro is a no-op")
    func missingMacro() {
        let r = run("@z", on: "hello")
        #expect(r.buffer.text == "hello")
    }

    @Test("empty macro plays as no-op")
    func emptyMacro() {
        let r = run("qaq@a", on: "hello")
        // qa starts recording in a; q stops immediately. macros[a] is empty.
        #expect(r.buffer.text == "hello")
        #expect(r.state.macros["a"]?.isEmpty == true)
    }

    @Test("recursive macro hits depth limit and unwinds cleanly")
    func recursionGuard() {
        // Pre-load a macro that calls itself; don't try to record it (the
        // recording path also recurses, so we'd test two things at once).
        var state = VimState.initial
        state.macros["a"] = [.character("@"), .character("a")]
        var buffer = TextBuffer(text: "hello", cursor: 0)
        // Trigger the recursion via @a.
        for input: VimInput in [.character("@"), .character("a")] {
            let r = VimEngine.handle(input, state: state, buffer: buffer)
            state = r.state
            buffer = r.buffer
        }
        // Engine recovered cleanly: depth back to zero, not flagged as playing.
        #expect(state.macroDepth == 0)
        #expect(state.isPlayingMacro == false)
        #expect(buffer.text == "hello")
    }

    @Test("dot replays the last change inside a macro, not the macro")
    func dotInsideMacro() {
        // qadwq records dw. After playback, the most recent change is dw,
        // so . repeats dw (not the macro).
        let r = run("qadwq@a.", on: "a b c d e")
        // qadwq → "b c d e". @a → "c d e". . → "d e".
        #expect(r.buffer.text == "d e")
    }

    @Test("macro recording captures the full insert session")
    func recordingContent() {
        // qa starts recording in a; iAB⎋ inserts "AB" and exits insert; q stops.
        // Recorded macro should be exactly [i, A, B, ⎋].
        let r = run("qaiAB⎋q", on: "world")
        #expect(r.state.macros["a"] == [
            .character("i"),
            .character("A"),
            .character("B"),
            .escape
        ])
    }

    @Test("macros can be re-recorded over")
    func overwriteMacro() {
        let r = run("qadwqqaxq", on: "foo bar")
        // First qadwq deletes "foo " → "bar" and saves [d, w] in a.
        // Second qaxq deletes "b" → "ar" and overwrites a with [x].
        #expect(r.state.macros["a"] == [.character("x")])
    }
}
