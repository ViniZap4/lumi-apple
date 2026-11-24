#if canImport(AppKit)
import AppKit
import SwiftUI
import LumiKit

/// Click-to-focus for split panes (SPEC-PARTE2 §3), read from AppKit at
/// click time.
///
/// Why: the shell used to find the clicked pane from SwiftUI `.global`
/// frames cached by `onGeometryChange`, and only moved the *logical*
/// focus. The keyboard (first responder) moved only when the click
/// happened to land on a text view that takes first responder on
/// mouse-down. A click on the pane header, a margin, the loading
/// skeleton, an internal link / task box (handled before
/// `super.mouseDown`), a hosted attachment, a board or a canvas left the
/// previous pane's editor first responder — and the key router hands
/// every key to an editable first responder, so the old pane kept typing:
/// "the first click does not switch". The probes below give exact window
/// geometry, and `PaneClickFocus` says whether the keyboard must still be
/// moved once the click was handled.
@MainActor
public final class PaneProbeRegistry {
    private final class Weak { weak var view: NSView?; init(_ v: NSView) { view = v } }
    private var probes: [PaneLeafID: Weak] = [:]

    public init() {}

    public func register(_ id: PaneLeafID, view: NSView) { probes[id] = Weak(view) }

    public func unregister(_ id: PaneLeafID, view: NSView) {
        if probes[id]?.view === view { probes[id] = nil }
    }

    /// Pane `id` in window coordinates (nil when not mounted in `window`).
    public func windowRect(_ id: PaneLeafID, in window: NSWindow) -> CGRect? {
        guard let v = probes[id]?.view, v.window === window, !v.isHiddenOrHasHiddenAncestor else { return nil }
        return v.convert(v.bounds, to: nil)
    }

    /// The pane under `point` (window coordinates), among `visible`.
    public func leaf(at point: CGPoint, in window: NSWindow, among visible: [PaneLeafID]) -> PaneLeafID? {
        visible.first { windowRect($0, in: window)?.contains(point) == true }
    }
}

/// Invisible marker behind a pane: reports the pane's AppKit geometry,
/// never takes a click.
public struct PaneProbe: NSViewRepresentable {
    let id: PaneLeafID
    let registry: PaneProbeRegistry

    public init(id: PaneLeafID, registry: PaneProbeRegistry) {
        self.id = id
        self.registry = registry
    }

    public final class ProbeView: NSView {
        var id: PaneLeafID?
        weak var registry: PaneProbeRegistry?
        public override func hitTest(_ point: NSPoint) -> NSView? { nil }
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let id, let registry else { return }
            if window != nil { registry.register(id, view: self) } else { registry.unregister(id, view: self) }
        }
    }

    public func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.id = id
        v.registry = registry
        registry.register(id, view: v)
        return v
    }

    public func updateNSView(_ v: ProbeView, context: Context) {
        if v.id != id, let old = v.id { registry.unregister(old, view: v) }
        v.id = id
        v.registry = registry
        registry.register(id, view: v)
    }

    public static func dismantleNSView(_ v: ProbeView, coordinator: ()) {
        if let id = v.id { v.registry?.unregister(id, view: v) }
    }
}

/// After a click was dispatched: does the keyboard still sit outside the
/// clicked pane?
public enum PaneClickFocus {
    /// The window's first responder is a view inside `paneRect` (window
    /// coordinates): a text view whose visible part is centred in the
    /// pane, or a field editor of a field in it. The window, the content
    /// (hosting) view and anything else count as outside.
    public static func responderIsInside(_ window: NSWindow, paneRect: CGRect) -> Bool {
        guard let view = window.firstResponder as? NSView, view !== window.contentView else { return false }
        let visible = view.visibleRect
        guard !visible.isEmpty else { return false }
        let r = view.convert(visible, to: nil)
        return paneRect.contains(CGPoint(x: r.midX, y: r.midY))
    }

    /// The previous pane's text view still owns the keys, or nothing in
    /// the clicked pane took them: the host moves the keyboard to the
    /// clicked pane.
    public static func needsKeyboardMove(_ window: NSWindow, paneRect: CGRect) -> Bool {
        !responderIsInside(window, paneRect: paneRect)
    }
}
#endif
