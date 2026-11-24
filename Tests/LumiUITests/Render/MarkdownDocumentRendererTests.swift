#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

@Suite("Markdown document renderer", .serialized)
@MainActor
struct MarkdownDocumentRendererTests {
    private let source = """
    # Heading with [link](https://example.com/h)

    Body **bold** _em_ `code` and [a link](https://example.com/a).

    > quoted
    > more

    - [ ] task
    - [x] done
      1. nested

    ```swift
    let a = 1
    let b = 2
    ```

    $$ x^2 $$

    ---

    Tail paragraph.
    """

    private func style(_ theme: LumiTheme = .defaultLight) -> MarkdownRenderStyle {
        MarkdownRenderStyle(theme: theme.tokens)
    }

    private func render(_ text: String, style: MarkdownRenderStyle, cache: MarkdownFragmentCache) -> NSMutableAttributedString {
        let renderer = MarkdownDocumentRenderer(cache: cache)
        let storage = NSMutableAttributedString()
        let update = renderer.update(header: MarkdownHeader(title: "T", tags: ["x"]), document: MarkdownParser.parse(text), style: style)!
        storage.replaceCharacters(in: update.range, with: update.replacement)
        return storage
    }

    @Test("incremental update touches one block and matches a fresh build")
    func incrementalMatchesFresh() throws {
        let cache = MarkdownFragmentCache(capacity: 1_000)
        let renderer = MarkdownDocumentRenderer(cache: cache)
        let storage = NSMutableAttributedString()
        let header = MarkdownHeader(title: "T", tags: ["x"])
        let first = try #require(renderer.update(header: header, document: MarkdownParser.parse(source), style: style()))
        #expect(first.isFullReload)
        storage.replaceCharacters(in: first.range, with: first.replacement)
        #expect(storage.length == renderer.totalLength)

        let edited = source.replacingOccurrences(of: "Tail paragraph.", with: "Tail paragraph, edited.")
        let second = try #require(renderer.update(header: header, document: MarkdownParser.parse(edited), style: style()))
        #expect(!second.isFullReload)
        #expect(second.rebuiltSegments == 1)
        #expect(second.reusedSegments == 0)
        storage.replaceCharacters(in: second.range, with: second.replacement)

        let fresh = render(edited, style: style(), cache: MarkdownFragmentCache(capacity: 1_000))
        #expect(storage.string == fresh.string)
        #expect(storage.length == renderer.totalLength)

        // No-op update returns nil: the host does no work at all.
        #expect(renderer.update(header: header, document: MarkdownParser.parse(edited), style: style()) == nil)
    }

    @Test("fragment cache: reopen hits, theme or scale change misses")
    func cacheInvalidation() throws {
        let cache = MarkdownFragmentCache(capacity: 1_000)
        let doc = MarkdownParser.parse(source)
        let blocks = doc.blocks.count

        let a = MarkdownDocumentRenderer(cache: cache)
        let first = try #require(a.update(header: nil, document: doc, style: style(.defaultLight)))
        #expect(first.rebuiltSegments == blocks)

        // Re-opening the same note in a new view: every block is reused.
        let b = MarkdownDocumentRenderer(cache: cache)
        let reopened = try #require(b.update(header: nil, document: doc, style: style(.defaultLight)))
        #expect(reopened.reusedSegments == blocks)
        #expect(reopened.rebuiltSegments == 0)

        // Theme change on the live renderer: full rebuild, no stale reuse.
        let themed = try #require(b.update(header: nil, document: doc, style: style(.defaultDark)))
        #expect(themed.isFullReload)
        #expect(themed.rebuiltSegments == blocks)

        var bigger = style(.defaultDark)
        bigger.scale = 1.2
        let scaled = try #require(b.update(header: nil, document: doc, style: bigger))
        #expect(scaled.rebuiltSegments == blocks)
    }

