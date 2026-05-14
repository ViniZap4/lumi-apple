import SwiftUI
import LumiKit

#if canImport(AppKit)
import AppKit

/// NSTextView-backed renderer for markdown paragraphs and headings that
/// contain at least one link. We use it instead of SwiftUI's `Text` for
/// two reasons:
///
/// 1. **Cursor precision.** SwiftUI's `Text(...).textSelection(.enabled)`
///    forces the I-beam over the entire text glyph run on macOS, which
///    fights any `.onHover` cursor swap a parent installs — the
///    pointing-hand we tried to set in F.40 came and went as the system
///    re-asserted I-beam. NSTextView handles this natively via
///    `linkTextAttributes[.cursor]`: pointing-hand over link characters,
///    I-beam over surrounding text.
///
/// 2. **Click latency.** Links inside a SwiftUI Text route through
///    SwiftUI's `OpenURLAction` chain (async, env-walked). NSTextView's
///    `textView(_:clickedOnLink:at:)` delegate callback is synchronous
///    and lands in the same runloop pass as the click event itself, so
///    in-app note navigation feels immediate.
///
/// Sizing follows the same self-measuring pattern `KaTeXParagraphView`
/// uses: NSTextView lays out into its container, reports the used
/// height back via a closure, the SwiftUI host snaps to it. The width
/// is constrained by `.frame(maxWidth: .infinity)` and a per-update
/// container resize.
public struct LinkAwareTextView: View {
    public let attributed: AttributedString
    public let fontSize: CGFloat
    public let fontWeight: NSFont.Weight
    public let lineSpacing: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.markdownLinkAction) private var linkAction
    @Environment(\.markdownVaultRoot) private var vaultRoot
    @State private var measuredHeight: CGFloat = 22

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
            }
        )
        .frame(height: measuredHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        textView.tooltipProvider = context.coordinator
        textView.onHeightChange = { h in
            // Hop to main async so we don't mutate SwiftUI state from
            // inside the layout pass that triggered the height update.
            DispatchQueue.main.async { onHeight(h) }
        }
        applyAttributes(to: textView, context: context)
        return textView
    }

    func updateNSView(_ nsView: SelfSizingTextView, context: Context) {
        context.coordinator.linkAction = linkAction
        context.coordinator.vaultRoot = vaultRoot
        applyAttributes(to: nsView, context: context)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(linkAction: linkAction, vaultRoot: vaultRoot)
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
        textView.refreshLinkTooltips(coordinator: context.coordinator)
        textView.scheduleHeightReport()
    }

    final class Coordinator: NSObject, NSTextViewDelegate, LinkTooltipProvider {
        var linkAction: MarkdownLinkAction
        var vaultRoot: URL?
        /// Most-recently-computed per-link rect → tooltip string map.
        /// Refreshed every time `refreshLinkTooltips` runs (after each
        /// attribute pass). Used to answer `view(_:stringForToolTip:point:userData:)`.
        var linkTooltipRects: [(rect: NSRect, label: String)] = []

        init(linkAction: MarkdownLinkAction, vaultRoot: URL?) {
            self.linkAction = linkAction
            self.vaultRoot = vaultRoot
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            switch link {
            case let direct as URL: url = direct
            case let str as String: url = URL(string: str)
            default: url = nil
            }
            guard let url else { return false }
            return MainActor.assumeIsolated {
                linkAction.handle(url)
            }
        }

        // MARK: - Tooltip

        func tooltipString(for point: NSPoint) -> String? {
            for entry in linkTooltipRects where entry.rect.contains(point) {
                return entry.label
            }
            return nil
        }

        /// Resolve a link URL into a display label for the hover
        /// tooltip. In-vault `file://*.md` URLs become vault-relative
        /// paths (`./subfolder/note.md`); external URLs surface as
        /// their `absoluteString`; everything else falls back to
        /// `path`.
        func tooltipLabel(for url: URL) -> String {
            if url.isFileURL {
                if let vaultRoot {
                    let vaultPath = vaultRoot.standardizedFileURL.path
                    let urlPath = url.standardizedFileURL.path
                    let prefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"
                    if urlPath == vaultPath {
                        return "./"
                    }
                    if urlPath.hasPrefix(prefix) {
                        return "./" + String(urlPath.dropFirst(prefix.count))
                    }
                }
                let home = NSHomeDirectory()
                if url.path.hasPrefix(home + "/") {
                    return "~/" + String(url.path.dropFirst(home.count + 1))
                }
                return url.path
            }
            return url.absoluteString
        }
    }
}

