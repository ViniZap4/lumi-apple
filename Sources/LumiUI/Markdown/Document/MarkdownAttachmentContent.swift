import SwiftUI
import LumiKit

/// Environment a hosted attachment view needs. A platform hosting view
/// is a fresh SwiftUI root — it inherits *nothing* from the surrounding
/// tree — so every value the leaf views read is passed explicitly. This
/// is the fix for the old read pane rendering light themes with the
/// default dark tokens.
struct MarkdownHostedEnvironment {
    var style: MarkdownRenderStyle
    var linkAction: MarkdownLinkAction
    var vaultRoot: URL?
    var embedDepth: Int
}

/// SwiftUI root mounted on top of a `MarkdownBlockAttachment`. Laid out
/// at a fixed width with its natural (ideal) height; that height is
/// reported through `onHeight` and never depends on the frame the host
/// gives back, so the measurement cannot oscillate.
struct MarkdownAttachmentContent: View {
    let payload: MarkdownBlockAttachment.Payload
    let width: CGFloat
    let environment: MarkdownHostedEnvironment
    let onHeight: (CGFloat) -> Void

    var body: some View {
        content
            .frame(width: max(1, width), alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onHeight(height)
            }
            .frame(width: max(1, width), alignment: .topLeading)
            .environment(\.theme, environment.style.theme)
            .environment(\.markdownScale, environment.style.scale)
            .environment(\.markdownFontFamily, environment.style.fontFamily)
            .environment(\.markdownStagger, false)
            .environment(\.markdownLite, false)
            .environment(\.markdownVaultRoot, environment.vaultRoot)
            .environment(\.markdownEmbedDepth, environment.embedDepth)
            .environment(\.markdownLinkAction, environment.linkAction)
            .environment(\.markdownAttachmentWidth, width)
            .environment(\.openURL, OpenURLAction { [linkAction = environment.linkAction] url in
                linkAction.handle(url) ? .handled : .systemAction
            })
    }

    @ViewBuilder
    private var content: some View {
        switch payload {
        case let .mathBlock(latex):
            KaTeXBlockView(latex: latex)
        case let .mathParagraph(inline):
            KaTeXParagraphView(inline: inline)
        case let .mathHeading(inline, level):
            KaTeXHeadingView(inline: inline, level: level)
        case let .mermaid(code):
            MermaidView(code: code)
        case let .media(reference):
            MediaView(reference: reference)
        case let .code(language, code):
            MarkdownCodeBlockView(language: language, code: code)
        case let .table(table):
            MarkdownTableView(table: table)
        }
    }
}
