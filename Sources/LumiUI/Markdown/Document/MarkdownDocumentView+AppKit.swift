#if canImport(AppKit)
import AppKit
import SwiftUI
import LumiKit

/// The read-mode document surface on macOS: one TextKit 2 `NSTextView`
/// rendering the whole note as a single attributed string.
///
/// Versus the old SwiftUI `LazyVStack` of per-block views this gives:
/// - selection (and ⌘C) across paragraphs, headings and lists;
/// - viewport-only layout: TextKit 2 lays out what's visible, attachment
///   views are mounted only near the viewport;
/// - no SwiftUI ↔ AppKit height feedback: text is measured by TextKit
///   itself; hosted attachment views report a fixed-width natural height
///   that cannot depend on the frame they're given;
/// - VoiceOver reads the note as one text area in document order.
final class MarkdownDocumentNSTextView: NSTextView {
    /// Reading column width; the text container is centred inside it.
    var readingWidth: CGFloat = 720 {
        didSet { if oldValue != readingWidth { updateInsets() } }
    }
    var onLayout: (() -> Void)?
    var onHoverLink: ((MarkdownLinkHit?) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var lastHoverRange: NSRange?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
        // TextKit 2 grows the document view's height as the viewport is
        // laid out (and on width reflow) — both move attachments.
        onLayout?()
    }

    func updateInsets() {
        let inset = NSSize(width: markdownHorizontalInset(viewWidth: bounds.width, readingWidth: readingWidth), height: 34)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    // MARK: Copy — attachments yield their markdown source

    override func copy(_ sender: Any?) {
        guard let storage = textStorage else { return super.copy(sender) }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= storage.length }
        guard !ranges.isEmpty else { return super.copy(sender) }
        let text = ranges.map { storage.lumiCopyText(in: $0) }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Link hit-testing + hover

    /// The link under `point` (view coordinates), verified against the
    /// link's actual glyph segments — the insertion index alone would
    /// also match points past the end of a line.
    func linkHit(at point: CGPoint) -> MarkdownLinkHit? {
        guard let storage = textStorage, storage.length > 0,
              let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager
        else { return nil }
        let index = characterIndexForInsertion(at: point)
        let origin = textContainerOrigin
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            var range = NSRange()
            guard let value = storage.attribute(.link, at: candidate, longestEffectiveRange: &range,
                                                in: NSRange(location: 0, length: storage.length)),
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { continue }
            var hit: CGRect?
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
                if rect.contains(point) {
                    hit = rect
                    return false
                }
                return true
            }
            if let hit { return MarkdownLinkHit(value: value, range: range, rect: hit) }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let hit = linkHit(at: convert(event.locationInWindow, from: nil))
        if hit?.range != lastHoverRange {
            lastHoverRange = hit?.range
            onHoverLink?(hit)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    func clearHover() {
        if lastHoverRange != nil {
            lastHoverRange = nil
            onHoverLink?(nil)
        }
    }
}

/// A hovered link: its `.link` value, character range and the glyph
/// segment rect under the cursor (text-view coordinates).
struct MarkdownLinkHit {
    let value: Any
    let range: NSRange
    let rect: CGRect
}

/// Owns the text stack for one read pane: renderer (diffing), layout
/// delegate (block chrome), attachment overlays, link routing and the
/// themed hover tooltip.
@MainActor
final class MarkdownDocumentController: NSObject, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: MarkdownDocumentNSTextView
    let renderer = MarkdownDocumentRenderer()
    private let layoutDelegate = MarkdownLayoutDelegate()
    let overlays: MarkdownAttachmentOverlays
    private var linkAction: MarkdownLinkAction = .systemDefault
    private var vaultRoot: URL?
    private var style: MarkdownRenderStyle?
    private weak var attachedSink: NSScrollView?
    private var tooltip: NSHostingView<AnyView>?
    private var pendingTooltip: DispatchWorkItem?
    private var hostedEnvKey: HostedEnvKey?

    private struct HostedEnvKey: Equatable {
        let style: MarkdownRenderStyle
        let vaultRoot: URL?
        let embedDepth: Int
    }

    override init() {
        scrollView = NSScrollView()
        textView = MarkdownDocumentNSTextView(usingTextLayoutManager: true)
        overlays = MarkdownAttachmentOverlays(environment: MarkdownHostedEnvironment(
            style: MarkdownRenderStyle(theme: LumiTheme.defaultDark.tokens),
            linkAction: .systemDefault, vaultRoot: nil, embedDepth: 0
        ))
        super.init()
        configureViews()
    }

    private func configureViews() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        // Keep the document origin at the real top of the pane (a unified
        // toolbar would otherwise auto-inset the clip view and hide the
        // title on first mount).
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let tv = textView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticLinkDetectionEnabled = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.delegate = self
        tv.textLayoutManager?.delegate = layoutDelegate
        tv.setAccessibilityLabel("Note")
        scrollView.documentView = tv

        overlays.container = tv
        overlays.layoutManager = tv.textLayoutManager
        overlays.containerOrigin = { [weak tv] in tv?.textContainerOrigin ?? .zero }
        overlays.visibleRect = { [weak tv] in tv?.visibleRect ?? .zero }
        overlays.relayout = { [weak self] in
            guard let self else { return }
            self.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            self.overlays.layout()
        }
        // Deferred: this fires inside NSTextView.layout(), and the overlay
        // pass forces TextKit layout for the visible rect.
        tv.onLayout = { [weak self] in self?.overlays.setNeedsLayout() }
        tv.onHoverLink = { [weak self] hit in self?.hoverChanged(hit) }

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        hideTooltip()
        overlays.layout()
    }

    // MARK: Update

