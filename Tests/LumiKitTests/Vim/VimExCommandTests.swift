import Testing
import Foundation
@testable import LumiKit

/// Like the other Vim test helpers, but also surfaces the *last* effect emitted
/// across the input sequence — ex commands fire on `<CR>`, which is typically
/// the last input, so the final Result effect is enough for these tests. We
/// thread effects explicitly because the standard helper rebuilds a `Result`
/// at the end and would otherwise drop them.
private struct ExRun: Sendable {
    var state: VimState
    var buffer: TextBuffer
    var lastEffect: VimEffect?
}

private func run(_ keys: String, on text: String, cursor: Int = 0) -> ExRun {
    var state = VimState.initial
    var buffer = TextBuffer(text: text, cursor: cursor)
    var lastEffect: VimEffect?
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
        if let e = result.effect { lastEffect = e }
    }
    return ExRun(state: state, buffer: buffer, lastEffect: lastEffect)
}

@Suite("Vim — ex commands: :w, :wq, :q")
struct VimExCommandTests {
    @Test(":w⏎ emits save effect and exits to normal")
    func write() {
        let r = run(":w⏎", on: "hello")
        #expect(r.lastEffect == .save)
        #expect(r.state.mode == .normal)
        #expect(r.buffer.text == "hello")
        #expect(r.buffer.cursor == 0)
    }

    @Test(":wq⏎ emits saveAndClose effect")
    func writeQuit() {
        let r = run(":wq⏎", on: "hello")
        #expect(r.lastEffect == .saveAndClose)
        #expect(r.state.mode == .normal)
    }

    @Test(":x⏎ is an alias for :wq")
    func xAlias() {
        let r = run(":x⏎", on: "hello")
        #expect(r.lastEffect == .saveAndClose)
    }

    @Test(":q⏎ emits close effect")
    func quit() {
        let r = run(":q⏎", on: "hello")
        #expect(r.lastEffect == .close)
        #expect(r.state.mode == .normal)
    }

    @Test("unknown ex command silently exits to normal with no effect")
    func unknown() {
        let r = run(":foobar⏎", on: "hello")
        #expect(r.lastEffect == nil)
        #expect(r.state.mode == .normal)
        #expect(r.buffer.text == "hello")
    }

    @Test("typing : starts command-line with `:` prefix")
    func colonInProgress() {
        let r = run(":w", on: "hello")
        if case let .commandLine(prefix, buffer) = r.state.mode {
            #expect(prefix == ":")
            #expect(buffer == "w")
        } else {
            Issue.record("expected commandLine mode, got \(r.state.mode)")
        }
        #expect(r.lastEffect == nil) // effect only fires on <CR>
    }

    @Test("ESC mid-ex cancels with no effect")
    func escMidCommand() {
        let r = run(":wq⎋", on: "hello")
        #expect(r.lastEffect == nil)
        #expect(r.state.mode == .normal)
    }

    @Test("backspace past empty exits command-line mode")
    func backspacePastEmpty() {
        let r = run(":⌫", on: "hello")
        #expect(r.state.mode == .normal)
        #expect(r.lastEffect == nil)
    }

    @Test("leading whitespace in ex buffer is tolerated")
    func leadingWhitespace() {
        let r = run(": w⏎", on: "hello")
        #expect(r.lastEffect == .save)
    }

    @Test(":w inside a macro emits save when the macro runs")
    func macroEmitsEffect() {
        // Record qa:w⏎q (save macro), then play with @a.
        let r = run("qa:w⏎q@a", on: "hello")
        #expect(r.lastEffect == .save)
        #expect(r.state.macros["a"]?.isEmpty == false)
    }

    @Test("empty `:⏎` (no command) is a no-op with no effect")
    func emptyExLine() {
        let r = run(":⏎", on: "hello")
        #expect(r.lastEffect == nil)
        #expect(r.state.mode == .normal)
    }
}