/// Protocol the NSTextView calls when AppKit asks for tooltip text.
/// Decoupled so the text view's tooltip lookup doesn't need to know
/// about SwiftUI types or the coordinator's storage shape.
protocol LinkTooltipProvider: AnyObject {
    func tooltipString(for point: NSPoint) -> String?
    func tooltipLabel(for url: URL) -> String
}

/// NSTextView subclass that reports its laid-out height back via a
/// closure. The closure fires on every layout pass that produces a
/// different used-rect height — the SwiftUI host uses that to size
/// itself, so the text view never shows blank padding at the bottom
/// or clips its last line.
final class SelfSizingTextView: NSTextView {
    var onHeightChange: ((CGFloat) -> Void)?
    weak var tooltipProvider: LinkTooltipProvider?
    private var lastReported: CGFloat = -1

    override func layout() {
        super.layout()
        scheduleHeightReport()
        // Tooltip rects depend on layout geometry — re-register them
        // every time AppKit re-runs the layout pass so window-resize
        // and font-load reflows keep the hover targets aligned with
        // the visible link glyphs.
        if let provider = tooltipProvider as? AnyObject as? LinkAwareNSTextViewRepresentable.Coordinator {
            refreshLinkTooltips(coordinator: provider)
        }
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
    /// its bounding rect in view coordinates, and register an AppKit
    /// tooltip rect for it. The tooltip body resolves at hover time via
    /// the coordinator's `tooltipString(for:)` — that way the rect can
    /// move (re-layout) without re-registering the strings.
    fileprivate func refreshLinkTooltips(coordinator: LinkAwareNSTextViewRepresentable.Coordinator) {
        removeAllToolTips()
        coordinator.linkTooltipRects.removeAll(keepingCapacity: true)
        guard let storage = textStorage,
              let layoutManager,
              let textContainer
        else { return }

        layoutManager.ensureLayout(for: textContainer)
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            let url: URL?
            switch value {
            case let direct as URL: url = direct
            case let str as String: url = URL(string: str)
            default: url = nil
            }
            guard let url else { return }
            let label = coordinator.tooltipLabel(for: url)
            // A single link can span multiple line fragments inside a
            // wrapping paragraph; enumerate fragments so each visual
            // chunk gets its own tooltip rect.
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, _ in
                let used = lineGlyphRange.intersection(glyphRange) ?? lineGlyphRange
                guard used.length > 0 else { return }
                let rect = layoutManager.boundingRect(forGlyphRange: used, in: textContainer)
                let inset = self.textContainerInset
                let viewRect = NSRect(
                    x: rect.origin.x + inset.width,
                    y: rect.origin.y + inset.height,
                    width: rect.width,
                    height: rect.height
                )
                coordinator.linkTooltipRects.append((rect: viewRect, label: label))
                self.addToolTip(viewRect, owner: self, userData: nil)
            }
        }
    }

    /// AppKit calls this whenever the cursor sits on a registered
    /// tooltip rect for the system delay (~0.5 s). Returning a string
    /// shows the native tooltip popover, which fades in/out via
    /// AppKit's standard animation. The method comes from
    /// `NSToolTipOwner` (a Foundation protocol), not from NSView's own
    /// surface — so we implement it without `override`.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        tooltipProvider?.tooltipString(for: point) ?? ""
    }
}
#endif
