import Testing
import Foundation
@testable import LumiKit

@Suite("Explorer — ShellKeymap")
struct ShellKeymapTests {
    private func feed(_ keys: [KeyStroke], context: ShellKeymap.Context = .explorer, start: TimeInterval = 0, step: TimeInterval = 0.05) -> [ShellAction?] {
        var map = ShellKeymap()
        var t = start
        return keys.map { k in
            defer { t += step }
            return map.feed(k, context: context, now: t)
        }
    }

    private func chars(_ s: String) -> [KeyStroke] { s.map { .char(String($0)) } }

    @Test("hjkl and arrows")
    func basics() {
        #expect(feed(chars("jkhl")) == [.move(1), .move(-1), .parent, .open])
        #expect(feed([.key(.down), .key(.up), .key(.left), .key(.right), .key(.enter)]) ==
            [.move(1), .move(-1), .parent, .open, .open])
        #expect(feed(chars("-")) == [.parent])
    }

    @Test("gg top, G bottom, gh / zh / ~ home, zp preview")
    func chords() {
        #expect(feed(chars("gg")) == [.pending, .top])
        #expect(feed(chars("G")) == [.bottom])
        #expect(feed(chars("gh")) == [.pending, .home])
        #expect(feed(chars("zh")) == [.pending, .home])
        #expect(feed(chars("zp")) == [.pending, .togglePreview])
        #expect(feed(chars("~")) == [.home])
    }

    @Test("g1–g9 and ⌃1–⌃9 switch books; [ ] cycle")
    func books() {
        #expect(feed(chars("g3")) == [.pending, .book(3)])
        #expect(feed([.char("5", control: true)]) == [.book(5)])
        #expect(feed(chars("[]")) == [.prevBook, .nextBook])
    }

    @Test("an expired g prefix does not chord")
    func chordTimeout() {
        let r = feed(chars("gg"), step: 2)
        #expect(r == [.pending, .pending])
    }

    @Test("unknown second key falls through: g then j moves")
    func unknownSecondKey() {
        #expect(feed(chars("gj")) == [.pending, .move(1)])
    }

    @Test("count prefix multiplies movement")
    func counts() {
        #expect(feed(chars("5j")) == [.pending, .move(5)])
        #expect(feed(chars("12k")) == [.pending, .pending, .move(-12)])
        #expect(feed(chars("0")) == [nil])
    }

    @Test("ctrl scrolling")
    func ctrl() {
        #expect(feed([.char("d", control: true), .char("u", control: true), .char("f", control: true), .char("b", control: true)]) ==
            [.halfPage(1), .halfPage(-1), .page(1), .page(-1)])
    }

    @Test("yazi file keys in the explorer")
    func fileKeys() {
        #expect(feed(chars("/nNardyp.")) ==
            [.filter, .nextMatch, .prevMatch, .create, .rename, .delete, .yank, .paste, .toggleHidden])
    }

    @Test("reader context: q closes, d/u half-page, file keys unbound")
    func reader() {
        #expect(feed(chars("qdua"), context: .reader) == [.close, .halfPage(1), .halfPage(-1), nil])
    }

    @Test("shell keys: palette, command, help, edit, refresh")
    func shell() {
        #expect(feed(chars(" :?ieR")) == [.palette, .command, .help, .edit, .edit, .refresh])
    }

    @Test("command-modified keys are left to the menu bar")
    func command() {
        #expect(feed([KeyStroke("k", command: true)]) == [nil])
    }
}

@Suite("FuzzyMatch")
struct FuzzyMatchTests {
    @Test("subsequence required")
    func subsequence() {
        #expect(FuzzyMatch.score("tdo", "todo") != nil)
        #expect(FuzzyMatch.score("xyz", "todo") == nil)
        #expect(FuzzyMatch.score("", "anything") == 0)
    }

    @Test("case and diacritics are ignored")
    func folding() {
        #expect(FuzzyMatch.score("cafe", "Café Notes") != nil)
    }

    @Test("word starts and runs rank higher")
    func ranking() {
        let ranked = FuzzyMatch.rank(["notes/old/todo-archive.md", "todo.md", "photo-dog.md"], query: "todo") { $0 }
        #expect(ranked.first == "todo.md")
        #expect(!ranked.contains("photo-dog.md") || ranked.firstIndex(of: "photo-dog.md")! > 0)
    }

