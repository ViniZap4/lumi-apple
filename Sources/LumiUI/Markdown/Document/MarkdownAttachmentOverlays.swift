import SwiftUI
import LumiKit

#if canImport(AppKit)
import AppKit
typealias MarkdownPlatformView = NSView
#else
import UIKit
typealias MarkdownPlatformView = UIView
#endif

/// Attachment `(object, rect)` pairs laid out inside `rect` (text
/// container coordinates). Forces layout for that rect only, so cost is
/// proportional to what is on screen, not to the note length.
@MainActor
func markdownAttachments(in layoutManager: NSTextLayoutManager, rect: CGRect) -> [(MarkdownBlockAttachment, CGRect)] {
    guard let contentManager = layoutManager.textContentManager else { return [] }
    layoutManager.ensureLayout(for: rect)
    let start = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, rect.minY)))?.rangeInElement.location
        ?? layoutManager.documentRange.location
    var out: [(MarkdownBlockAttachment, CGRect)] = []
    layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
        let frame = fragment.layoutFragmentFrame
        if frame.minY > rect.maxY { return false }
        guard let paragraph = fragment.textElement as? NSTextParagraph else { return true }
        let text = paragraph.attributedString
        guard text.length > 0 else { return true }
        let base = fragment.rangeInElement.location
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            guard let attachment = value as? MarkdownBlockAttachment,
                  let location = contentManager.location(base, offsetBy: range.location)
            else { return }
            let local = fragment.frameForTextAttachment(at: location)
            guard local.width > 0, local.height > 0 else { return }
            out.append((attachment, local.offsetBy(dx: frame.minX, dy: frame.minY)))
        }
        return true
    }
    return out
}

/// Mounts the real SwiftUI views (KaTeX, Mermaid, media) over the
/// rectangles reserved by `MarkdownBlockAttachment`s — only for
/// attachments within about a screen of the viewport. This is what makes
/// the read pane genuinely lazy: a note with 200 diagrams creates web
/// views for the handful you can see, not for all 200.
@MainActor
final class MarkdownAttachmentOverlays {
    #if canImport(AppKit)
    private typealias Host = NSHostingView<MarkdownAttachmentContent>
    #else
    private typealias Host = UIHostingController<MarkdownAttachmentContent>
    #endif

    private struct Mounted {
        let attachment: MarkdownBlockAttachment
        let host: Host
        var width: CGFloat
        var view: MarkdownPlatformView {
            #if canImport(AppKit)
            host
            #else
            host.view
            #endif
        }
    }

    weak var container: MarkdownPlatformView?
    weak var layoutManager: NSTextLayoutManager?
    /// Text-container origin in `container` coordinates.
    var containerOrigin: () -> CGPoint = { .zero }
    /// Visible rect in `container` coordinates.
    var visibleRect: () -> CGRect = { .zero }
    /// Called (coalesced, next run-loop turn) after attachment heights
    /// changed and layout was invalidated, so the host can re-run viewport
    /// layout and then `layout()` again.
    var relayout: () -> Void = {}

    var environment: MarkdownHostedEnvironment {
        didSet { environmentGeneration &+= 1 }
    }

    private var mounted: [ObjectIdentifier: Mounted] = [:]
    private var environmentGeneration = 0
    private var mountedGeneration: [ObjectIdentifier: Int] = [:]
    private var invalidationScheduled = false

    init(environment: MarkdownHostedEnvironment) {
        self.environment = environment
    }

    var mountedCount: Int { mounted.count }

    private var layoutScheduled = false

