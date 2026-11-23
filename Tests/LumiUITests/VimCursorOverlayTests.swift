import Testing
import Foundation
import LumiKit
@testable import LumiUI

#if canImport(AppKit)
import AppKit

/// The cursor overlay on a real TextKit 2 `NSTextView`, laid out
/// offscreen (no window, no focus, nothing on screen).
@Suite("Vim cursor overlay — AppKit, offscreen")
@MainActor
struct VimCursorOverlayTests {
    private func make(_ text: String, cursor: Int = 0) -> (VimAppKitTextView, VimController, NSScrollView) {
        let c = VimController(initialText: text)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        let view = VimAppKitTextView(usingTextLayoutManager: true)
        view.styler = EditorStyler(theme: .tokyoNight, fontSize: 13)
        view.minSize = .zero
        view.maxSize = NSSize(width: 1e6, height: 1e6)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 160)
        view.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = view
        view.focusOverride = true
        view.attach(c)
        for _ in 0..<cursor { c.send(.character("l")) }
        view.updateCursor()
        return (view, c, scroll)
    }

    @Test("normal mode: block over the character, glyph drawn inverted")
    func block() {
        let (view, _, _) = make("hello", cursor: 1)
        #expect(view.cursorStyle.shape == .block)
        #expect(!view.cursorView.isHidden)
        #expect(view.cursorView.frame.width > 4)
        #expect(view.cursorView.frame.height > 8)
        #expect(view.cursorView.glyph?.string == "e")
        // Native caret hidden while the overlay draws.
        #expect(view.insertionPointColor == .clear)
    }

    @Test("insert → bar (blinks), replace → underline, operator-pending → half block")
    func shapes() {
        let (view, c, _) = make("hello")
        c.send(.character("i"))
        #expect(view.cursorStyle == VimCursorStyle(shape: .bar, blinks: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        c.send(.escape)
        c.send(.character("R"))
        #expect(view.cursorStyle.shape == .underline)
        c.send(.escape)
        c.send(.character("d"))
        #expect(view.cursorStyle.shape == .halfBlock)
        c.send(.escape)
        c.send(.character(":"))
        #expect(view.cursorStyle.shape == .hidden)
        #expect(view.cursorView.isHidden)
    }

    @Test("empty line and end of text get a one-cell block")
    func emptyCells() {
        let (view, c, _) = make("ab\n\ncd")
        c.send(.character("j"))
        #expect(c.cursorCharacterRange.length == 0)
        let cell = view.cursorView.frame
        #expect(cell.width > 4)
        let (v2, c2, _) = make("ab\n")
        c2.send(.character("G"))
        #expect(c2.buffer.cursor == 3)
        #expect(v2.cursorView.frame.minY > 0)
        #expect(!v2.cursorView.isHidden)
    }

    @Test("wide glyphs (emoji, CJK) get a wider cell")
    func wide() {
        let (view, _, _) = make("a😀b")
        let narrow = view.cursorView.frame.width
        let (v2, _, _) = make("a😀b", cursor: 1)
        #expect(v2.cursorView.glyph?.string == "😀")
        #expect(v2.cursorView.frame.width > narrow)
    }

    @Test("unfocused → hollow block")
    func unfocused() {
        let (view, c, _) = make("hello")
        view.focusOverride = false
        view.updateCursor()
        #expect(view.cursorStyle.shape == .hollowBlock)
        withExtendedLifetime(c) {}
    }

    @Test("IME marked text → system caret, overlay hidden")
    func ime() {
        let (view, c, _) = make("xy")
        c.send(.character("a"))
        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.updateCursor()
        #expect(view.cursorStyle.usesSystemCaret)
        #expect(view.cursorView.isHidden)
    }

    @Test("visual block highlights one range per line")
    func blockRanges() {
        let (_, c, _) = make("abc\ndef")
        for k: VimInput in [.control("v"), .character("j"), .character("l")] { c.send(k) }
        #expect(c.blockSelectionRanges == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
    }

    @Test("shape geometry inside the cell")
    func geometry() {
        let r = CGRect(x: 10, y: 20, width: 8, height: 16)
        #expect(VimCursorView.shapeRect(.block, in: r, thickness: 2) == r)
        #expect(VimCursorView.shapeRect(.halfBlock, in: r, thickness: 2) == CGRect(x: 10, y: 28, width: 8, height: 8))
        #expect(VimCursorView.shapeRect(.underline, in: r, thickness: 2) == CGRect(x: 10, y: 34, width: 8, height: 2))
        #expect(VimCursorView.shapeRect(.bar, in: r, thickness: 2) == CGRect(x: 10, y: 20, width: 2, height: 16))
    }

    /// Offscreen PNGs for eyeballing (only when LUMI_RENDER_DIR is set).
    @Test("offscreen render of each cursor shape")
    func render() throws {
        guard let dir = ProcessInfo.processInfo.environment["LUMI_RENDER_DIR"] else { return }
        let cases: [(String, [VimInput])] = [
            ("normal", []), ("insert", [.character("i")]), ("replace", [.character("R")]),
            ("oppending", [.character("d")]), ("visual", [.character("v"), .character("e")]),
            ("block", [.control("v"), .character("j"), .character("l")]),
        ]
        for (name, keys) in cases {
            let (view, c, scroll) = make("fn main() {\n  let 😀 = \"vim\";\n\n}", cursor: 3)
            for k in keys { c.send(k) }
            view.updateCursor()
            view.cursorView.alphaValue = 1
            let rep = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("cursor-\(name).png"))
        }
    }
}

