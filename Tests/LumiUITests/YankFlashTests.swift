import Testing
import Foundation
import LumiKit
@testable import LumiUI

@MainActor
private func type(_ c: VimController, _ s: String) {
    for ch in s { ch == "⎋" ? c.send(.escape) : c.send(.character(ch)) }
}

@Suite("Yank highlight + split-preview editor hooks")
@MainActor
struct YankFlashTests {
    private func make(_ text: String) -> (VimController, FakeSurface) {
        let c = VimController(initialText: text)
        let s = FakeSurface(text)
        c.surface = s
        return (c, s)
    }

    @Test("every yank form flashes its range; nothing else does, and the text is untouched")
    func forms() {
        let (c, s) = make("héllo world\nsecond line\nthird")
        type(c, "yw")
        #expect(s.flashes.last == [NSRange(location: 0, length: 6)])
        type(c, "yy")
        #expect(s.flashes.last == [NSRange(location: 0, length: 11)])
        type(c, "2yy")
        #expect(s.flashes.last == [NSRange(location: 0, length: 23)])
        type(c, "\"ayiw")
        #expect(s.flashes.last == [NSRange(location: 0, length: 5)])
        type(c, "vey")
        #expect(s.flashes.last == [NSRange(location: 0, length: 5)])
        type(c, "Vjy")
        #expect(s.flashes.last == [NSRange(location: 0, length: 23)])
        c.send(.control("v")); type(c, "jly")
        #expect(s.flashes.last == [NSRange(location: 0, length: 2), NSRange(location: 12, length: 2)])
        let count = s.flashes.count
        type(c, "jdd")
        #expect(s.flashes.count == count, "a delete must not flash")
        #expect(s.edits.allSatisfy { !$0.replacement.isEmpty || $0.length > 0 })
    }

    @Test("visual mode paints its range as a rendering highlight")
    func visualRanges() {
        let (c, _) = make("abc def\nghi")
        #expect(c.visualHighlightRanges.isEmpty)
        type(c, "vl")
        #expect(c.visualHighlightRanges == [NSRange(location: 0, length: 2)])
        type(c, "⎋V")
        #expect(c.visualHighlightRanges == [NSRange(location: 0, length: 8)])
    }

    @Test("default leader map: \\p runs :preview split")
    func leader() {
        let (c, _) = make("x")
        c.applyVimrc(nil)
        var effects: [VimEffect] = []
        c.onEffect = { effects.append($0) }
        type(c, "\\p")
        #expect(effects == [.host("preview split")])
        type(c, ":settings")
        c.send(.return)
        #expect(effects.last == .host("settings"))
    }

    @Test("programmatic task toggle is one ranged op on the CRDT, cursor kept")
    func programmatic() throws {
        let doc = FakeDocument("- [ ] one\n- [ ] two")
        let c = VimController(document: doc)
        c.bindDocument()
        let s = FakeSurface(doc.text)
        c.surface = s
        type(c, "jw")
        let before = c.buffer.cursor
        let sync = SplitScrollSync()
        sync.attach(editor: c)
        #expect(sync.toggleTask(1))
        #expect(doc.localOps.last == [TextEdit(location: 13, length: 1, replacement: "x")])
        #expect(doc.text == "- [ ] one\n- [x] two")
        #expect(s.storage as String == doc.text)
        #expect(c.buffer.cursor == before)
    }
}