    /// Request a `layout()` on the next run-loop turn (coalesced). Used
    /// from inside the text view's own layout pass, where forcing TextKit
    /// layout re-entrantly could recurse.
    func setNeedsLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutScheduled = false
            self.layout()
        }
    }

    /// Position / mount / unmount hosted views for the current viewport.
    func layout() {
        guard let container, let layoutManager else { return }
        let visible = visibleRect()
        guard visible.height > 0 else { return }
        let origin = containerOrigin()
        // Mount a screen above and below so views exist before they
        // scroll in; keep (but don't reposition) views up to three
        // screens away so scrolling back and forth doesn't thrash web
        // views; drop anything beyond.
        let mountRect = visible.insetBy(dx: 0, dy: -visible.height)
        let keepRect = visible.insetBy(dx: 0, dy: -3 * visible.height)
        let containerRect = mountRect.offsetBy(dx: -origin.x, dy: -origin.y)

        var seen = Set<ObjectIdentifier>()
        var heightsChanged = false
        for (attachment, rect) in markdownAttachments(in: layoutManager, rect: containerRect) {
            let key = ObjectIdentifier(attachment)
            seen.insert(key)
            let frame = CGRect(
                x: rect.minX + origin.x,
                y: rect.minY + origin.y,
                width: rect.width,
                height: attachment.height
            ).integral
            if var entry = mounted[key] {
                if entry.width != frame.width || mountedGeneration[key] != environmentGeneration {
                    entry.width = frame.width
                    update(entry.host, attachment: attachment, width: frame.width)
                    mounted[key] = entry
                    mountedGeneration[key] = environmentGeneration
                }
                if entry.view.frame != frame { entry.view.frame = frame }
            } else {
                let host = makeHost(attachment: attachment, width: frame.width)
                let entry = Mounted(attachment: attachment, host: host, width: frame.width)
                mounted[key] = entry
                mountedGeneration[key] = environmentGeneration
                entry.view.frame = frame
                container.addSubview(entry.view)
                // Synchronous first measurement: SwiftUI lays the root out
                // right here, so content with a known size lands at its
                // real height on the very first pass.
                if record(height: measure(host, width: frame.width), for: attachment, width: frame.width) {
                    entry.view.frame.size.height = attachment.height
                    heightsChanged = true
                }
            }
        }

        for (key, entry) in mounted where !seen.contains(key) {
            // Not in the mount band: either scrolled far away or removed
            // from the document. Anything still inside the keep band but
            // unseen is a removed attachment (a live one would have been
            // enumerated), so it goes too.
            if !entry.view.frame.intersects(keepRect) || entry.view.frame.intersects(mountRect) {
                unmount(key)
            }
        }
        if heightsChanged { scheduleInvalidation() }
    }

    /// Mounted hosted views with their frames (container coordinates):
    /// hint mode labels the code blocks' copy buttons from these.
    var mountedViews: [(attachment: MarkdownBlockAttachment, frame: CGRect)] {
        mounted.values.map { ($0.attachment, $0.view.frame) }
    }

    /// Drop hosts whose attachment is no longer in the document.
    func retain(only live: Set<ObjectIdentifier>) {
        for key in mounted.keys where !live.contains(key) { unmount(key) }
    }

    func removeAll() {
        for key in Array(mounted.keys) { unmount(key) }
    }

    private func unmount(_ key: ObjectIdentifier) {
        guard let entry = mounted.removeValue(forKey: key) else { return }
        mountedGeneration.removeValue(forKey: key)
        entry.view.removeFromSuperview()
    }

    // MARK: Heights

    /// Returns true if the attachment's height changed.
    @discardableResult
    private func record(height: CGFloat, for attachment: MarkdownBlockAttachment, width: CGFloat) -> Bool {
        guard height > 1, height.isFinite else { return false }
        let rounded = ceil(height)
        MarkdownAttachmentHeightCache.store(rounded, for: attachment.payload, width: width, scale: environment.style.scale)
        guard abs(rounded - attachment.height) > 0.5 else { return false }
        attachment.height = rounded
        return true
    }

    private func reported(height: CGFloat, for attachment: MarkdownBlockAttachment) {
        guard let entry = mounted[ObjectIdentifier(attachment)] else { return }
        if record(height: height, for: attachment, width: entry.width) {
            scheduleInvalidation()
        }
    }

    /// Coalesce every height change in this turn into one layout
    /// invalidation on the next turn. Deferred because reports arrive
    /// from inside SwiftUI's layout of the hosted view; touching TextKit
    /// layout re-entrantly from there is how the old renderer looped.
    private func scheduleInvalidation() {
        guard !invalidationScheduled else { return }
        invalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidationScheduled = false
            guard let layoutManager = self.layoutManager else { return }
            let range = layoutManager.textViewportLayoutController.viewportRange ?? layoutManager.documentRange
            layoutManager.invalidateLayout(for: range)
            self.relayout()
        }
    }

    // MARK: Hosting

    private func rootView(attachment: MarkdownBlockAttachment, width: CGFloat) -> MarkdownAttachmentContent {
        MarkdownAttachmentContent(
            payload: attachment.payload,
            width: width,
            environment: environment,
            onHeight: { [weak self, weak attachment] height in
                guard let self, let attachment else { return }
                self.reported(height: height, for: attachment)
            }
        )
    }

    private func makeHost(attachment: MarkdownBlockAttachment, width: CGFloat) -> Host {
        #if canImport(AppKit)
        let host = NSHostingView(rootView: rootView(attachment: attachment, width: width))
        host.sizingOptions = []
        host.setAccessibilityLabel(attachment.spokenText)
        return host
        #else
        let host = UIHostingController(rootView: rootView(attachment: attachment, width: width))
        host.sizingOptions = []
        host.view.backgroundColor = .clear
        host.view.accessibilityLabel = attachment.spokenText
        return host
        #endif
    }

    private func update(_ host: Host, attachment: MarkdownBlockAttachment, width: CGFloat) {
        host.rootView = rootView(attachment: attachment, width: width)
    }

    private func measure(_ host: Host, width: CGFloat) -> CGFloat {
        #if canImport(AppKit)
        return host.fittingSize.height
        #else
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        #endif
    }
}

/// Horizontal text inset that centres a `readingWidth` column, matching
/// the old `.frame(maxWidth: readingWidth).padding(.horizontal, 48)`.
func markdownHorizontalInset(viewWidth: CGFloat, readingWidth: CGFloat) -> CGFloat {
    // Phone 16, narrow pane / iPad portrait 28, wide 48 (space pass).
    let gutter: CGFloat = viewWidth < 520 ? 16 : viewWidth < 900 ? 28 : 48
    let column = min(viewWidth, max(readingWidth, 2 * gutter + 1))
    return max(gutter, (viewWidth - column) / 2 + gutter)
}
