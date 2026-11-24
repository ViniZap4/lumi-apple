#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

/// A note that exercises every coloured prose element (heading ramp,
/// links, emphasis, marks, code, quotes, callouts, lists, tags, tables,
/// rules, footnotes).
enum ProseSample {
    static let note = """
    # Prose in colour

    Lumi keeps **notes as plain markdown** — _portable_, ~~locked~~ open, with ==a warm highlight== and `inline code`. See the [protocol](https://example.com) or [[another note]].[^1] Tagged #design #prose.

    ## Second level

    1. Open a book from the sidebar.
    2. Pick a note with `j` / `k`.

    - Bullets hang in the margin
      - nested bullets use a ring
    - [ ] write the parity report
    - [x] ship the prose stylesheet

    ### Third level

    > A quote keeps a coloured bar and a faint tint, so it reads as an aside.

    > [!note] Note
    > The default callout.

    > [!tip] Tip
    > Every mouse action has a key.

    > [!warning] Warning
    > Unsynced changes stay on this device.

    > [!danger] Danger
    > Deleting a book removes it everywhere.

    #### Fourth level

    ```swift
    // Ranged ops only
    func toggle(_ index: Int) -> TextEdit? {
        let marker = markers[index] + 1
        return TextEdit(location: marker, length: 1, replacement: "x")
    }
    ```

    | Client | Sync | Cursors |
    |:-------|:----:|--------:|
    | Web | Yjs | yes |
    | Apple | yswift | yes |
    | TUI | snapshot | no |

    ---

    ##### Fifth level

    ###### Sixth level

    [^1]: Footnotes collect at the end, with a way back.
    """
}

@Suite("Prose colour renders (LUMI_RENDER_DIR)", .serialized)
@MainActor
struct ProseColorRenderTests {
    static let themes: [LumiTheme] = [.tokyoNight, .catppuccinLatte, .dracula]

    static var tag: String { ProcessInfo.processInfo.environment["LUMI_RENDER_TAG"] ?? "after" }

    @Test("reader + live preview, three themes")
    func renders() throws {
        guard ParityRenderTests.dir != nil else { return }
        for theme in Self.themes {
            let c = ParityRenderTests.readerView(ProseSample.note, theme: theme, size: NSSize(width: 900, height: 2800), title: "", tags: [])
            let page = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: min(3000, max(600, c.textView.frame.height))))
            c.scrollView.frame = page.bounds
            page.addSubview(c.scrollView)
            c.overlays.layout()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            c.overlays.layout()
            try ParityRenderTests.png(page, "prose-reader-\(theme.rawValue)-\(Self.tag)", background: MarkdownPalette.concrete(theme.tokens.background))

            let (view, _, scroll) = LivePreviewEditorTests.editor(ProseSample.note, theme: theme, size: NSSize(width: 900, height: 2400))
            scroll.frame.size.height = min(2600, max(600, view.frame.height))
            LivePreviewEditorTests.settle(view)
            try ParityRenderTests.png(scroll, "prose-live-\(theme.rawValue)-\(Self.tag)", background: MarkdownPalette.concrete(theme.tokens.background))
        }
    }
}
#endif