    @Test("book settings command found by `book`")
    func commands() {
        let ranked = FuzzyMatch.rank(["Sign out", "Book settings", "New book…"], query: "book set") { $0 }
        #expect(ranked.first == "Book settings")
    }
}

@Suite("Explorer — pane keys and preview reader")
struct ShellPaneKeymapTests {
    private func feed(_ keys: [KeyStroke], context: ShellKeymap.Context = .explorer, panes: Bool = true) -> [ShellAction?] {
        var map = ShellKeymap()
        map.ctrlHJKLPanes = panes
        var t: TimeInterval = 0
        return keys.map { k in
            defer { t += 0.05 }
            return map.feed(k, context: context, now: t)
        }
    }

    private func ctrl(_ c: String) -> KeyStroke { .char(c, control: true) }
    private func chars(_ s: String) -> [KeyStroke] { s.map { .char(String($0)) } }

    @Test("⌃h ⌃j ⌃k ⌃l are pane keys in every shell context")
    func ctrlHJKL() {
        for ctx: ShellKeymap.Context in [.explorer, .reader, .preview, .sidebar] {
            #expect(feed(["h", "j", "k", "l"].map(ctrl), context: ctx) ==
                [.paneKey(.left), .paneKey(.down), .paneKey(.up), .paneKey(.right)])
        }
        // ⌃n / ⌃p still move.
        #expect(feed([ctrl("n"), ctrl("p")]) == [.move(1), .move(-1)])
    }

    @Test("setting off: ⌃hjkl unbound, ⌃w chords still work")
    func settingOff() {
        #expect(feed([ctrl("h"), ctrl("j")], panes: false) == [nil, nil])
        #expect(feed([ctrl("w"), .char("l")], panes: false) == [.pending, .pane(.move(.right))])
    }

    @Test("⌃w chords: h j k l, ⌃h, arrows, w W p, unknown swallowed")
    func ctrlW() {
        #expect(feed([ctrl("w"), .char("h")]) == [.pending, .pane(.move(.left))])
        #expect(feed([ctrl("w"), ctrl("j")]) == [.pending, .pane(.move(.down))])
        #expect(feed([ctrl("w"), .key(.up)]) == [.pending, .pane(.move(.up))])
        #expect(feed([ctrl("w"), .char("w")]) == [.pending, .pane(.next)])
        #expect(feed([ctrl("w"), ctrl("w")]) == [.pending, .pane(.next)])
        #expect(feed([ctrl("w"), .char("W")]) == [.pending, .pane(.previous)])
        #expect(feed([ctrl("w"), .char("p")]) == [.pending, .pane(.last)])
        #expect(feed([ctrl("w"), .char("x"), .char("j")]) == [.pending, .pending, .move(1)])
    }

    @Test("^W shows as pending")
    func pendingDisplay() {
        var map = ShellKeymap()
        _ = map.feed(ctrl("w"), context: .explorer, now: 0)
        #expect(map.pendingDisplay == "^W")
    }

    @Test("preview reader keymap")
    func preview() {
        #expect(feed(chars("jkdubGyf/nN{}"), context: .preview) ==
            [.move(1), .move(-1), .halfPage(1), .halfPage(-1), .page(-1), .bottom, .yank, .hints, .find, .nextMatch, .prevMatch, .prevHeading, .nextHeading])
        #expect(feed(chars("gg"), context: .preview) == [.pending, .top])
        #expect(feed(chars("[[]]"), context: .preview) == [.pending, .prevHeading, .pending, .nextHeading])
        #expect(feed(chars("5j"), context: .preview) == [.pending, .move(5)])
        #expect(feed(chars(" "), context: .preview) == [.page(1)])
        #expect(feed([ctrl("d"), ctrl("u")], context: .preview) == [.halfPage(1), .halfPage(-1)])
        #expect(feed(chars("qhie"), context: .preview) == [.close, .parent, .edit, .edit])
        #expect(feed([.key(.escape), .key(.enter)], context: .preview) == [.clearOrBack, .open])
        #expect(feed(chars("?:"), context: .preview) == [.help, .command])
        // The reader keeps [ ] for books and f for page.
        #expect(feed(chars("[f/"), context: .reader) == [.prevBook, .page(1), .find])
    }

    @Test("sidebar: moves and opens, no file ops")
    func sidebar() {
        #expect(feed(chars("jkl"), context: .sidebar) == [.move(1), .move(-1), .open])
        #expect(feed(chars("adr"), context: .sidebar) == [nil, nil, nil])
    }
}
