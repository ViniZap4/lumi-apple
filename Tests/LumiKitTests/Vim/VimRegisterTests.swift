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

@Suite("Vim — named registers")
struct VimRegisterTests {
    @Test("\"ayw stores the word in register a")
    func yankToNamedRegister() {
        let r = run("\"ayw", on: "foo bar")
        #expect(r.state.registers["a"]?.text == "foo ")
    }

    @Test("named yank also writes the unnamed register")
    func mirrorsToDefault() {
        let r = run("\"ayw", on: "foo bar")
        #expect(r.state.defaultRegister.text == "foo ")
        #expect(r.state.registers["a"]?.text == "foo ")
    }

    @Test("\"adw moves the deleted text to register a")
    func deleteToNamedRegister() {
        let r = run("\"adw", on: "foo bar")
        #expect(r.buffer.text == "bar")
        #expect(r.state.registers["a"]?.text == "foo ")
    }

    @Test("\"ayw\"ap pastes from a")
    func pasteFromNamedRegister() {
        // yw → "foo " in register a. Cursor still at 0 (yank doesn't move).
        // ap → paste characterwise after cursor → "ffoo oo bar".
        let r = run("\"ayw\"ap", on: "foo bar")
        #expect(r.state.registers["a"]?.text == "foo ")
        #expect(r.buffer.text.contains("foo "))
    }

    @Test("paste from empty register is a no-op")
    func pasteEmpty() {
        let r = run("\"zp", on: "abc")
        #expect(r.buffer.text == "abc")
    }

    @Test("named registers persist across other operations")
    func registerPersists() {
        // Yank to a, then a different yank with no prefix overwrites only default.
        let r = run("\"aywyy", on: "foo bar\n", cursor: 0)
        #expect(r.state.registers["a"]?.text == "foo ")
        #expect(r.state.defaultRegister.text == "foo bar\n")
    }

    @Test("ESC clears pending register")
    func escClearsRegister() {
        let r = run("\"a⎋", on: "foo")
        #expect(r.state.pendingRegister == nil)
        #expect(r.state.awaitingRegisterChar == false)
    }

    @Test("uppercase register name is also valid")
    func uppercaseRegister() {
        let r = run("\"Ayw", on: "foo bar")
        #expect(r.state.registers["A"]?.text == "foo ")
    }

    @Test("digit after \" is rejected (only letters)")
    func nonLetterRegister() {
        let r = run("\"1yw", on: "foo bar")
        // "1" rejected → no pending register; yw runs as a normal yank.
        #expect(r.state.registers["1"] == nil)
        #expect(r.state.defaultRegister.text == "foo ")
    }
}
