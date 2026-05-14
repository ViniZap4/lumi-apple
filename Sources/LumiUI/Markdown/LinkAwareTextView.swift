import SwiftUI
import LumiKit

#if canImport(AppKit)
import AppKit

/// NSTextView-backed renderer for markdown paragraphs and headings that
/// contain at least one link. Same shape as before, with two refinements:
///
/// 1. **Cursor precision.** `linkTextAttributes[.cursor]` puts the
///    pointing-hand under link glyphs and the I-beam everywhere else,
///    which SwiftUI's Text path can't manage natively (the
///    `.textSelection(.enabled)` I-beam fought the `.onHover` cursor
///    swap and the two visually raced).
///
/// 2. **Themed hover tooltip.** AppKit's native tooltip is unstyled
///    (light-yellow popover, system font, decoded `file://` path) and
///    can't be themed. We disable it and ship a SwiftUI overlay that
///    matches the lumi theme: `theme.overlayBackground` fill,
///    `theme.border` outline, monospaced caption, drop shadow, and a
///    fade-in / scale animation when it appears. Link rects come from
///    the NSTextView's layout manager; SwiftUI's `.onContinuousHover`
///    in local coords picks the rect under the cursor, and a 350 ms
///    Task delay keeps micro-movements from popping the bubble.
public struct LinkAwareTextView: View {
    public let attributed: AttributedString
    public let fontSize: CGFloat
    public let fontWeight: NSFont.Weight
    public let lineSpacing: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.markdownLinkAction) private var linkAction
    @Environment(\.markdownVaultRoot) private var vaultRoot
    @State private var measuredHeight: CGFloat = 22
    /// Most recently computed per-line-fragment link rects, in local
    /// SwiftUI coordinates (which match the NSTextView's bounds since
    /// we frame them 1:1). Published from the Representable via the
    /// `onLinkRects` callback below.
    @State private var linkRects: [LinkRect] = []
    /// Active hover, set when the cursor sits on a link rect for at
    /// least `tooltipDelay`. Nil means no tooltip rendered.
    @State private var hover: LinkHover? = nil
    /// In-flight task that turns a hovered rect into a visible tooltip
    /// after the delay. Cancelled on every cursor move so flicks across
    /// links don't queue a backlog of bubbles.
    @State private var pendingShow: Task<Void, Never>? = nil

    public init(
        attributed: AttributedString,
        fontSize: CGFloat,
        fontWeight: NSFont.Weight = .regular,
        lineSpacing: CGFloat = 3
    ) {
        self.attributed = attributed
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.lineSpacing = lineSpacing
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            LinkAwareNSTextViewRepresentable(
                attributed: attributed,
                fontSize: fontSize,
                fontWeight: fontWeight,
                lineSpacing: lineSpacing,
                theme: theme,
                linkAction: linkAction,
                vaultRoot: vaultRoot,
                onHeight: { h in
                    if h > 1, abs(h - measuredHeight) > 0.5 {
                        measuredHeight = h
                    }
                },
                onLinkRects: { rects in
                    if rects != linkRects {
                        linkRects = rects
                    }
                },
                // Hover events come from the NSTextView's own
                // NSTrackingArea (added in SelfSizingTextView). SwiftUI's
                // `.onContinuousHover` doesn't fire reliably here because
                // NSTextView consumes mouseMoved events for its own
                // selection/cursor handling, so we route from AppKit
                // directly instead.
                onHoverLink: { rect in
                    handleHoverChange(to: rect)
                }
            )

            if let hover {
                LinkTooltipBubble(label: hover.label)
                    // Anchor the bubble's top-leading corner just below
                    // the link's left edge via `.offset`. We avoid
                    // `.position(x:y:)` here because position anchors
                    // by the bubble's *center* — which requires knowing
                    // the bubble's height up-front so a multi-line
                    // wrap doesn't shift it visually.
                    .offset(
                        x: max(0, min(max(0, measuredWidth - tooltipMaxWidth), hover.anchor.minX)),
                        y: hover.anchor.maxY + 8
                    )
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.94, anchor: .topLeading))
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(height: measuredHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WidthReporter(width: $measuredWidth))
        // Tell SwiftUI where our first text baseline sits so a parent
        // `HStack(alignment: .firstTextBaseline)` — notably
        // `ListBlockView`'s row layout — aligns its marker glyph with
        // our first line.
        .alignmentGuide(.firstTextBaseline) { _ in
            firstLineBaselineFromTop
        }
        .animation(.easeOut(duration: 0.16), value: hover)
    }

    /// Approximate position of the first-line baseline below the top
    /// edge of the rendered text. NSFont reports `ascender` in points
    /// for the current weight + size combination — that's the cap-to-
    /// baseline distance SwiftUI's HStack expects.
    private var firstLineBaselineFromTop: CGFloat {
        NSFont.systemFont(ofSize: fontSize, weight: fontWeight).ascender
    }

    /// Upper bound on the tooltip's width. The bubble shrinks
    /// horizontally when the path is short; for long paths it wraps
    /// inside this cap instead of shooting past the column. Exposed
    /// as a static so `LinkTooltipBubble` can pin its `.frame
    /// (maxWidth:)` to the same value.
    fileprivate static let tooltipMaxWidth: CGFloat = 360
    private var tooltipMaxWidth: CGFloat { Self.tooltipMaxWidth }

    @State private var measuredWidth: CGFloat = 0

    /// Translate AppKit hover events (delivered from the NSTextView's
    /// tracking area) into the SwiftUI bubble's show / hide state.
    /// Same delay + animation envelope as the prior onContinuousHover
    /// path — only the event source changed.
    private func handleHoverChange(to rect: LinkRect?) {
        if let rect {
            if hover?.id == rect.id { return }
            pendingShow?.cancel()
            pendingShow = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 280_000_000) // ~280 ms
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    hover = LinkHover(id: rect.id, label: rect.label, anchor: rect.rect)
                }
            }
        } else {
            pendingShow?.cancel()
            pendingShow = nil
            if hover != nil {
                withAnimation(.easeOut(duration: 0.10)) { hover = nil }
            }
        }
    }
}

