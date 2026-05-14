import SwiftUI
import LumiKit

/// Walks `[InlineNode]` and produces an `AttributedString` ready to drop into
/// `Text`. SwiftUI handles tap-to-open for `.link` attributes natively, so
/// link click handling is free.
public enum InlineRenderer {
    public static func render(_ nodes: [InlineNode], theme: ThemeTokens) -> AttributedString {
        var out = AttributedString()
        for node in nodes {
            out += render(node: node, theme: theme)
        }
        return out
    }

    private static func render(node: InlineNode, theme: ThemeTokens) -> AttributedString {
        switch node {
        case let .text(s):
            return AttributedString(s)

        case let .strong(children):
            var attr = render(children, theme: theme)
            attr.inlinePresentationIntent = .stronglyEmphasized
            return attr

        case let .emphasis(children):
            var attr = render(children, theme: theme)
            attr.inlinePresentationIntent = .emphasized
            return attr

        case let .strikethrough(children):
            var attr = render(children, theme: theme)
            attr.inlinePresentationIntent = .strikethrough
            return attr

        case let .code(s):
            var attr = AttributedString(s)
            attr.inlinePresentationIntent = .code
            attr.backgroundColor = theme.overlayBackground
            attr.foregroundColor = theme.accent
            return attr

        case let .link(destination, children):
            var attr = render(children, theme: theme)
            attr.foregroundColor = theme.primary
            attr.underlineStyle = .single
            if let url = URL(string: destination) {
                attr.link = url
            }
            return attr

        case let .image(_, alt):
            // Inline images render as their alt text. Block images are lifted
            // to MarkdownBlock.media by the parser and handled separately.
            var attr = AttributedString(alt.isEmpty ? "[image]" : alt)
            attr.foregroundColor = theme.textDim
            return attr

        case let .math(latex, _):
            // Defensive fallback: a paragraph that *contains* `.math` is
            // routed by the renderer to `KaTeXParagraphView`, which never
            // calls this function. We still handle the case so the type
            // is total, in case a future path drops down to the native
            // Text renderer with math present. The output is the raw
            // LaTeX in code styling — readable, even if unrendered.
            var attr = AttributedString(latex)
            attr.inlinePresentationIntent = .code
            attr.foregroundColor = theme.accent
            attr.backgroundColor = theme.overlayBackground
            return attr

        case .lineBreak:
            return AttributedString("\n")

        case .softBreak:
            return AttributedString(" ")
        }
    }

    /// True iff the inline tree contains at least one `.math` node anywhere,
    /// including inside `.strong` / `.emphasis` / `.link` children.
    /// Drives the renderer's decision to swap the native Text path for the
    /// KaTeX paragraph WebView so math expressions line up on the baseline
    /// next to their prose.
    public static func containsMath(_ nodes: [InlineNode]) -> Bool {
        for node in nodes {
            switch node {
            case .math: return true
            case let .strong(children),
                 let .emphasis(children),
                 let .strikethrough(children):
                if containsMath(children) { return true }
            case let .link(_, children):
                if containsMath(children) { return true }
            case .text, .code, .image, .lineBreak, .softBreak:
                continue
            }
        }
        return false
    }

    /// True iff the inline tree contains at least one `.link` node anywhere.
    /// Drives the read-pane's pointing-hand cursor swap on macOS — SwiftUI
    /// Text doesn't change cursor for AttributedString `.link` attributes
    /// natively, so the renderer attaches an `.onHover` to whole-paragraph
    /// granularity when this is true.
    public static func containsLink(_ nodes: [InlineNode]) -> Bool {
        for node in nodes {
            switch node {
            case .link: return true
            case let .strong(children),
                 let .emphasis(children),
                 let .strikethrough(children):
                if containsLink(children) { return true }
            case .text, .code, .image, .math, .lineBreak, .softBreak:
                continue
            }
        }
        return false
    }
}
