#if canImport(AppKit)
import AppKit
import SwiftUI
import LumiKit

/// Live Preview block widgets on macOS: the reader's own views (table,
/// code block, math, diagram, image — `MarkdownAttachmentContent`) laid
/// over the space a collapsed source block reserves, mounted only near
/// the viewport. A click on a widget puts the cursor into its source,
/// which reveals it (web: clicking a rendered table drops the cursor in).
@MainActor
final class LiveWidgetOverlays {
    weak var textView: NSTextView?
    var environment: MarkdownHostedEnvironment
    /// Measured natural height for a payload.
    var onHeight: (MarkdownBlockAttachment.Payload, CGFloat) -> Void = { _, _ in }
    /// The widget at this source location was clicked.
    var onActivate: (Int) -> Void = { _ in }

    private struct Mounted {
        let payload: MarkdownBlockAttachment.Payload
        let view: LiveWidgetHostView
        var width: CGFloat
    }
    private var mounted: [Mounted] = []
    private var scheduled = false

    init(environment: MarkdownHostedEnvironment) {
        self.environment = environment
    }

    var mountedCount: Int { mounted.count }

    func setNeedsLayout() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.layout()
        }
    }

    func removeAll() {
        for m in mounted { m.view.removeFromSuperview() }
        mounted.removeAll()
    }

    /// Mount / place widgets for the fragments around the viewport.
    func layout() {
        guard let tv = textView, let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
              let storage = tv.textStorage else { return }
        let visible = tv.visibleRect.height > 0 ? tv.visibleRect : tv.bounds
        let band = visible.insetBy(dx: 0, dy: -visible.height)
        let origin = tv.textContainerOrigin
        let padding = tv.textContainer?.lineFragmentPadding ?? 5
        let width = max(1, (tv.textContainer?.size.width ?? tv.bounds.width) - 2 * padding)
        var found: [(payload: MarkdownBlockAttachment.Payload, frame: CGRect, location: Int)] = []
        let top = CGPoint(x: 0, y: max(0, band.minY - origin.y))
        let start = tlm.textLayoutFragment(for: top)?.rangeInElement.location ?? tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let f = fragment.layoutFragmentFrame
            if f.minY + origin.y > band.maxY { return false }
            let loc = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
            guard loc < storage.length,
                  let box = storage.attribute(.lumiLiveWidget, at: loc, effectiveRange: nil) as? LiveWidgetBox,
                  let ps = storage.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
            else { return true }
            let y = f.minY + ps.paragraphSpacingBefore + 0.5
            let frame = CGRect(x: origin.x + padding, y: origin.y + y, width: width, height: box.height).integral
            found.append((box.payload, frame, loc))
            return true
        }

        var keep: [Mounted] = []
        var pool = mounted
        for item in found {
            if let i = pool.firstIndex(where: { $0.payload == item.payload }) {
                var m = pool.remove(at: i)
                if m.width != item.frame.width {
                    m.width = item.frame.width
                    m.view.host.rootView = content(item.payload, width: item.frame.width)
                }
                if m.view.frame != item.frame { m.view.frame = item.frame }
                m.view.sourceLocation = item.location
                keep.append(m)
            } else {
                let host = NSHostingView(rootView: content(item.payload, width: item.frame.width))
                host.sizingOptions = []
                let view = LiveWidgetHostView(host: host)
                view.frame = item.frame
                view.sourceLocation = item.location
                view.onActivate = { [weak self] loc in self?.onActivate(loc) }
                tv.addSubview(view)
                let natural = host.fittingSize.height
                if natural > 1, abs(natural - item.frame.height) > 0.5 { onHeight(item.payload, ceil(natural)) }
                keep.append(Mounted(payload: item.payload, view: view, width: item.frame.width))
            }
        }
        for m in pool { m.view.removeFromSuperview() }
        mounted = keep
    }

    private func content(_ payload: MarkdownBlockAttachment.Payload, width: CGFloat) -> MarkdownAttachmentContent {
        MarkdownAttachmentContent(payload: payload, width: width, environment: environment) { [weak self] h in
            guard h > 1, h.isFinite else { return }
            DispatchQueue.main.async { self?.onHeight(payload, ceil(h)) }
        }
    }
}

/// Wraps a hosted widget: it is not interactive itself (no copy button,
/// no text selection), a click moves the cursor into its source.
final class LiveWidgetHostView: NSView {
    let host: NSHostingView<MarkdownAttachmentContent>
    var sourceLocation = 0
    var onActivate: (Int) -> Void = { _ in }

    init(host: NSHostingView<MarkdownAttachmentContent>) {
        self.host = host
        super.init(frame: .zero)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not coded") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onActivate(sourceLocation)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
#endif
