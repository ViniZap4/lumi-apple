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

@Suite("Vim — smartcase + \\C / \\c case flags")
struct VimSmartcaseTests {
    @Test("lowercase pattern matches uppercase text (smartcase = case-insensitive)")
    func lowercaseMatchesCapitalized() {
        // 'Foo' at offset 0, 'foo' at offset 4. /foo from cursor 0 with
        // smartcase is case-insensitive — but forward search skips matches at
        // the cursor itself, so the next match (offset 4) wins. Then n wraps
        // back to 0, confirming the case-insensitive match exists.
        let r = run("/foo⏎n", on: "Foo foo", cursor: 0)
        #expect(r.buffer.cursor == 0) // wrap finds 'Foo' (insensitive)
    }

    @Test("uppercase letter in pattern forces case-sensitive match")
    func uppercaseForcesSensitive() {
        // /Foo should NOT match 'foo'; first 'Foo' is at offset 0.
        let r = run("/Foo⏎", on: "Foo foo", cursor: 0)
        #expect(r.buffer.cursor == 0)
        // From after 'Foo', /Foo wraps back to 0 (the only 'Foo').
        let r2 = run("/Foo⏎", on: "foo Foo foo", cursor: 0)
        #expect(r2.buffer.cursor == 4) // 'Foo' starts at 4 in "foo Foo foo"
    }

    @Test("uppercase-only pattern doesn't match lowercase only")
    func uppercaseNoMatchLowercase() {
        // 'foo' only — /Bar should find nothing; cursor stays put.
        let r = run("/Bar⏎", on: "bar bar", cursor: 0)
        #expect(r.buffer.cursor == 0)
        #expect(r.state.lastSearch == nil)
    }

    @Test("\\C forces case-sensitive even with all-lowercase pattern")
    func backslashCForcesSensitive() {
        // 'Foo foo' — /foo\\C should skip 'Foo' and find 'foo' at offset 4.
        let r = run("/foo\\C⏎", on: "Foo foo", cursor: 0)
        #expect(r.buffer.cursor == 4)
    }

    @Test("\\c forces case-insensitive even with uppercase pattern")
    func backslashcForcesInsensitive() {
        // /Foo\\c → insensitive, so 'foo' matches. From cursor 0 forward search
        // skips the cursor, finds 'Foo' at offset 4. n then wraps back to 0
        // confirming the case-insensitive 'foo' match.
        let r = run("/Foo\\c⏎n", on: "foo Foo", cursor: 0)
        #expect(r.buffer.cursor == 0)
    }

    @Test("\\C wins over \\c when both present")
    func bothFlags_CWins() {
        let r = run("/foo\\c\\C⏎", on: "Foo foo", cursor: 0)
        #expect(r.buffer.cursor == 4) // case-sensitive: skips 'Foo'
    }

    @Test("backslash escapes other than \\C/\\c pass through")
    func backslashEscapesPassThrough() {
        // Match a literal period via \\. — 'a.b' has '.' at offset 1.
        let r = run("/\\.⏎", on: "a.b", cursor: 0)
        #expect(r.buffer.cursor == 1)
    }

    @Test("d/Bar<CR> with uppercase pattern is case-sensitive")
    func operatorPlusSensitive() {
        // 'foo Bar baz' — d/Bar deletes [0..4) → 'Bar baz'.
        let r = run("d/Bar⏎", on: "foo Bar baz", cursor: 0)
        #expect(r.buffer.text == "Bar baz")
    }

    @Test("n repeat honors smartcase from the original pattern")
    func repeatHonorsCase() {
        // /Foo finds 'Foo' at 4 in "foo Foo bar". n wraps and finds 'Foo' at 4
        // again (case-sensitive search).
        let r = run("/Foo⏎n", on: "foo Foo bar", cursor: 0)
        #expect(r.buffer.cursor == 4)
    }

    @Test("incsearch preview honors smartcase live")
    func incsearchSmartcase() {
        // Typing /F live with cursor 0 on "foo Foo" — uppercase F → sensitive,
        // first 'F' is at offset 4.
        let r = run("/F", on: "foo Foo", cursor: 0)
        #expect(r.buffer.cursor == 4)
    }
}
