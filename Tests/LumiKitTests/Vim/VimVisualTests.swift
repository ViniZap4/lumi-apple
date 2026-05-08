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

@Suite("Vim — visual mode")
struct VimVisualTests {
    @Test("v enters characterwise visual with anchor at cursor")
    func enterVisualChar() {
        let r = run("v", on: "hello", cursor: 2)
        if case let .visual(kind, anchor) = r.state.mode {
            #expect(kind == .characterwise)
            #expect(anchor == 2)
        } else {
            Issue.record("expected visual mode")
        }
    }

    @Test("V enters linewise visual")
    func enterVisualLine() {
        let r = run("V", on: "a\nb\nc", cursor: 2)
        if case let .visual(kind, _) = r.state.mode {
            #expect(kind == .linewise)
        } else {
            Issue.record("expected linewise visual")
        }
    }

    @Test("ESC exits visual back to normal")
    func escExitsVisual() {
        let r = run("v⎋", on: "hello")
        #expect(r.state.mode == .normal)
    }

    @Test("v in visual char exits to normal")
    func vToggleExits() {
        let r = run("vv", on: "hello")
        #expect(r.state.mode == .normal)
    }

    @Test("V in visual line exits to normal")
    func capitalVToggleExits() {
        let r = run("VV", on: "a\nb")
        #expect(r.state.mode == .normal)
    }

    @Test("v then V switches to linewise visual")
    func switchCharToLine() {
        let r = run("vV", on: "abc")
        if case let .visual(kind, _) = r.state.mode {
            #expect(kind == .linewise)
        } else {
            Issue.record("expected linewise visual")
        }
    }

    @Test("vlld deletes 3 chars")
    func deleteRangeForward() {
        let r = run("vlld", on: "abcdef")
        #expect(r.buffer.text == "def")
        #expect(r.state.mode == .normal)
    }

    @Test("v$d deletes to end of line")
    func deleteToEndOfLine() {
        let r = run("v$d", on: "hello world")
        #expect(r.buffer.text.isEmpty || r.buffer.text == "")
    }

    @Test("Vd deletes the entire current line")
    func linewiseDelete() {
        let r = run("Vd", on: "first\nsecond\n", cursor: 0)
        #expect(r.buffer.text == "second\n")
    }

    @Test("vlly yanks 3 chars and exits visual")
    func yankCharacterwise() {
        let r = run("vlly", on: "abcdef")
        #expect(r.state.defaultRegister.text == "abc")
        #expect(r.state.defaultRegister.kind == .characterwise)
        #expect(r.state.mode == .normal)
    }

    @Test("Vy yanks the line as linewise")
    func yankLinewise() {
        let r = run("Vy", on: "hello\nworld", cursor: 0)
        #expect(r.state.defaultRegister.kind == .linewise)
        #expect(r.state.defaultRegister.text.contains("hello"))
    }

    @Test("vc deletes selection and enters insert")
    func changeFromVisual() {
        let r = run("vlc", on: "abcdef")
        #expect(r.buffer.text == "cdef")
        #expect(r.state.mode == .insert)
    }

    @Test("o swaps anchor and cursor in visual")
    func swapAnchor() {
        let r = run("vllo", on: "abcdef")
        if case let .visual(_, anchor) = r.state.mode {
            #expect(anchor == 2)
            #expect(r.buffer.cursor == 0)
        } else {
            Issue.record("expected visual mode")
        }
    }

    @Test("vh extends selection backward")
    func extendBackward() {
        let r = run("lllvhh", on: "abcdef")
        if case let .visual(_, anchor) = r.state.mode {
            #expect(anchor == 3)
            #expect(r.buffer.cursor == 1)
        } else {
            Issue.record("expected visual mode")
        }
    }
}