@Suite("VimController — ranged edits reach the CRDT")
@MainActor
struct VimControllerRangedEditTests {
    @Test(":%s over many lines is one applyLocal with one edit per match")
    func substitute() {
        let text = (0..<20).map { "row \($0) foo" }.joined(separator: "\n")
        let doc = FakeDocument(text)
        let c = VimController(document: doc)
        c.bindDocument()
        let surface = FakeSurface(text)
        c.surface = surface
        for ch in ":%s/foo/barbaz/" { c.send(.character(ch)) }
        c.send(.return)
        #expect(doc.localOps.count == 1)
        #expect(doc.localOps.first?.count == 20)
        #expect(doc.localOps.first?.allSatisfy { $0.length == 3 && $0.replacement == "barbaz" } == true)
        #expect(doc.text == c.buffer.text)
        #expect(surface.storage as String == c.buffer.text)
    }

    @Test("an insert session goes out as one growing ranged op per key, never a replace-all")
    func insertOps() {
        let doc = FakeDocument("hello world")
        let c = VimController(document: doc)
        c.bindDocument()
        c.surface = FakeSurface(doc.text)
        for ch in "wciwthere" { c.send(.character(ch)) }
        c.send(.escape)
        #expect(doc.localOps.allSatisfy { $0.count == 1 && $0[0].length <= 5 })
        #expect(doc.text == "hello there")
    }

    @Test("status exposes mode, pending keys and leader maps for the legend")
    func status() {
        let c = VimController(initialText: "abc")
        c.applyVimrc(Vimrc.parse("let mapleader=\",\"\nnnoremap <leader>w :w<CR>"))
        c.send(.character("d"))
        #expect(c.status.legendContext == .operatorPending)
        #expect(c.status.pending.display == "d")
        #expect(c.status.leaderMaps.first?.keys == "w")
        c.send(.escape)
        c.send(.control("v"))
        #expect(c.status.legendContext == .visualBlock)
    }

    @Test("Ctrl chords map to engine inputs")
    func ctrl() {
        #expect(VimKeyMapper.controlInput(for: "w") == .control("w"))
        #expect(VimKeyMapper.controlInput(for: "V") == .control("v"))
        #expect(VimKeyMapper.controlInput(for: "c") == .escape)
        #expect(VimKeyMapper.controlInput(for: "[") == .escape)
        #expect(VimKeyMapper.input(forCommand: "deleteForward:") == .delete)
    }
}
#endif
