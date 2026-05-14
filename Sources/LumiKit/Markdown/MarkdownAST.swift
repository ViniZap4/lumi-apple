import Foundation

/// Block-level element of a parsed markdown document. Lossy by design — only
/// the constructs the renderer cares about are represented; everything else
/// is ignored. Add cases as new constructs are needed.
public indirect enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, inline: [InlineNode])
    case paragraph(inline: [InlineNode])
    case codeBlock(language: String?, code: String)
    case blockQuote(blocks: [MarkdownBlock])
    case unorderedList(items: [ListItemContent])
    case orderedList(start: Int, items: [ListItemContent])
    case thematicBreak
    case media(MediaReference)
    /// Display-style LaTeX: a paragraph whose entire content was a single
    /// `$$ … $$` expression. Rendered as a centered KaTeX block by the
    /// renderer; the host paragraph is dropped.
    case mathBlock(latex: String)
}

/// One row of an `unorderedList` / `orderedList`. The `checkbox` field is
/// `nil` for regular bullets and `.unchecked` / `.checked` for GitHub-style
/// task list items (`- [ ]` / `- [x]`) — those swap the bullet marker for
/// a tinted check glyph in the renderer.
public struct ListItemContent: Sendable, Hashable {
    public let checkbox: ListItemCheckbox?
    public let blocks: [MarkdownBlock]

    public init(checkbox: ListItemCheckbox?, blocks: [MarkdownBlock]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

public enum ListItemCheckbox: Sendable, Hashable {
    case unchecked
    case checked
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
    /// LaTeX math expression extracted from `$ … $` (inline) or `$$ … $$`
    /// (display). The `display` flag tells the renderer whether to ask
    /// KaTeX for inline or display-mode layout. A paragraph that is
    /// nothing but a single `.math(display: .block)` gets lifted to
    /// `MarkdownBlock.mathBlock` by the parser; everything else stays
    /// inline and the surrounding paragraph renders via a single
    /// paragraph-level KaTeX WebView so neighbouring text + math line
    /// up on the same baseline.
    case math(latex: String, display: MathDisplay)
    case lineBreak
    case softBreak
}

/// Inline vs. display math, mirroring KaTeX's `displayMode` flag.
public enum MathDisplay: Sendable, Hashable {
    case inline  // $ … $
    case block   // $$ … $$
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
