import Foundation

/// Block-level element of a parsed markdown document. Lossy by design — only
/// the constructs the renderer cares about are represented; everything else
/// is ignored. Add cases as new constructs are needed.
public indirect enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, inline: [InlineNode])
    case paragraph(inline: [InlineNode])
    case codeBlock(language: String?, code: String)
    case blockQuote(blocks: [MarkdownBlock])
    case unorderedList(items: [[MarkdownBlock]])
    case orderedList(start: Int, items: [[MarkdownBlock]])
    case thematicBreak
    case media(MediaReference)
}

/// Inline-level element. Strings carry through verbatim; styles and links wrap
/// child runs.
public indirect enum InlineNode: Sendable, Hashable {
    case text(String)
    case strong([InlineNode])
    case emphasis([InlineNode])
    case strikethrough([InlineNode])
    case code(String)
    case link(destination: String, children: [InlineNode])
    case image(source: String, alt: String)
    case lineBreak
    case softBreak
}

/// A media reference resolved to an absolute URL with detected kind. Block
/// media (paragraphs that are nothing but a single `![alt](src)`) are pulled
/// up to top-level `MarkdownBlock.media` cases.
public struct MediaReference: Sendable, Hashable {
    public let url: URL
    public let alt: String
    public let kind: MediaKind

    public init(url: URL, alt: String, kind: MediaKind) {
        self.url = url
        self.alt = alt
        self.kind = kind
    }
}

/// Parsed document plus the base URL its media references resolve against.
public struct MarkdownDocument: Sendable, Hashable {
    public let blocks: [MarkdownBlock]
    public let baseURL: URL?

    public init(blocks: [MarkdownBlock], baseURL: URL? = nil) {
        self.blocks = blocks
        self.baseURL = baseURL
    }
}
