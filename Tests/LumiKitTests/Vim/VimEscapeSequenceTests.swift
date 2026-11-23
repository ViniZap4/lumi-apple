import Testing
import Foundation
@testable import LumiKit

/// Drive the engine with per-key timestamps.
private func run(
    _ keys: String,
    on text: String = "",
    sequences: [String],
    jj: Bool = false,
    timeout: TimeInterval = 0.2,
    times: [TimeInterval]? = nil
) -> VimEngine.Result {
    var state = VimState(jjEscapeEnabled: jj, escapeSequences: sequences, escapeTimeout: timeout)
    var buffer = TextBuffer(text: text, cursor: 0)
    for (i, ch) in keys.enumerated() {
        let input: VimInput = ch == "⎋" ? .escape : (ch == "⏎" ? .return : .character(ch))
        let t = times.map { $0[i] } ?? Double(i) * 0.05
        let r = VimEngine.handle(input, state: state, buffer: buffer, at: t)
        state = r.state
        buffer = r.buffer
    }
    return VimEngine.Result(state: state, buffer: buffer)
}

@Suite("Vim — insert-mode escape sequences (web parity)")
struct VimEscapeSequenceTests {
    @Test("jk typed quickly leaves insert and removes the typed j")
    func jk() {
        let r = run("iabjk", sequences: ["jk"])
        #expect(r.state.mode == .normal)
        #expect(r.buffer.text == "ab")
    }

    @Test("ff works too (same key twice)")
    func ff() {
        let r = run("ixff", sequences: ["ff"])
        #expect(r.state.mode == .normal)
        #expect(r.buffer.text == "x")
    }

    @Test("a slow second key types literally")
    func timeout() {
        let r = run("ijk", sequences: ["jk"], times: [0, 0.1, 0.9])
        #expect(r.state.mode == .insert)
        #expect(r.buffer.text == "jk")
    }

    @Test("a lone first key stays in the text")
    func lonePrefix() {
        let r = run("ijoke", sequences: ["jk"])
        #expect(r.state.mode == .insert)
        #expect(r.buffer.text == "joke")
    }

    @Test("overlapping prefix: jjk with jk still escapes")
    func overlap() {
        let r = run("ijjk", sequences: ["jk"])
        #expect(r.state.mode == .normal)
        #expect(r.buffer.text == "j")
    }

    @Test("three-key sequence")
    func threeKeys() {
        let r = run("iab;;q", sequences: [";;q"])
        #expect(r.state.mode == .normal)
        #expect(r.buffer.text == "ab")
    }

    @Test("Return breaks the run")
    func returnBreaks() {
        let r = run("ij⏎k", sequences: ["jk"])
        #expect(r.state.mode == .insert)
        #expect(r.buffer.text == "j\nk")
    }

    @Test("legacy jj toggle and a custom list combine")
    func combined() {
        #expect(run("iajj", sequences: ["kj"], jj: true).buffer.text == "a")
        #expect(run("iakj", sequences: ["kj"], jj: true).state.mode == .normal)
    }

    @Test("untimed handle never times out (macro / dot replay)")
    func untimed() {
        var state = VimState(escapeSequences: ["jk"])
        var buffer = TextBuffer(text: "", cursor: 0)
        for ch in "ijk" {
            let r = VimEngine.handle(.character(ch), state: state, buffer: buffer)
            state = r.state
            buffer = r.buffer
        }
        #expect(state.mode == .normal)
        #expect(buffer.text.isEmpty)
    }

    @Test("validation mirrors the web rules")
    func validation() {
        #expect(EscapeSequences.validate("jk") == .success("jk"))
        #expect(EscapeSequences.validate("j") == .failure(.tooShort))
        #expect(EscapeSequences.validate("abcde") == .failure(.tooLong))
        #expect(EscapeSequences.validate("j k") == .failure(.whitespace))
        #expect(EscapeSequences.validate("<Esc>") == .failure(.tooLong))
        #expect(EscapeSequences.validate("<CR") == .failure(.keyNotation))
        #expect(EscapeSequences.sanitize(["jk", "jk", "x", "ff"]) == ["jk", "ff"])
        #expect(EscapeSequences.decode(EscapeSequences.encode(["jk", "ff"])) == ["jk", "ff"])
        #expect(EscapeSequences.clampTimeout(5) == 100)
        #expect(EscapeSequences.clampTimeout(5000) == 1000)
    }
}