    @Test("theme colours are applied for every theme (light themes included)")
    func themeApplication() throws {
        for theme in LumiTheme.allCases {
            let storage = render("Plain body text and [link](https://x.y).\n\n```\ncode\n```", style: style(theme), cache: MarkdownFragmentCache(capacity: 100))
            let palette = MarkdownPalette(theme.tokens)
            let bodyIndex = (storage.string as NSString).range(of: "Plain").location
            let color = try #require(storage.attribute(.foregroundColor, at: bodyIndex, effectiveRange: nil) as? NSColor)
            #expect(color == palette.text, "body colour wrong for \(theme.rawValue)")

            let linkIndex = (storage.string as NSString).range(of: "link").location
            #expect(storage.attribute(.link, at: linkIndex, effectiveRange: nil) as? URL == URL(string: "https://x.y"))
            #expect(storage.attribute(.foregroundColor, at: linkIndex, effectiveRange: nil) as? NSColor == palette.link)

            // Fenced code is a hosted block (header, copy, wrap toggle).
            var code: MarkdownBlockAttachment?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let a = value as? MarkdownBlockAttachment { code = a }
            }
            guard case let .code(language, body)? = code?.payload else {
                Issue.record("expected a code attachment for \(theme.rawValue)")
                continue
            }
            #expect(language == nil)
            #expect(body.hasPrefix("code"))
            #expect(palette.codeBackground != palette.background)
        }
        let light = MarkdownPalette(LumiTheme.defaultLight.tokens).text
        let dark = MarkdownPalette(LumiTheme.defaultDark.tokens).text
        #expect(light != dark)
    }

    @Test("structure: code is one paragraph, attachments carry source, copy text is markdown-ish")
    func structureAndCopy() throws {
        let storage = render(source, style: style(), cache: MarkdownFragmentCache(capacity: 100))
        var attachments: [MarkdownBlockAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let a = value as? MarkdownBlockAttachment { attachments.append(a) }
        }
        #expect(attachments.count == 2)
        guard case let .code(language, code)? = attachments.first?.payload else {
            Issue.record("expected a code block attachment")
            return
        }
        #expect(language == "swift")
        #expect(code.contains("let a = 1\nlet b = 2"))
        guard case let .mathBlock(latex)? = attachments.last?.payload else {
            Issue.record("expected a math block attachment")
            return
        }
        #expect(latex.trimmingCharacters(in: .whitespaces) == "x^2")

        let copied = storage.lumiCopyText(in: NSRange(location: 0, length: storage.length))
        #expect(copied.contains("```swift\nlet a = 1\nlet b = 2\n```"))
        #expect(copied.contains("$$\(latex)$$"))
        #expect(copied.contains("[ ] "))
        #expect(copied.contains("[x] "))
        #expect(!copied.contains("\u{FFFC}"))
    }

    @Test("quote paragraphs are stamped first/last for contiguous chrome")
    func quoteStamping() throws {
        let storage = render("> one\n>\n> two", style: style(), cache: MarkdownFragmentCache(capacity: 10))
        let ns = storage.string as NSString
        let one = try #require(storage.attribute(.lumiDecorations, at: ns.range(of: "one").location, effectiveRange: nil) as? [MarkdownDecoration])
        let two = try #require(storage.attribute(.lumiDecorations, at: ns.range(of: "two").location, effectiveRange: nil) as? [MarkdownDecoration])
        #expect(one.last?.kind == .quote && one.last?.isFirst == true && one.last?.isLast == false)
        #expect(two.last?.kind == .quote && two.last?.isFirst == false && two.last?.isLast == true)
    }
}

@Suite("Markdown TextKit 2 layout", .serialized)
@MainActor
struct MarkdownTextKitLayoutTests {
    private func makeView(_ text: String, width: CGFloat = 640) -> MarkdownDocumentController {
        let controller = MarkdownDocumentController()
        controller.scrollView.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        controller.textView.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        controller.update(
            header: MarkdownHeader(title: "Title"),
            document: MarkdownParser.parse(text),
            style: MarkdownRenderStyle(theme: LumiTheme.defaultLight.tokens),
            readingWidth: 720, linkAction: .systemDefault, vaultRoot: nil, embedDepth: 0
        )
        return controller
    }

