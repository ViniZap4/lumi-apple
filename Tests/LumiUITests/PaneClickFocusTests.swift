#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import LumiKit
@testable import LumiUI

/// Click-to-focus (SPEC-PARTE2 §3) on an offscreen window: the window is
/// created but never ordered in, so nothing takes focus or input.
@Suite("Pane click-to-focus (offscreen NSEvents)", .serialized)
@MainActor
struct PaneClickFocusTests {
    /// Hosts a given AppKit view.
    struct Wrap: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ v: NSView, context: Context) {}
    }


    @MainActor
    final class Harness {
        let window: NSWindow
        let registry = PaneProbeRegistry()
        let texts: [NSTextView]
        init(zoomed: PaneLeafID? = nil) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            texts = (0..<2).map { i in
                let tv = VimAppKitTextView(usingTextLayoutManager: true)
                tv.string = "pane \(i + 1)\nsome text to click into"
                tv.isEditable = true
                tv.frame = NSRect(x: 0, y: 0, width: 400, height: 370)
                return tv
            }
            let one = PaneLeafID(1), two = PaneLeafID(2)
            let root = PaneNode.split(.vertical, [.leaf(one, .note(path: "a.md", view: .source)),
                                                  .leaf(two, .note(path: "b.md", view: .source))], [0.5, 0.5])
            let registry = self.registry, texts = self.texts
            let view = PaneLayoutView(root: root, focused: one, showsFocus: true, zoomed: zoomed, onResize: { _, _, _ in }) { id, _ in
                VStack(spacing: 0) {
                    // The header: plain SwiftUI, takes no first responder.
                    Text("header \(id.raw)").frame(maxWidth: .infinity, minHeight: 30)
                    Wrap(view: texts[id.raw - 1])
                }
                .background(PaneProbe(id: id, registry: registry))
            }
            .environment(\.lumiMotion, false)
            .frame(width: 800, height: 400)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            for _ in 0..<5 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                host.layoutSubtreeIfNeeded()
            }
        }

        /// What a click at a window point (AppKit, origin bottom-left)
        /// lands on: `NSWindow.sendEvent`'s hit test. (The swift test host
        /// cannot run AppKit's mouse tracking loop — nested `nextEvent`
        /// drains its async main queue — so the dispatch is asserted at the
        /// hit-test level; a hit `NSTextView` takes first responder on
        /// mouse-down, which is AppKit's documented behaviour.)
        func hit(_ p: NSPoint) -> NSView? {
            guard let content = window.contentView else { return nil }
            return content.hitTest(content.superview?.convert(p, from: nil) ?? p)
        }

        /// The effect of AppKit's mouse-down on what was hit.
        func click(_ p: NSPoint) -> NSView? {
            let v = hit(p)
            if let v, v.acceptsFirstResponder { window.makeFirstResponder(v) }
            return v
        }
    }

    @Test("probes give exact window geometry; the click finds its pane", .timeLimit(.minutes(1)))
    func geometry() throws {
        let h = Harness()
        let r1 = try #require(h.registry.windowRect(PaneLeafID(1), in: h.window))
        let r2 = try #require(h.registry.windowRect(PaneLeafID(2), in: h.window))
        #expect(abs(r1.minX) < 1 && abs(r1.width - 399.5) < 1.5)
        #expect(abs(r2.maxX - 800) < 1)
        let ids = [PaneLeafID(1), PaneLeafID(2)]
        #expect(h.registry.leaf(at: CGPoint(x: 100, y: 200), in: h.window, among: ids) == PaneLeafID(1))
        #expect(h.registry.leaf(at: CGPoint(x: 700, y: 390), in: h.window, among: ids) == PaneLeafID(2))
        // Not visible (zoomed away): never found.
        #expect(h.registry.leaf(at: CGPoint(x: 700, y: 200), in: h.window, among: [PaneLeafID(1)]) == nil)
    }

    @Test("root cause: a click on a pane's header leaves the old pane's editor first responder", .timeLimit(.minutes(1)))
    func headerClickKeepsOldResponder() throws {
        let h = Harness()
        h.window.makeFirstResponder(h.texts[0])
        let r2 = try #require(h.registry.windowRect(PaneLeafID(2), in: h.window))
        // The header strip of pane 2 (top 30 pt; AppKit y is bottom-up).
        let hit = h.click(NSPoint(x: 600, y: r2.maxY - 12))
        // What is under the header takes no first responder…
        #expect(!(hit is NSText))
        #expect(hit?.acceptsFirstResponder != true || hit === h.window.contentView)
        #expect(h.window.firstResponder === h.texts[0])
        // …so the host must move the keyboard: this is what was missing.
        let mv = PaneClickFocus.needsKeyboardMove(h.window, paneRect: r2)
        #expect(mv)
        let r1 = try #require(h.registry.windowRect(PaneLeafID(1), in: h.window))
        #expect(!PaneClickFocus.needsKeyboardMove(h.window, paneRect: r1))
    }

    @Test("a click into the other pane's text focuses it and places the caret on the first click", .timeLimit(.minutes(1)))
    func textClick() throws {
        let h = Harness()
        h.window.makeFirstResponder(h.texts[0])
        let r2 = try #require(h.registry.windowRect(PaneLeafID(2), in: h.window))
        h.texts[1].setSelectedRange(NSRange(location: 0, length: 0))
        let tf = h.texts[1].convert(h.texts[1].bounds, to: nil)
        #expect(r2.contains(CGPoint(x: tf.midX, y: tf.midY)))
        let p = NSPoint(x: tf.minX + 60, y: tf.maxY - 8)
        let hit = h.click(p)
        #expect(hit === h.texts[1])
        #expect(h.window.firstResponder === h.texts[1])
        #expect(!PaneClickFocus.needsKeyboardMove(h.window, paneRect: r2))
        // The same click places the caret there.
        let local = h.texts[1].convert(p, from: nil)
        #expect(h.texts[1].characterIndexForInsertion(at: local) > 0)
    }

    @Test("pane text views accept the first mouse (no dead click in an inactive window)")
    func firstMouse() {
        #expect(VimAppKitTextView(usingTextLayoutManager: true).acceptsFirstMouse(for: nil))
        #expect(MarkdownDocumentController().textView.acceptsFirstMouse(for: nil))
    }

    @Test("zoom: the zoomed pane covers the area; the hidden pane is out of reach", .timeLimit(.minutes(1)))
    func zoomGeometry() throws {
        let h = Harness(zoomed: PaneLeafID(2))
        let r2 = try #require(h.registry.windowRect(PaneLeafID(2), in: h.window))
        #expect(abs(r2.width - 800) < 1 && abs(r2.minX) < 1)
        // Pane 1 still mounted (session alive) but moved out of the window.
        let r1 = h.registry.windowRect(PaneLeafID(1), in: h.window)
        #expect(r1 == nil || !(r1!.intersects(CGRect(x: 0, y: 0, width: 800, height: 400))))
        #expect(h.texts[0].superview != nil)
        #expect(h.registry.leaf(at: CGPoint(x: 100, y: 200), in: h.window, among: [PaneLeafID(1), PaneLeafID(2)]) == PaneLeafID(2))
    }
}
#endif
