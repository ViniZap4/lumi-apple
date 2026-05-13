import Testing
import Foundation
@testable import LumiKit

/// Same shape as the other Vim helpers but recognizes `↑` and `↓` as
/// `.historyPrev` and `.historyNext` — VimInput cases that don't have an
/// obvious printable character.
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
        case "↑": input = .historyPrev
        case "↓": input = .historyNext
        default: input = .character(char)
        }
        let result = VimEngine.handle(input, state: state, buffer: buffer)
        state = result.state
        buffer = result.buffer
    }
    return VimEngine.Result(state: state, buffer: buffer)
}

@Suite("Vim — command-line history (↑/↓ recall)")
struct VimCommandLineHistoryTests {
    @Test("after /foo<CR>, foo is in searchHistory")
    func searchHistoryRecords() {
        let r = run("/foo⏎", on: "foo bar")
        #expect(r.state.searchHistory == ["foo"])
        #expect(r.state.exHistory.isEmpty)
    }

    @Test("after :w<CR>, w is in exHistory")
    func exHistoryRecords() {
        let r = run(":w⏎", on: "hello")
        #expect(r.state.exHistory == ["w"])
        #expect(r.state.searchHistory.isEmpty)
    }

    @Test("↑ in a fresh search command-line recalls the most recent pattern")
    func upRecallsMostRecent() {
        // After /foo⏎ /↑ — the second command-line's buffer should be "foo".
        let r = run("/foo⏎/↑", on: "foo bar foo")
        if case let .commandLine(prefix, buffer) = r.state.mode {
            #expect(prefix == "/")
            #expect(buffer == "foo")
        } else {
            Issue.record("expected commandLine mode, got \(r.state.mode)")
        }
    }

    @Test("repeated ↑ steps to older entries")
    func upStepsOlder() {
        // Record foo then bar. /↑↑ should walk to "foo".
        let r = run("/foo⏎/bar⏎/↑↑", on: "foo bar")
        if case let .commandLine(_, buffer) = r.state.mode {
            #expect(buffer == "foo")
        } else {
            Issue.record("expected commandLine mode")
        }
    }

    @Test("↓ past the newest entry restores the draft")
    func downRestoresDraft() {
        // Type /xy then ↑ (recalls "foo") then ↓ (back past newest = draft).
        let r = run("/foo⏎/xy↑↓", on: "")
        if case let .commandLine(_, buffer) = r.state.mode {
            #expect(buffer == "xy")
        } else {
            Issue.record("expected commandLine mode")
        }
    }

    @Test("typing after ↑ ends the walk")
    func typingResetsWalk() {
        let r = run("/foo⏎/↑X", on: "")
        if case let .commandLine(_, buffer) = r.state.mode {
            #expect(buffer == "fooX")
        } else {
            Issue.record("expected commandLine mode")
        }
        #expect(r.state.commandLineHistoryIndex == nil)
    }

    @Test("ex and search histories are independent")
    func separateHistories() {
        // Record foo to search and w to ex. Then in ex mode, ↑ should give "w",
        // not "foo".
        let r = run("/foo⏎:w⏎:↑", on: "")
        if case let .commandLine(prefix, buffer) = r.state.mode {
            #expect(prefix == ":")
            #expect(buffer == "w")
        } else {
            Issue.record("expected commandLine mode")
        }
    }

    @Test("empty <CR> doesn't pollute history")
    func emptyDoesntRecord() {
        let r = run("/⏎", on: "")
        #expect(r.state.searchHistory.isEmpty)
    }

    @Test("duplicate of most recent is not re-appended")
    func dedupesLast() {
        let r = run("/foo⏎/foo⏎", on: "foo")
        #expect(r.state.searchHistory == ["foo"])
    }

    @Test("history is bounded at the limit (oldest dropped)")
    func boundedAtLimit() {
        let limit = VimState.commandLineHistoryLimit
        var keys = ""
        for i in 0..<(limit + 5) {
            keys += "/p\(i)⏎"
        }
        let r = run(keys, on: "")
        #expect(r.state.searchHistory.count == limit)
        // Oldest 5 entries dropped — first remaining should be "p5".
        #expect(r.state.searchHistory.first == "p5")
        #expect(r.state.searchHistory.last == "p\(limit + 4)")
    }

    @Test("ESC during walk discards the recalled entry without committing")
    func escDuringWalkDoesNotCommit() {
        // /foo⏎ /↑⎋ — recall foo, then ESC. Should not have appended a new
        // entry (still ["foo"]). And history walk state is cleared.
        let r = run("/foo⏎/↑⎋", on: "")
        #expect(r.state.searchHistory == ["foo"])
        #expect(r.state.commandLineHistoryIndex == nil)
        #expect(r.state.commandLineHistoryDraft == nil)
    }

    @Test("↓ with no walk in progress is a no-op")
    func downWithoutWalkIsNoOp() {
        let r = run("/foo⏎/↓", on: "")
        if case let .commandLine(_, buffer) = r.state.mode {
            #expect(buffer == "")
        } else {
            Issue.record("expected commandLine mode")
        }
    }

    @Test("recalled pattern is also recorded after <CR>")
    func recalledPatternRecords() {
        // /foo⏎ /↑⏎ — second commit is "foo" again. Dedupe should keep it as
        // a single entry.
        let r = run("/foo⏎/↑⏎", on: "foo bar")
        #expect(r.state.searchHistory == ["foo"])
    }
}