    @Test("view runs TextKit 2 with decorated fragments for block chrome")
    func usesTextKit2() throws {
        let controller = makeView("> quoted\n\nplain")
        let tv = controller.textView
        let tlm = try #require(tv.textLayoutManager)
        tlm.ensureLayout(for: tlm.documentRange)
        var decorated = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            if fragment is MarkdownLayoutFragment { decorated += 1 }
            return true
        }
        // Header rule + quote bar.
        #expect(decorated >= 2)
    }

    @Test("attachment rects are in container space, sized by the attachment")
    func attachmentGeometry() throws {
        let controller = makeView("Intro paragraph that takes a line.\n\n$$ a+b $$\n\nmiddle\n\n$$ c+d $$")
        let tv = controller.textView
        let tlm = try #require(tv.textLayoutManager)
        let found = markdownAttachments(in: tlm, rect: CGRect(x: 0, y: 0, width: 2_000, height: 10_000))
        #expect(found.count == 2)
        guard found.count == 2 else { return }
        #expect(found[0].1.minY > 40, "first attachment must sit below title + intro, got \(found[0].1)")
        #expect(found[1].1.minY > found[0].1.maxY)
        #expect(abs(found[0].1.height - found[0].0.height) < 1)
        #expect(found[0].1.width > 100)

        // Cross-check against TextKit's own container-space segment rect
        // for the attachment character (guards the fragment-local vs
        // container coordinate conversion).
        let storage = try #require(tv.textStorage)
        let content = try #require(tlm.textContentManager)
        var offsets: [Int] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value is MarkdownBlockAttachment { offsets.append(range.location) }
        }
        for (i, offset) in offsets.enumerated() {
            let start = try #require(content.location(content.documentRange.location, offsetBy: offset))
            let end = try #require(content.location(start, offsetBy: 1))
            var segment = CGRect.null
            tlm.enumerateTextSegments(in: try #require(NSTextRange(location: start, end: end)), type: .standard, options: []) { _, frame, _, _ in
                segment = segment.union(frame)
                return true
            }
            #expect(segment.intersects(found[i].1), "attachment \(i): overlay \(found[i].1) vs segment \(segment)")
            #expect(abs(segment.minX - found[i].1.minX) < 1)
        }
    }

    @Test("link hit-testing uses real glyph segments")
    func linkHitTest() throws {
        let controller = makeView("Some words then [the link](https://example.com/x) and more words.")
        let tv = controller.textView
        let tlm = try #require(tv.textLayoutManager)
        tlm.ensureLayout(for: tlm.documentRange)
        let storage = try #require(tv.textStorage)
        let linkRange = (storage.string as NSString).range(of: "the link")
        let content = try #require(tlm.textContentManager)
        let start = try #require(content.location(content.documentRange.location, offsetBy: linkRange.location))
        let end = try #require(content.location(start, offsetBy: linkRange.length))
        var segment = CGRect.null
        tlm.enumerateTextSegments(in: try #require(NSTextRange(location: start, end: end)), type: .standard, options: []) { _, frame, _, _ in
            segment = segment.union(frame)
            return true
        }
        let origin = tv.textContainerOrigin
        let center = CGPoint(x: segment.midX + origin.x, y: segment.midY + origin.y)
        let hit = try #require(tv.linkHit(at: center))
        #expect(hit.value as? URL == URL(string: "https://example.com/x"))
        #expect(hit.range == linkRange)
        // Far right of the same line is not on the link.
        #expect(tv.linkHit(at: CGPoint(x: 5, y: center.y + 400)) == nil)
    }

    @Test("attachment views are mounted lazily, only near the viewport")
    func lazyOverlays() async throws {
        let blocks = (0..<200).map { "$$ x_{\($0)} $$" }.joined(separator: "\n\n")
        let controller = MarkdownDocumentController()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = root
        controller.scrollView.frame = root.bounds
        root.addSubview(controller.scrollView)
        controller.update(
            header: nil, document: MarkdownParser.parse(blocks),
            style: MarkdownRenderStyle(theme: LumiTheme.defaultLight.tokens),
            readingWidth: 720, linkAction: .systemDefault, vaultRoot: nil, embedDepth: 0
        )
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(30))
            root.layoutSubtreeIfNeeded()
        }
        let mounted = controller.overlays.mountedCount
        #expect(mounted > 0)
        // 600pt viewport + one screen of overscan ≈ 30 blocks, not 200.
        #expect(mounted < 60, "mounted \(mounted) of 200 attachments")
    }

    @Test("reading width centres the text column")
    func readingWidthInsets() {
        let controller = makeView("x", width: 1_200)
        let tv = controller.textView
        #expect(abs(tv.textContainerInset.width - ((1_200 - 720) / 2 + 48)) < 0.5)
        tv.readingWidth = 900
        #expect(abs(tv.textContainerInset.width - ((1_200 - 900) / 2 + 48)) < 0.5)
    }
}

@Suite("Link tooltip label")
struct LinkTooltipLabelTests {
    @Test func vaultRelative() {
        let root = URL(fileURLWithPath: "/Users/me/Notes/vault")
        #expect(LinkTooltipLabel.label(for: URL(fileURLWithPath: "/Users/me/Notes/vault/sub/n.md"), vaultRoot: root, home: "/Users/me") == "./sub/n.md")
        #expect(LinkTooltipLabel.label(for: URL(fileURLWithPath: "/Users/me/other.md"), vaultRoot: root, home: "/Users/me") == "~/other.md")
        #expect(LinkTooltipLabel.label(for: URL(string: "https://example.com/a?b")!, vaultRoot: root) == "https://example.com/a?b")
        #expect(LinkTooltipLabel.label(for: 42, vaultRoot: root) == nil)
    }
}
#endif
