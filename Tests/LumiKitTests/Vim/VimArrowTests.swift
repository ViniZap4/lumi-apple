import Testing
import Foundation
@testable import LumiKit

private func run(_ inputs: [VimInput], on text: String, cursor: Int = 0) -> VimEngine.Result {
    var state = VimState()
    var buffer = TextBuffer(text: text, cursor: cursor)
    for input in inputs {
        let r = VimEngine.handle(input, state: state, buffer: buffer)
        state = r.state
        buffer = r.buffer
    }
    return VimEngine.Result(state: state, buffer: buffer)
}

@Suite("Vim — arrow keys")
struct VimArrowTests {
    @Test("insert-mode arrows move the cursor and never type hjkl")
    func insertArrows() {
        let r = run([.character("i"), .arrow(.right), .arrow(.right), .character("X")], on: "abc\ndef")
        #expect(r.buffer.text == "abXc\ndef")
        #expect(r.state.mode == .insert)

        let down = run([.character("i"), .arrow(.right), .arrow(.down), .character("Y")], on: "abc\ndef")
        #expect(down.buffer.text == "abc\ndYef")

        let up = run([.character("i"), .arrow(.up), .arrow(.left), .character("Z")], on: "abc\ndef", cursor: 6)
        #expect(up.buffer.text == "aZbc\ndef")
    }

    @Test("insert-mode arrows stop at line boundaries and clamp the column")
    func insertBounds() {
        let r = run([.character("i"), .arrow(.left), .arrow(.up), .character("Q")], on: "ab\ncd")
        #expect(r.buffer.text == "Qab\ncd")
        let clamp = run([.character("A"), .arrow(.down), .character("!")], on: "abcdef\nxy")
        #expect(clamp.buffer.text == "abcdef\nxy!")
    }

    @Test("normal and visual arrows are the hjkl motions")
    func normalArrows() {
        let r = run([.arrow(.right), .arrow(.right), .character("x")], on: "abcd")
        #expect(r.buffer.text == "abd")
        let v = run([.character("v"), .arrow(.right), .character("d")], on: "abcd")
        #expect(v.buffer.text == "cd")
        let j = run([.arrow(.down), .character("x")], on: "ab\ncd")
        #expect(j.buffer.text == "ab\nd")
    }

    @Test("command-line up/down arrows walk history")
    func commandLineArrows() {
        var state = VimState(exHistory: ["w", "q"])
        var buffer = TextBuffer(text: "abc", cursor: 0)
        for input: VimInput in [.character(":"), .arrow(.up)] {
            let r = VimEngine.handle(input, state: state, buffer: buffer)
            state = r.state
            buffer = r.buffer
        }
        #expect(state.mode == .commandLine(prefix: ":", buffer: "q"))
    }
}
