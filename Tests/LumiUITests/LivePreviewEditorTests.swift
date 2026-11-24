#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

@MainActor
private func type(_ c: VimController, _ s: String) {
    for ch in s { ch == "⎋" ? c.send(.escape) : c.send(.character(ch)) }
}

@Suite("Live Preview in the editor", .serialized)
@MainActor
struct LivePreviewEditorTests {
    static let sample = """
    # Field notes

    Lumi keeps **notes as plain markdown** — _portable_, ~~locked~~ open. Type `:live` or press ==⌘E==, read the [protocol](https://example.com/protocol) or a [[vault note]].

    ## Tasks

    - [ ] write the parity report
    - [x] ship the prose stylesheet
    - Bullets hang in the margin
      - nested bullets use a ring

    > Quotes stay quiet: a thin bar and dimmed text.

    > [!tip] Keyboard first
    > Every mouse action has a key.

    ```swift
    func toggle(_ index: Int) -> TextEdit? {
        return TextEdit(location: index, length: 1, replacement: "x")
    }
    ```

    | Client | Sync | Live cursors |
    |:-------|:----:|-------------:|
    | Web | Yjs | yes |
    | Apple | yswift | yes |

    ---

    That's all.
    """

    static func editor(_ text: String, theme: LumiTheme, size: NSSize, live: Bool = true) -> (VimAppKitTextView, VimController, NSScrollView) {
        let (view, c, scroll) = ParityRenderTests.editor(text, theme: theme, size: size)
        if live { view.applyPresentation(.live(LivePreviewOptions(readingWidth: 680)), theme: theme.tokens) }
        settle(view)
        return (view, c, scroll)
    }

    static func settle(_ view: VimAppKitTextView) {
        if let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        view.sizeToFit()
        view.liveOverlays?.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        if let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        view.liveOverlays?.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.updateCursor()
    }

    // MARK: Behaviour

    @Test("live preview never changes the characters; source ⇄ live round-trips")
    func textUntouched() {
        let (view, c, _) = Self.editor(Self.sample, theme: .tokyoNight, size: NSSize(width: 800, height: 600))
        #expect(view.string == Self.sample)
        #expect(c.buffer.text == Self.sample)
        view.applyPresentation(.source, theme: LumiTheme.tokyoNight.tokens)
        #expect(view.string == Self.sample)
        #expect(view.live == nil)
        view.applyPresentation(.live(LivePreviewOptions()), theme: LumiTheme.tokyoNight.tokens)
        #expect(view.live != nil)
        #expect(view.string == Self.sample)
    }

    @Test("syntax hides off the cursor line and comes back on it")
    func reveal() throws {
        let (view, c, _) = Self.editor("# Title\n\nsome **bold** text", theme: .tokyoNight, size: NSSize(width: 700, height: 300))
        let storage = try #require(view.textStorage)
        // Cursor on line 0: the heading marker shows.
        let markerFont = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(markerFont.pointSize > 1)
        // `**` on line 2 is hidden.
        let starAt = ("# Title\n\nsome " as NSString).length
        let hidden = try #require(storage.attribute(.font, at: starAt, effectiveRange: nil) as? NSFont)
        #expect(hidden.pointSize < 1)
        // Move to line 2: `**` shows, `# ` hides.
        type(c, "jj")
        view.refreshLive()
        let shown = try #require(storage.attribute(.font, at: starAt, effectiveRange: nil) as? NSFont)
        #expect(shown.pointSize > 1)
        let markerNow = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(markerNow.pointSize < 1)
        #expect(view.string == "# Title\n\nsome **bold** text")
    }

    @Test("a cursor move restyles only the lines it enters and leaves")
    func incremental() throws {
        var text = ""
        for i in 0..<400 { text += "line \(i) with **bold**\n" }
        let (view, c, _) = Self.editor(text, theme: .tokyoNight, size: NSSize(width: 700, height: 400))
        let live = try #require(view.live)
        type(c, "j")
        #expect(Set(live.lastRestyled) == [0, 1])
        type(c, "x")   // delete a char on line 1
        #expect(live.lastRestyled.count <= 3)
        type(c, "o")
        type(c, "new line⎋")
        #expect(live.lastRestyled.count <= 4, "an inserted line must not restyle the lines below: \(live.lastRestyled.count)")
    }

