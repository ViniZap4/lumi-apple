import Foundation
import Markdown

/// Parses a markdown source string into a `MarkdownDocument` of our own AST.
/// Wraps `swift-markdown` so the rest of the codebase doesn't depend on it
/// directly — this keeps the renderer tied to a stable internal shape.
public enum MarkdownParser {
    public static func parse(_ source: String, baseURL: URL? = nil) -> MarkdownDocument {
        let document = Document(parsing: source)
        let blocks = document.children.compactMap { convertBlock($0, baseURL: baseURL) }
        return MarkdownDocument(blocks: blocks, baseURL: baseURL)
    }

    private static func convertBlock(_ markup: any Markup, baseURL: URL?) -> MarkdownBlock? {
        if let p = markup as? Paragraph, let media = blockMedia(from: p, baseURL: baseURL) {
            return .media(media)
        }

        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, inline: convertInline(heading.children, baseURL: baseURL))

        case let paragraph as Paragraph:
            return .paragraph(inline: convertInline(paragraph.children, baseURL: baseURL))

        case let codeBlock as CodeBlock:
            return .codeBlock(language: codeBlock.language, code: codeBlock.code)

        case let blockQuote as BlockQuote:
            return .blockQuote(blocks: blockQuote.children.compactMap { convertBlock($0, baseURL: baseURL) })

        case let list as UnorderedList:
            return .unorderedList(items: list.listItems.map { item in
                item.children.compactMap { convertBlock($0, baseURL: baseURL) }
            })

        case let list as OrderedList:
            let start = Int(list.startIndex)
            return .orderedList(
                start: start,
                items: list.listItems.map { item in
                    item.children.compactMap { convertBlock($0, baseURL: baseURL) }
                }
            )

        case is ThematicBreak:
            return .thematicBreak

        default:
            return nil
        }
    }

    private static func blockMedia(from paragraph: Paragraph, baseURL: URL?) -> MediaReference? {
        let visualChildren = paragraph.children.filter { !($0 is SoftBreak) && !($0 is LineBreak) }
        guard visualChildren.count == 1, let image = visualChildren.first as? Markdown.Image,
              let source = image.source else {
            return nil
        }
        let alt = image.plainText
        guard let url = resolve(source: source, baseURL: baseURL) else { return nil }
        let kind = MediaKind.detect(url: url)
        return MediaReference(url: url, alt: alt, kind: kind)
    }

    private static func convertInline(_ markups: MarkupChildren, baseURL: URL?) -> [InlineNode] {
        markups.compactMap { convertInlineNode($0, baseURL: baseURL) }
    }

    private static func convertInline(_ markups: [any Markup], baseURL: URL?) -> [InlineNode] {
        markups.compactMap { convertInlineNode($0, baseURL: baseURL) }
    }

    private static func convertInlineNode(_ markup: any Markup, baseURL: URL?) -> InlineNode? {
        switch markup {
        case let text as Markdown.Text:
            return .text(text.string)
        case let strong as Strong:
            return .strong(convertInline(strong.children, baseURL: baseURL))
        case let emph as Emphasis:
            return .emphasis(convertInline(emph.children, baseURL: baseURL))
        case let strike as Strikethrough:
            return .strikethrough(convertInline(strike.children, baseURL: baseURL))
        case let code as InlineCode:
            return .code(code.code)
        case let link as Link:
            let raw = link.destination ?? ""
            // Resolve at parse time so the renderer doesn't need
            // baseURL plumbing. Relative paths like `./README.md`
            // become full file URLs; absolute URLs pass through.
            let resolved = resolve(source: raw, baseURL: baseURL)?.absoluteString ?? raw
            return .link(
                destination: resolved,
                children: convertInline(link.children, baseURL: baseURL)
            )
        case let image as Markdown.Image:
            let rawSource = image.source ?? ""
            let resolvedSource = resolve(source: rawSource, baseURL: baseURL)?.absoluteString ?? rawSource
            return .image(source: resolvedSource, alt: image.plainText)
        case is LineBreak:
            return .lineBreak
        case is SoftBreak:
            return .softBreak
        default:
            return nil
        }
    }

    /// Resolve a markdown link/image target against the document's base URL.
    /// Absolute URLs (with scheme) are returned as-is; bare paths become file
    /// URLs relative to the base.
    public static func resolve(source: String, baseURL: URL?) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = URL(string: trimmed), direct.scheme != nil {
            return direct
        }
        guard let baseURL else { return URL(string: trimmed) }
        return URL(fileURLWithPath: trimmed, relativeTo: baseURL).standardized
    }
}

private extension Markdown.Image {
    var plainText: String {
        var text = ""
        for child in children {
            if let t = child as? Markdown.Text {
                text += t.string
            }
        }
        return text
    }
}
