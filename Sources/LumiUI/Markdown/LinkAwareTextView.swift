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
        textView.onHeightChange = { h in
            // Hop to main async so we don't mutate SwiftUI state from
            // inside the layout pass that triggered the height update.
            DispatchQueue.main.async { onHeight(h) }
        }
        applyAttributes(to: textView)
        return textView
    }

    func updateNSView(_ nsView: SelfSizingTextView, context: Context) {
        context.coordinator.linkAction = linkAction
        applyAttributes(to: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(linkAction: linkAction)
    }

    private func applyAttributes(to textView: SelfSizingTextView) {
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
        textView.scheduleHeightReport()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var linkAction: MarkdownLinkAction
        init(linkAction: MarkdownLinkAction) {
            self.linkAction = linkAction
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            switch link {
            case let direct as URL: url = direct
            case let str as String: url = URL(string: str)
            default: url = nil
            }
            guard let url else { return false }
            // Synchronous: the SwiftUI side mutates AppState on this
            // exact frame, so the read-pane swap feels immediate.
            return MainActor.assumeIsolated {
                linkAction.handle(url)
            }
        }
    }
}

/// NSTextView subclass that reports its laid-out height back via a
/// closure. The closure fires on every layout pass that produces a
/// different used-rect height — the SwiftUI host uses that to size
/// itself, so the text view never shows blank padding at the bottom
/// or clips its last line.
final class SelfSizingTextView: NSTextView {
    var onHeightChange: ((CGFloat) -> Void)?
    private var lastReported: CGFloat = -1

    override func layout() {
        super.layout()
        scheduleHeightReport()
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
}
#endif
