#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

/// Large-note benchmark (5k lines, ~1.4k blocks). Prints `BENCH` lines;
/// bounds are deliberately loose so the suite isn't flaky on a busy
/// machine — the numbers are the point, the asserts only catch
/// order-of-magnitude regressions.
@Suite("Renderer benchmark", .serialized)
@MainActor
struct RendererBenchmark {
    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private func makeController(width: CGFloat = 900, height: CGFloat = 900) -> MarkdownDocumentController {
        let controller = MarkdownDocumentController()
        controller.scrollView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.textView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        return controller
    }

    private func push(_ controller: MarkdownDocumentController, _ doc: MarkdownDocument, _ style: MarkdownRenderStyle) {
        controller.update(
            header: MarkdownHeader(title: "Benchmark", tags: ["perf"]), document: doc, style: style,
            readingWidth: 720, linkAction: .systemDefault, vaultRoot: nil, embedDepth: 0
        )
    }

    @Test("TextKit 2 document renderer, 5k lines")
    func newRenderer() throws {
        let source = RenderFixtures.largeNote()
        let style = MarkdownRenderStyle(theme: LumiTheme.defaultLight.tokens)
        let clock = ContinuousClock()

        let t0 = clock.now
        let doc = MarkdownParser.parse(source)
        let parse = clock.now - t0

        MarkdownFragmentCache.shared.removeAll()
        let controller = makeController()
        let t1 = clock.now
        push(controller, doc, style)
        let tlm = try #require(controller.textView.textLayoutManager)
        tlm.ensureLayout(for: CGRect(x: 0, y: 0, width: 900, height: 900))
        let firstScreen = clock.now - t1

        let t2 = clock.now
        tlm.ensureLayout(for: tlm.documentRange)
        let fullLayout = clock.now - t2

        // Re-open the same note in a fresh view: fragments come from cache.
        let reopened = makeController()
        let t3 = clock.now
        push(reopened, doc, style)
        try #require(reopened.textView.textLayoutManager).ensureLayout(for: CGRect(x: 0, y: 0, width: 900, height: 900))
        let warmReopen = clock.now - t3

        // One-paragraph edit in the middle of the note.
        let edited = MarkdownParser.parse(source.replacingOccurrences(of: "Paragraph 200 with", with: "Paragraph 200 (edited) with"))
        let t4 = clock.now
        push(controller, edited, style)
        let incremental = clock.now - t4

        // Theme switch: everything re-rendered with new colours.
        let t5 = clock.now
        push(controller, edited, MarkdownRenderStyle(theme: LumiTheme.defaultDark.tokens))
        let themeSwitch = clock.now - t5

        print("""
        BENCH new: blocks=\(doc.blocks.count) parse=\(Self.seconds(parse))s \
        firstScreen=\(Self.seconds(firstScreen))s fullLayout=\(Self.seconds(fullLayout))s \
        warmReopen=\(Self.seconds(warmReopen))s incrementalEdit=\(Self.seconds(incremental))s \
        themeSwitch=\(Self.seconds(themeSwitch))s
        """)
        #expect(Self.seconds(firstScreen) < 2.0)
        #expect(Self.seconds(incremental) < 0.5)
        #expect(controller.textView.textStorage?.string.contains("Paragraph 200 (edited) with") == true)
    }

    /// Apples-to-apples with the pre-rewrite read pane, measured the same
    /// way (window, layout, first display). The old pipeline —
    /// MarkdownView in an NSHostingView inside NSScrollView — took ~2.0 s
    /// on this fixture and created 315 NSTextViews up front.
    @Test("read pane, windowed: time to first display")
    func windowed() {
        let doc = MarkdownParser.parse(RenderFixtures.largeNote())
        MarkdownFragmentCache.shared.removeAll()
        let clock = ContinuousClock()
        let start = clock.now
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let controller = MarkdownDocumentController()
        controller.scrollView.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
        window.contentView = controller.scrollView
        push(controller, doc, MarkdownRenderStyle(theme: LumiTheme.defaultLight.tokens))
        controller.scrollView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let elapsed = Self.seconds(clock.now - start)
        print("BENCH new-windowed: total=\(elapsed)s textViews=1")
        #expect(elapsed < 2.0)
    }

    @Test("secondary SwiftUI MarkdownView (preview pane), 5k lines, eager layout")
    func swiftUIView() {
        let doc = MarkdownParser.parse(RenderFixtures.largeNote())
        let clock = ContinuousClock()
        let start = clock.now
        let host = NSHostingView(rootView: MarkdownView(doc)
            .environment(\.theme, LumiTheme.defaultLight.tokens)
            .frame(width: 624))
        _ = host.fittingSize
        print("BENCH swiftui-view: layout=\(Self.seconds(clock.now - start))s")
    }
}
#endif
