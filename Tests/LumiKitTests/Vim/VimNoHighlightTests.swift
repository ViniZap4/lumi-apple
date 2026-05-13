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

@Suite("Vim — :noh (suspend hlsearch)")
struct VimNoHighlightTests {
    @Test(":noh sets hlsearchSuspended without clearing lastSearch")
    func nohSuspends() {
        let r = run("/bar⏎:noh⏎", on: "foo bar baz", cursor: 0)
        #expect(r.state.hlsearchSuspended == true)
        #expect(r.state.lastSearch?.pattern == "bar")
    }

    @Test("n after :noh re-enables hlsearch")
    func nReenables() {
        // /bar at 4. :noh suspends. n wraps to 4 again (only one 'bar').
        let r = run("/bar⏎:noh⏎n", on: "foo bar baz", cursor: 0)
        #expect(r.state.hlsearchSuspended == false)
        #expect(r.buffer.cursor == 4)
    }

    @Test("/<pattern>⏎ after :noh re-enables hlsearch")
    func newSearchReenables() {
        let r = run("/bar⏎:noh⏎/baz⏎", on: "foo bar baz", cursor: 0)
        #expect(r.state.hlsearchSuspended == false)
        #expect(r.state.lastSearch?.pattern == "baz")
    }

    @Test(":nohl alias also suspends")
    func nohlAlias() {
        let r = run("/bar⏎:nohl⏎", on: "foo bar", cursor: 0)
        #expect(r.state.hlsearchSuspended == true)
    }

    @Test(":nohlsearch alias also suspends")
    func nohlsearchAlias() {
        let r = run("/bar⏎:nohlsearch⏎", on: "foo bar", cursor: 0)
        #expect(r.state.hlsearchSuspended == true)
    }

    @Test(":noh on a buffer with no prior search is still a no-op effect-wise")
    func nohWithoutPriorSearch() {
        let r = run(":noh⏎", on: "foo bar", cursor: 0)
        #expect(r.state.hlsearchSuspended == true)
        #expect(r.state.lastSearch == nil)
        #expect(r.state.mode == .normal)
    }

    @Test("N after :noh also re-enables hlsearch")
    func capitalNReenables() {
        // /bar at 4 forward. :noh. N reverses → backward from 4. Only 'bar' is
        // at 4. Backward from 4 with strict-less-than-cursor (4) → wrap → 4.
        let r = run("/bar⏎:noh⏎N", on: "foo bar baz", cursor: 0)
        #expect(r.state.hlsearchSuspended == false)
    }
}