    func update(
        header: MarkdownHeader?,
        document: MarkdownDocument,
        style newStyle: MarkdownRenderStyle,
        readingWidth: CGFloat,
        linkAction: MarkdownLinkAction,
        vaultRoot: URL?,
        embedDepth: Int
    ) {
        self.linkAction = linkAction
        self.vaultRoot = vaultRoot
        textView.readingWidth = readingWidth
        if style != newStyle {
            style = newStyle
            applyChrome(newStyle)
        }
        // Hosted views route links through `self`, so the (unequatable)
        // closure never forces a remount; only real inputs do.
        let envKey = HostedEnvKey(style: newStyle, vaultRoot: vaultRoot, embedDepth: embedDepth)
        if envKey != hostedEnvKey {
            hostedEnvKey = envKey
            overlays.environment = MarkdownHostedEnvironment(
                style: newStyle,
                linkAction: MarkdownLinkAction { [weak self] url in self?.linkAction.handle(url) ?? false },
                vaultRoot: vaultRoot,
                embedDepth: embedDepth
            )
        }
        guard let update = renderer.update(header: header, document: document, style: newStyle),
              let storage = textView.textStorage
        else { return }
        hideTooltip()
        textView.clearHover()
        let apply = {
            storage.replaceCharacters(in: update.range, with: update.replacement)
        }
        if let content = textView.textLayoutManager?.textContentManager {
            content.performEditingTransaction(apply)
        } else {
            apply()
        }
        overlays.retain(only: Self.liveAttachments(in: storage))
        textView.needsLayout = true
        // NSTextView (TextKit 2) doesn't reliably run `layout()` after an
        // edit, so schedule the overlay pass explicitly.
        overlays.setNeedsLayout()
    }

    private func applyChrome(_ style: MarkdownRenderStyle) {
        let palette = MarkdownPalette(style.theme)
        textView.linkTextAttributes = [
            .foregroundColor: palette.primary,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.selectedTextAttributes = [
            .backgroundColor: palette.primary.withAlphaComponent(0.28),
        ]
        hideTooltip()
    }

    static func liveAttachments(in storage: NSAttributedString) -> Set<ObjectIdentifier> {
        var live = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
            if let attachment = value as? MarkdownBlockAttachment { live.insert(ObjectIdentifier(attachment)) }
        }
        return live
    }

    func attachSink(_ sink: MarkdownScrollViewSink?) {
        guard let sink, attachedSink !== scrollView else { return }
        attachedSink = scrollView
        sink.attach(scrollView)
    }

    // MARK: Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        hideTooltip()
        let url: URL?
        switch link {
        case let direct as URL: url = direct
        case let string as String: url = URL(string: string)
        default: url = nil
        }
        guard let url else { return false }
        // false → NSTextView hands the URL to NSWorkspace (https, mailto…).
        return linkAction.handle(url)
    }

    func textView(_ view: NSTextView, willDisplayToolTip tooltip: String, forCharacterAt characterIndex: Int) -> String? {
        nil
    }

    // MARK: Tooltip

    private func hoverChanged(_ hit: MarkdownLinkHit?) {
        pendingTooltip?.cancel()
        pendingTooltip = nil
        guard let hit, let label = LinkTooltipLabel.label(for: hit.value, vaultRoot: vaultRoot) else {
            hideTooltip()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.showTooltip(label: label, linkRect: hit.rect)
        }
        pendingTooltip = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func showTooltip(label: String, linkRect: CGRect) {
        let theme = style?.theme ?? LumiTheme.defaultDark.tokens
        let root = AnyView(LinkTooltipBubble(label: label).environment(\.theme, theme).fixedSize())
        let host: NSHostingView<AnyView>
        if let tooltip {
            host = tooltip
            host.rootView = root
        } else {
            host = NSHostingView(rootView: root)
            host.sizingOptions = []
            tooltip = host
        }
        let size = host.fittingSize
        let inScroll = scrollView.convert(linkRect, from: textView)
        let bounds = scrollView.bounds
        let x = min(max(8, inScroll.minX), max(8, bounds.width - size.width - 8))
        // NSScrollView is not flipped: "below the link" is a smaller y.
        var y = inScroll.minY - 8 - size.height
        if y < 4 { y = inScroll.maxY + 8 }
        host.frame = CGRect(x: x, y: y, width: size.width, height: size.height).integral
        if host.superview !== scrollView {
            scrollView.addSubview(host, positioned: .above, relativeTo: nil)
        }
        host.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            host.animator().alphaValue = 1
        }
    }

    func hideTooltip() {
        pendingTooltip?.cancel()
        pendingTooltip = nil
        guard let tooltip, tooltip.superview != nil else { return }
        tooltip.removeFromSuperview()
    }
}

/// SwiftUI entry point for the macOS document surface.
struct MarkdownDocumentView: NSViewRepresentable {
    let header: MarkdownHeader?
    let document: MarkdownDocument
    let style: MarkdownRenderStyle
    let readingWidth: CGFloat
    @Environment(\.markdownLinkAction) private var linkAction
    @Environment(\.markdownVaultRoot) private var vaultRoot
    @Environment(\.markdownScrollViewSink) private var scrollSink
    @Environment(\.markdownEmbedDepth) private var embedDepth

    func makeCoordinator() -> MarkdownDocumentController { MarkdownDocumentController() }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        push(to: controller)
        return controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        push(to: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: MarkdownDocumentController) {
        coordinator.hideTooltip()
        coordinator.overlays.removeAll()
    }

    private func push(to controller: MarkdownDocumentController) {
        controller.update(
            header: header, document: document, style: style, readingWidth: readingWidth,
            linkAction: linkAction, vaultRoot: vaultRoot, embedDepth: embedDepth
        )
        controller.attachSink(scrollSink)
    }
}
#endif
