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

@Suite("Vim — text objects (operator)")
struct VimTextObjectOperatorTests {
    @Test("daw deletes a word with trailing whitespace")
    func dawTrailing() {
        let r = run("daw", on: "foo bar baz", cursor: 0)
        #expect(r.buffer.text == "bar baz")
    }

    @Test("ciw deletes inner word and enters insert")
    func ciwInner() {
        let r = run("ciw", on: "foo bar", cursor: 1)
        #expect(r.buffer.text == " bar")
        #expect(r.state.mode == .insert)
    }

    @Test("diw with cursor inside word deletes word only")
    func diwInner() {
        let r = run("diw", on: "alpha beta", cursor: 2)
        #expect(r.buffer.text == " beta")
    }

    @Test("daw with cursor inside word includes trailing whitespace")
    func dawInnerCursor() {
        let r = run("daw", on: "alpha beta gamma", cursor: 2)
        #expect(r.buffer.text == "beta gamma")
    }
}

@Suite("Vim — text objects (quotes)")
struct VimTextObjectQuoteTests {
    @Test("di\" deletes inside double quotes")
    func diQuote() {
        let r = run("di\"", on: "say \"hello\" world", cursor: 7)
        #expect(r.buffer.text == "say \"\" world")
    }

    @Test("da\" deletes including the double quotes")
    func daQuote() {
        let r = run("da\"", on: "say \"hello\" world", cursor: 7)
        #expect(r.buffer.text == "say  world")
    }

    @Test("ci' enters insert with single-quoted contents removed")
    func ciSingleQuote() {
        let r = run("ci'", on: "x = 'hi'", cursor: 5)
        #expect(r.buffer.text == "x = ''")
        #expect(r.state.mode == .insert)
    }

    @Test("yi` yanks contents of backtick block")
    func yiBacktick() {
        let r = run("yi`", on: "code: `let x = 1`", cursor: 8)
        #expect(r.state.defaultRegister.text == "let x = 1")
    }
}

@Suite("Vim — text objects (brackets)")
struct VimTextObjectBracketTests {
    @Test("di( deletes inside parentheses")
    func diParen() {
        let r = run("di(", on: "f(arg) tail", cursor: 3)
        #expect(r.buffer.text == "f() tail")
    }

    @Test("da( deletes including parentheses")
    func daParen() {
        let r = run("da(", on: "f(arg) tail", cursor: 3)
        #expect(r.buffer.text == "f tail")
    }

    @Test("di{ handles nested braces correctly")
    func diBraceNested() {
        let r = run("di{", on: "{ outer { inner } end }", cursor: 11)
        #expect(r.buffer.text == "{ outer {} end }")
    }

    @Test("ci[ enters insert with bracket contents removed")
    func ciBracket() {
        let r = run("ci[", on: "arr[idx]", cursor: 4)
        #expect(r.buffer.text == "arr[]")
        #expect(r.state.mode == .insert)
    }
}

@Suite("Vim — text objects (visual)")
struct VimTextObjectVisualTests {
    @Test("vi\" selects inside quotes")
    func viQuote() {
        let r = run("vi\"", on: "say \"hello\" world", cursor: 7)
        guard case let .visual(_, anchor) = r.state.mode else {
            Issue.record("expected visual mode"); return
        }
        // Anchor at start of inner range, cursor at last inner char.
        #expect(anchor == 5)
        #expect(r.buffer.cursor == 9)
    }

    @Test("vaw selects word with trailing whitespace")
    func vawWord() {
        let r = run("vaw", on: "foo bar", cursor: 0)
        guard case let .visual(_, anchor) = r.state.mode else {
            Issue.record("expected visual mode"); return
        }
        #expect(anchor == 0)
        #expect(r.buffer.cursor == 3)
    }
}
