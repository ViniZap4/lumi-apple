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

@Suite("Vim — find / till motions")
struct VimFindTests {
    @Test("f finds first occurrence forward")
    func fForward() {
        let r = run("fb", on: "foo bar")
        #expect(r.buffer.cursor == 4)
    }

    @Test("F finds first occurrence backward")
    func fBackward() {
        let r = run("Fo", on: "foo bar", cursor: 6)
        #expect(r.buffer.cursor == 2)
    }

    @Test("t stops one before the target forward")
    func tForward() {
        let r = run("tb", on: "foo bar")
        #expect(r.buffer.cursor == 3)
    }

    @Test("T stops one after the target backward")
    func tBackward() {
        let r = run("Tf", on: "foo bar", cursor: 6)
        #expect(r.buffer.cursor == 1)
    }

    @Test("count finds the Nth occurrence")
    func countFind() {
        // 'a' positions strictly after cursor 0: 4, 7, 9, 11, 14, 16, 18.
        // The 3rd is at offset 9.
        let r = run("3fa", on: "alpha banana papaya")
        #expect(r.buffer.cursor == 9)
    }

    @Test("find does not cross newlines")
    func lineScoped() {
        let r = run("fz", on: "foo\nbaz", cursor: 0)
        // No 'z' on the cursor's line — cursor should not move.
        #expect(r.buffer.cursor == 0)
    }

    @Test("dfx deletes through the target inclusive")
    func operatorPlusF() {
        let r = run("dfb", on: "foo bar baz")
        #expect(r.buffer.text == "ar baz")
    }

    @Test("dtx deletes up to but not including the target")
    func operatorPlusT() {
        let r = run("dtb", on: "foo bar baz")
        #expect(r.buffer.text == "bar baz")
    }

    @Test("yfx yanks through the target inclusive")
    func yankThroughFind() {
        // From cursor 0 ('f'), yf<space> includes f, o, o, and the space.
        let r = run("yf ", on: "foo bar")
        #expect(r.state.defaultRegister.text == "foo ")
    }
}
