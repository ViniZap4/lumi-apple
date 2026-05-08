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

        case .lineBreak:
            return AttributedString("\n")

        case .softBreak:
            return AttributedString(" ")
        }
    }
}