/// One link's hit rect + display label, in SwiftUI local coordinates.
/// `id` is the byte range start so quick wiggles within the same link
/// don't restart the tooltip delay.
public struct LinkRect: Hashable, Sendable {
    public let id: Int
    public let rect: CGRect
    public let label: String
}

private struct LinkHover: Hashable {
    let id: Int
    let label: String
    let anchor: CGRect
}

/// The styled bubble itself. Matches the rest of the app: themed
/// background, monospaced caption text, thin border, soft drop
/// shadow. `.fixedSize()` lets the bubble grow to its content's
/// width up to a sane cap and wrap to multiple lines when the path
/// is deep.
private struct LinkTooltipBubble: View {
    let label: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(theme.text)
            // Wrap onto multiple lines (up to four) so long paths read
            // properly instead of getting middle-truncated. The
            // `.fixedSize(horizontal: false, vertical: true)` plus the
            // outer `maxWidth: tooltipMaxWidth` cap lets the bubble
            // shrink horizontally to the path's natural width when it
            // fits on one line, and wrap when it doesn't.
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                // Two-layer background gives the bubble a real "card"
                // feel that reads on every theme:
                //   1. Solid `theme.background` underlay so the bubble
                //      is fully opaque even when the page content is
                //      using `theme.overlayBackground`.
                //   2. A faint `theme.accent` tint over it for a hint
                //      of theme colour without competing with the
                //      label text.
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.background)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accent.opacity(0.07))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.accent.opacity(0.40), lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(0.42), radius: 14, x: 0, y: 5)
            .frame(maxWidth: LinkAwareTextView.tooltipMaxWidth, alignment: .leading)
    }
}

/// Background reporter that publishes the host view's width through a
/// PreferenceKey. We use it to clamp the tooltip's centre so a hover at
/// the left or right edge of a paragraph doesn't shoot the bubble out
/// of frame.
private struct WidthReporter: View {
    @Binding var width: CGFloat
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: WidthPreferenceKey.self, value: proxy.size.width)
        }
        .onPreferenceChange(WidthPreferenceKey.self) { width = $0 }
    }
}

private struct WidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct LinkAwareNSTextViewRepresentable: NSViewRepresentable {
    let attributed: AttributedString
    let fontSize: CGFloat
    let fontWeight: NSFont.Weight
    let lineSpacing: CGFloat
    let theme: ThemeTokens
    let linkAction: MarkdownLinkAction
    let vaultRoot: URL?
    let onHeight: (CGFloat) -> Void
    let onLinkRects: ([LinkRect]) -> Void
    let onHoverLink: (LinkRect?) -> Void

    func makeNSView(context: Context) -> SelfSizingTextView {
        let textView = SelfSizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.linkRectsProvider = context.coordinator
        textView.onHeightChange = { h in
            // Hop to main async so we don't mutate SwiftUI state from
            // inside the layout pass that triggered the height update.
            DispatchQueue.main.async { onHeight(h) }
        }
        textView.onHoverLink = { rect in
            DispatchQueue.main.async { onHoverLink(rect) }
        }
        applyAttributes(to: textView, context: context)
        return textView
    }