    @Test("vim edits, yank and visual still work in Live; visual range reveals its lines")
    func vimInLive() throws {
        let (view, c, _) = Self.editor("alpha **one**\nbeta **two**\ngamma", theme: .tokyoNight, size: NSSize(width: 700, height: 300))
        let storage = try #require(view.textStorage)
        type(c, "Vj")
        view.refreshLive()
        let at = ("alpha **one**\nbeta " as NSString).length
        #expect((storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont).map { $0.pointSize > 1 } == true)
        type(c, "y⎋")
        type(c, "dd")
        #expect(c.buffer.text == "beta **two**\ngamma")
        #expect(view.string == c.buffer.text)
        type(c, "u")
        #expect(view.string == "alpha **one**\nbeta **two**\ngamma")
    }

    @Test("task box toggle is one ranged CRDT op and keeps the cursor")
    func taskToggle() throws {
        let doc = FakeDocument("intro\n- [ ] one\n- [ ] two")
        let c = VimController(document: doc)
        c.bindDocument()
        let (view, _, _) = ParityRenderTests.editor("", theme: .tokyoNight, size: NSSize(width: 700, height: 300))
        view.attach(c)
        view.applyPresentation(.live(LivePreviewOptions()), theme: LumiTheme.tokyoNight.tokens)
        Self.settle(view)
        let before = c.buffer.cursor
        let edit = try #require(LivePreview.taskToggle(view.string as NSString, at: ("intro\n- [ ] one\n- " as NSString).length))
        c.applyProgrammaticEdit(edit)
        #expect(doc.localOps.last == [TextEdit(location: 19, length: 1, replacement: "x")])
        #expect(doc.text == "intro\n- [ ] one\n- [x] two")
        #expect(view.string == doc.text)
        #expect(c.buffer.cursor == before)
    }

    @Test("rendered widgets mount for the table and the code block")
    func widgets() throws {
        let (view, _, _) = Self.editor(Self.sample, theme: .tokyoNight, size: NSSize(width: 900, height: 2400))
        let overlays = try #require(view.liveOverlays)
        #expect(overlays.mountedCount == 2)
    }

    // MARK: Renders (LUMI_RENDER_DIR)

    @Test("renders: cursor off / on a line, dark + light")
    func renders() throws {
        guard ParityRenderTests.dir != nil else { return }
        for (theme, name) in [(LumiTheme.tokyoNight, "dark"), (LumiTheme.catppuccinLatte, "light")] {
            let size = NSSize(width: 900, height: 1250)
            // Cursor on the last line: everything above renders.
            let (view, c, scroll) = Self.editor(Self.sample, theme: theme, size: size)
            type(c, "G")
            view.refreshLive()
            Self.settle(view)
            try ParityRenderTests.png(scroll, "live-\(name)-cursor-off", background: MarkdownPalette.concrete(theme.tokens.background))

            // Cursor on the paragraph, the task and inside the table.
            let (view2, c2, scroll2) = Self.editor(Self.sample, theme: theme, size: size)
            type(c2, "jj")
            view2.refreshLive()
            Self.settle(view2)
            try ParityRenderTests.png(scroll2, "live-\(name)-cursor-paragraph", background: MarkdownPalette.concrete(theme.tokens.background))
            let (view3, c3, scroll3) = Self.editor(Self.sample, theme: theme, size: size)
            type(c3, "/Apple")
            c3.send(.return)
            view3.refreshLive()
            Self.settle(view3)
            try ParityRenderTests.png(scroll3, "live-\(name)-cursor-table", background: MarkdownPalette.concrete(theme.tokens.background))
        }
    }
}
#endif
