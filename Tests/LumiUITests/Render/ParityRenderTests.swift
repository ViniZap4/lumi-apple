#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

/// Rich sample note covering the prose system (web parity).
enum ParitySample {
    static let note = """
    # Field notes

    Lumi keeps **notes as plain markdown** — _portable_, ~~locked~~ open, and readable anywhere. Press <kbd>⌘</kbd> <kbd>K</kbd> to jump, or type `:preview split` in the editor.[^1] A ==highlighted phrase== stands out.

    ## Getting started

    1. Open a book from the sidebar.
    2. Pick a note with `j` / `k`.
    3. Press `e` to edit.

    - Bullets hang in the margin
      - nested bullets use a ring
        - and then a square
    - [ ] write the parity report
    - [x] ship the prose stylesheet

    > Quotes stay quiet: a thin bar and dimmed text, so they read as an aside rather than a shout.

    > [!tip] Keyboard first
    > Every mouse action has a key. The context menu shows it.

    > [!warning]- Folded by default
    > Hidden until you open it.

    > [!danger] Careful
    > Deleting a book removes it from every device.

    ```swift
    // Ranged ops only (CRDT-CLIENT-PROTOCOL §3)
    func toggle(_ index: Int) -> TextEdit? {
        let marker = markers[index]
        return TextEdit(location: marker, length: 1, replacement: "x")
    }
    ```

    | Client | Sync | Live cursors |
    |:-------|:----:|-------------:|
    | Web | Yjs | yes |
    | Apple | yswift | yes |
    | TUI | snapshot + diff | no |

    ### Small heading

    Read the [protocol](https://example.com/protocol) or a [vault note](other-note.md), and see the footnote.

    ---

    ##### Fine print

    That's all.

    [^1]: Footnotes collect at the end, with a way back.
    """
}

@Suite("Parity renders (offscreen PNGs when LUMI_RENDER_DIR is set)", .serialized)
@MainActor
struct ParityRenderTests {
    static var dir: URL? {
        ProcessInfo.processInfo.environment["LUMI_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func png(_ view: NSView, _ name: String, background: NSColor) throws {
        guard let dir else { return }
        let host = NSView(frame: view.bounds)
        host.wantsLayer = true
        host.layer?.backgroundColor = background.cgColor
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: dir.appendingPathComponent(name + ".png"))
        view.removeFromSuperview()
    }