    func updateNSView(_ nsView: SelfSizingTextView, context: Context) {
        context.coordinator.linkAction = linkAction
        context.coordinator.vaultRoot = vaultRoot
        context.coordinator.onLinkRects = onLinkRects
        nsView.onHoverLink = { rect in
            DispatchQueue.main.async { onHoverLink(rect) }
        }
        applyAttributes(to: nsView, context: context)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(linkAction: linkAction, vaultRoot: vaultRoot, onLinkRects: onLinkRects)
    }

    private func applyAttributes(to textView: SelfSizingTextView, context: Context) {
        let ns = NSMutableAttributedString(attributed)
        let full = NSRange(location: 0, length: ns.length)

        let font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        ns.addAttribute(.font, value: font, range: full)
        ns.addAttribute(.foregroundColor, value: NSColor(theme.text), range: full)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping
        ns.addAttribute(.paragraphStyle, value: paragraphStyle, range: full)

        textView.linkTextAttributes = [
            .foregroundColor: NSColor(theme.primary),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        textView.textStorage?.setAttributedString(ns)
        textView.refreshLinkRects(coordinator: context.coordinator)
        textView.scheduleHeightReport()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, LinkRectsProvider {
        var linkAction: MarkdownLinkAction
        var vaultRoot: URL?
        var onLinkRects: ([LinkRect]) -> Void

        init(linkAction: MarkdownLinkAction, vaultRoot: URL?, onLinkRects: @escaping ([LinkRect]) -> Void) {
            self.linkAction = linkAction
            self.vaultRoot = vaultRoot
            self.onLinkRects = onLinkRects
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = resolveURL(link)
            guard let url else { return false }
            return MainActor.assumeIsolated {
                linkAction.handle(url)
            }
        }

        // Suppress NSTextView's default link tooltip — we render our
        // own SwiftUI overlay instead.
        func textView(_ textView: NSTextView, willDisplayToolTip tooltip: String, forCharacterAt characterIndex: Int) -> String? {
            nil
        }

        func publish(_ rects: [LinkRect]) {
            // NSTextView layout always runs on the main thread, so the
            // SwiftUI @State mutation that follows is safe — we just
            // need to satisfy Swift 6 strict concurrency about where
            // `onLinkRects` is invoked from. `MainActor.assumeIsolated`
            // is the contract: "I promise we're already on the main
            // actor", and AppKit guarantees that here.
            MainActor.assumeIsolated {
                onLinkRects(rects)
            }
        }

        /// Resolve a link URL into a display label for the hover
        /// tooltip. In-vault `file://*.md` URLs become vault-relative
        /// paths (`./subfolder/note.md`); local files outside the
        /// vault collapse to `~/`-prefixed paths; external URLs
        /// surface as their `absoluteString`. We accept both `URL` and
        /// `String` forms because `URL(string:)` of a path containing
        /// unencoded chars returns nil in modern Foundation — in that
        /// case we fall back to treating the string as a path.
        func tooltipLabel(for raw: Any) -> String? {
            if let url = raw as? URL {
                return tooltipLabel(forURL: url, fallback: url.absoluteString)
            }
            if let str = raw as? String {
                if let url = URL(string: str) {
                    return tooltipLabel(forURL: url, fallback: str)
                }
                return prettifyPath(str)
            }
            return nil
        }

        private func tooltipLabel(forURL url: URL, fallback: String) -> String {
            let scheme = url.scheme?.lowercased() ?? ""
            // Treat both `URL.isFileURL` and explicit `file://` strings
            // as file URLs. The Foundation API drifts between them
            // depending on how the URL was constructed (file:// strings
            // parsed via `URL(string:)` may report isFileURL=false on
            // some toolchains).
            let isFile = url.isFileURL || scheme == "file"
            if isFile {
                return prettifyPath(url.path.isEmpty ? fallback : url.path)
            }
            if scheme.isEmpty {
                return prettifyPath(fallback)
            }
            return url.absoluteString
        }

        /// Collapse vault root → `./`, home → `~/`. Idempotent on
        /// already-prettified inputs.
        private func prettifyPath(_ raw: String) -> String {
            var path = raw
            if path.hasPrefix("file://") {
                path = String(path.dropFirst("file://".count))
                if let decoded = path.removingPercentEncoding { path = decoded }
            }
            if let vaultRoot {
                let vaultPath = vaultRoot.standardizedFileURL.path
                let prefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"
                if path == vaultPath {
                    return "./"
                }
                if path.hasPrefix(prefix) {
                    return "./" + String(path.dropFirst(prefix.count))
                }
            }
            let home = NSHomeDirectory()
            if path.hasPrefix(home + "/") {
                return "~/" + String(path.dropFirst(home.count + 1))
            }
            return path
        }
    }
}

private func resolveURL(_ link: Any) -> URL? {
    switch link {
    case let direct as URL: return direct
    case let str as String: return URL(string: str)
    default: return nil
    }
}

/// Protocol the NSTextView calls back to when it has freshly-laid-out
/// link rects. Decoupled so the view doesn't need to know about
/// SwiftUI state. Annotated `@MainActor` because AppKit views live on
/// the main thread and the SwiftUI side that consumes the rects does
/// too — keeping the protocol main-actor-isolated lets the Coordinator
/// conform without Swift 6 sending-self diagnostics.
@MainActor
protocol LinkRectsProvider: AnyObject {
    func publish(_ rects: [LinkRect])
    func tooltipLabel(for raw: Any) -> String?
}

/// NSTextView subclass that:
///   - reports its laid-out height back via a closure
///   - publishes per-line-fragment link rects with display labels
///   - emits mouseMoved-driven hover events for the SwiftUI tooltip,
///     because the SwiftUI .onContinuousHover modifier on a parent
///     view doesn't fire when the NSTextView itself is consuming
///     mouseMoved for its own selection / I-beam handling.
final class SelfSizingTextView: NSTextView {
    var onHeightChange: ((CGFloat) -> Void)?
    var onHoverLink: ((LinkRect?) -> Void)?
    weak var linkRectsProvider: LinkRectsProvider?
    private var lastReported: CGFloat = -1
    private var lastPublishedRects: [LinkRect] = []
    private var hoverTrackingArea: NSTrackingArea?
    private var lastHoveredLinkID: Int? = nil

    override func layout() {
        super.layout()
        scheduleHeightReport()
        // Layout geometry changed (window resize, font load reflow,
        // wrap break) — re-emit the link rects so the SwiftUI tooltip
        // tracks the new positions.
        if let provider = linkRectsProvider {
            refreshLinkRects(coordinator: provider)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        // `.inVisibleRect` makes the area auto-resize with the view
        // (no need to recompute on bounds change). `.activeInKeyWindow`
        // restricts firing to the focused window so unfocused notes
        // don't burn cycles on hover dispatch. `.mouseMoved` plus
        // `.mouseEnteredAndExited` give us continuous + boundary
        // events, which we coalesce into a single hover-changed
        // callback.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let hit = lastPublishedRects.first(where: { $0.rect.contains(local) })
        if hit?.id != lastHoveredLinkID {
            lastHoveredLinkID = hit?.id
            onHoverLink?(hit)
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if lastHoveredLinkID != nil {
            lastHoveredLinkID = nil
            onHoverLink?(nil)
        }
        super.mouseExited(with: event)
    }

    func scheduleHeightReport() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let h = ceil(used.height) + textContainerInset.height * 2
        if h > 0, abs(h - lastReported) > 0.5 {
            lastReported = h
            onHeightChange?(h)
        }
    }

    /// Walk the text storage, find every `.link` attribute run, compute
    /// its bounding rect in view coordinates, and hand the list to the
    /// SwiftUI side via the coordinator. The SwiftUI host's
    /// `.onContinuousHover` then knows which link the cursor is over
    /// and renders the themed tooltip — no AppKit popover involved.
    func refreshLinkRects(coordinator: LinkRectsProvider) {
        guard let storage = textStorage,
              let layoutManager,
              let textContainer
        else { return }

        layoutManager.ensureLayout(for: textContainer)
        var rects: [LinkRect] = []
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            guard let value, let label = coordinator.tooltipLabel(for: value) else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, _ in
                let used = lineGlyphRange.intersection(glyphRange) ?? lineGlyphRange
                guard used.length > 0 else { return }
                let rect = layoutManager.boundingRect(forGlyphRange: used, in: textContainer)
                let inset = self.textContainerInset
                let viewRect = CGRect(
                    x: rect.origin.x + inset.width,
                    y: rect.origin.y + inset.height,
                    width: rect.width,
                    height: rect.height
                )
                rects.append(LinkRect(id: range.location, rect: viewRect, label: label))
            }
        }
        if rects != lastPublishedRects {
            lastPublishedRects = rects
            coordinator.publish(rects)
            // Re-evaluate the current hover against the new rects —
            // a reflow can move a link out from under the cursor.
            if let lastHoveredLinkID,
               !rects.contains(where: { $0.id == lastHoveredLinkID }) {
                self.lastHoveredLinkID = nil
                onHoverLink?(nil)
            }
        }
    }
}
#endif