    static func readerView(_ text: String, theme: LumiTheme, size: NSSize, title: String = "Field notes", tags: [String] = ["lumi", "parity"]) -> MarkdownDocumentController {
        let controller = MarkdownDocumentController()
        controller.scrollView.frame = NSRect(origin: .zero, size: size)
        let tv = controller.textView
        tv.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height))
        let header = MarkdownText.startsWithTitle(text, title: title) ? MarkdownHeader(title: "", tags: tags) : MarkdownHeader(title: title, tags: tags)
        controller.update(
            header: header, document: MarkdownParser.parse(text),
            style: MarkdownRenderStyle(theme: theme.tokens, tasksInteractive: true),
            readingWidth: 760, linkAction: .systemDefault, vaultRoot: nil, embedDepth: 0,
            onToggleTask: { _ in }
        )
        if let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager {
            tlm.ensureLayout(for: tcm.documentRange)
        }
        tv.sizeToFit()
        tv.layoutSubtreeIfNeeded()
        controller.overlays.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.overlays.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return controller
    }

    /// A vim editor view laid out offscreen (no window), like the cursor
    /// overlay tests.
    static func editor(_ text: String, theme: LumiTheme, size: NSSize) -> (VimAppKitTextView, VimController, NSScrollView) {
        let c = VimController(initialText: text)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.drawsBackground = false
        let view = VimAppKitTextView(usingTextLayoutManager: true)
        view.styler = EditorStyler(theme: theme.tokens, fontSize: 13)
        view.minSize = .zero
        view.maxSize = NSSize(width: 1e6, height: 1e6)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.frame = NSRect(origin: .zero, size: size)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.drawsBackground = false
        scroll.documentView = view
        view.focusOverride = true
        view.attach(c)
        view.yankColor = NSColor(theme.tokens.accent)
        return (view, c, scroll)
    }

    static func applyHighlights(_ view: VimAppKitTextView, _ c: VimController, theme: LumiTheme) {
        let visual = c.state.mode.isVisual
        view.selectedTextAttributes = [.backgroundColor: visual ? NSColor.clear : NSColor(theme.tokens.editorSelection)]
        view.applyRenderingHighlights(search: [], searchColor: .clear, block: c.visualHighlightRanges,
                                      blockColor: NSColor(theme.tokens.editorSelection))
        view.updateCursor()
    }

    static let editorSample = """
    # Field notes

    Lumi keeps **notes as plain markdown**.
    - [ ] write the parity report
    - [x] ship the prose stylesheet

    > [!tip] Keyboard first
    > Every mouse action has a key.
    """

    @Test("editor: visual selection on every theme, yank flash")
    func editorStates() throws {
        guard Self.dir != nil else { return }
        // Visual selection: one strip per theme, so an invisible
        // selection on any theme shows up at a glance.
        let themes = LumiTheme.allCases
        let stripH: CGFloat = 78
        let sheet = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: stripH * CGFloat(themes.count)))
        for (i, theme) in themes.enumerated() {
            let (view, c, scroll) = Self.editor("Lumi keeps notes as plain markdown,\nportable and readable anywhere.", theme: theme, size: NSSize(width: 520, height: stripH))
            for ch in "wvjll" { c.send(.character(ch)) }
            Self.applyHighlights(view, c, theme: theme)
            let strip = NSView(frame: NSRect(x: 0, y: CGFloat(themes.count - 1 - i) * stripH, width: 520, height: stripH))
            strip.wantsLayer = true
            strip.layer?.backgroundColor = MarkdownPalette.concrete(theme.tokens.background).cgColor
            strip.addSubview(scroll)
            let label = NSTextField(labelWithString: theme.rawValue)
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = MarkdownPalette.concrete(theme.tokens.textDim)
            label.frame = NSRect(x: 400, y: 4, width: 116, height: 14)
            label.alignment = .right
            strip.addSubview(label)
            sheet.addSubview(strip)
        }
        try Self.png(sheet, "visual-selection-all-themes", background: .black)

        for (theme, name) in [(LumiTheme.tokyoNight, "yank-flash-dark"), (LumiTheme.catppuccinLatte, "yank-flash-light")] {
            let (view, c, scroll) = Self.editor(Self.editorSample, theme: theme, size: NSSize(width: 520, height: 200))
            Self.applyHighlights(view, c, theme: theme)
            for ch in "jjjjyy" { c.send(.character(ch)) }   // yank "- [ ] write the parity report"
            view.updateCursor()
            // Freeze the flash at its peak for the snapshot.
            for sub in view.subviews where sub is YankFlashView { sub.layer?.removeAllAnimations(); sub.alphaValue = 1 }
            try Self.png(scroll, name, background: MarkdownPalette.concrete(theme.tokens.background))
        }
    }

    @Test("split: source beside the preview, scroll-synced")
    func split() throws {
        guard Self.dir != nil else { return }
        for (theme, name) in [(LumiTheme.tokyoNight, "split-dark"), (LumiTheme.catppuccinLatte, "split-light")] {
            let size = NSSize(width: 1240, height: 760)
            let page = NSView(frame: NSRect(origin: .zero, size: size))
            let editorW = size.width * 0.5 - 4
            let (view, c, scroll) = Self.editor(ParitySample.note, theme: theme, size: NSSize(width: editorW, height: size.height))
            Self.applyHighlights(view, c, theme: theme)
            page.addSubview(scroll)
            let divider = NSView(frame: NSRect(x: editorW + 3.5, y: 0, width: 1, height: size.height))
            divider.wantsLayer = true
            divider.layer?.backgroundColor = MarkdownPalette.concrete(theme.tokens.border).withAlphaComponent(0.7).cgColor
            page.addSubview(divider)
            let preview = Self.readerView(ParitySample.note, theme: theme, size: NSSize(width: size.width - editorW - 8, height: size.height), title: "", tags: [])
            preview.scrollView.frame = NSRect(x: editorW + 8, y: 0, width: size.width - editorW - 8, height: size.height)
            page.addSubview(preview.scrollView)
            preview.overlays.layout()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            // Scroll the editor to the callouts and let the sync follow.
            let sync = SplitScrollSync()
            sync.attach(editor: c)
            sync.attach(preview: preview)
            sync.previewDidLayout(MarkdownParser.parse(ParitySample.note))
            c.scrollViewport(toLine: 27)
            sync.scrolled(.source)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            preview.overlays.layout()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            try Self.png(page, name, background: MarkdownPalette.concrete(theme.tokens.background))
        }
    }

    @Test("reader: rich sample note, dark + light")
    func reader() throws {
        guard Self.dir != nil else { return }
        for (theme, name) in [(LumiTheme.tokyoNight, "reader-dark"), (LumiTheme.catppuccinLatte, "reader-light")] {
            let c = Self.readerView(ParitySample.note, theme: theme, size: NSSize(width: 900, height: 2600))
            let tv = c.textView
            tv.frame.size.height = max(tv.frame.height, 600)
            let page = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: min(3200, tv.frame.height)))
            c.scrollView.frame = page.bounds
            page.addSubview(c.scrollView)
            c.overlays.layout()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            c.overlays.layout()
            try Self.png(page, name, background: MarkdownPalette.concrete(theme.tokens.background))
        }
    }
}
#endif
