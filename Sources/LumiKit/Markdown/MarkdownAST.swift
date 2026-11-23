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
    /// GFM pipe table.
    case table(MarkdownTable)
    /// Obsidian-style callout: a blockquote opening with `[!kind]`
    /// (`[!kind]+` / `[!kind]-` make it foldable, open / closed).
    case callout(MarkdownCallout)
    /// Footnote definitions, collected from the whole note and rendered
    /// once at the end (`[^id]: text`).
    case footnotes([MarkdownFootnote])
}

/// Column alignment of a table (`:--`, `:-:`, `--:`).
public enum MarkdownTableAlignment: Sendable, Hashable {
    case none, left, center, right
}

public struct MarkdownTable: Sendable, Hashable {
    public var alignments: [MarkdownTableAlignment]
    public var header: [[InlineNode]]
    public var rows: [[[InlineNode]]]

    public init(alignments: [MarkdownTableAlignment], header: [[InlineNode]], rows: [[[InlineNode]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }
}

public struct MarkdownCallout: Sendable, Hashable {
    public enum Fold: Sendable, Hashable { case none, open, closed }
    /// Canonical kind: note, abstract, info, todo, tip, success,
    /// question, warning, danger, example, quote (aliases resolved).
    public var kind: String
    /// Kind as written (lowercased) — the default title.
    public var rawKind: String
    /// Inline title; empty → the capitalised raw kind.
    public var title: [InlineNode]
    public var fold: Fold
    public var blocks: [MarkdownBlock]

    public init(kind: String, rawKind: String, title: [InlineNode], fold: Fold, blocks: [MarkdownBlock]) {
        self.kind = kind
        self.rawKind = rawKind
        self.title = title
        self.fold = fold
        self.blocks = blocks
    }

    public static let kinds: Set<String> = [
        "note", "abstract", "info", "todo", "tip", "success", "question", "warning", "danger", "example", "quote",
    ]
    public static let aliases: [String: String] = [
        "summary": "abstract", "tldr": "abstract", "hint": "tip", "important": "tip", "check": "success",
        "done": "success", "help": "question", "faq": "question", "caution": "warning", "attention": "warning",
        "fail": "danger", "failure": "danger", "missing": "danger", "error": "danger", "bug": "danger", "cite": "quote",
    ]

    /// `NOTE`, `tldr`, `Bug` → canonical kind (unknown kinds render as note).
    public static func canonicalKind(_ raw: String) -> String {
        let k = raw.lowercased()
        if let alias = aliases[k] { return alias }
        return kinds.contains(k) ? k : "note"
    }
}

public struct MarkdownFootnote: Sendable, Hashable {
    public var id: String
    public var number: Int
    public var inline: [InlineNode]

    public init(id: String, number: Int, inline: [InlineNode]) {
        self.id = id
        self.number = number
        self.inline = inline
    }
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
    /// `==highlight==`.
    case mark([InlineNode])
    /// `<kbd>…</kbd>`.
    case kbd(String)
    /// `[^id]` with a definition: rendered as its number, linking to the
    /// footnote list.
    case footnoteRef(id: String, number: Int)
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
    /// `![alt](src "title")`: shown as the figure caption.
    public let title: String?

    public init(url: URL, alt: String, kind: MediaKind, title: String? = nil) {
        self.url = url
        self.alt = alt
        self.kind = kind
        self.title = title
    }
}

/// Parsed document plus the base URL its media references resolve against.
public struct MarkdownDocument: Sendable, Hashable {
    public let blocks: [MarkdownBlock]
    public let baseURL: URL?
    /// 0-based source line each top-level block starts at (index-aligned
    /// with `blocks`; empty when unknown). Drives the split preview's
    /// scroll sync. Kept out of the blocks so an edit that shifts lines
    /// doesn't invalidate every cached block below it.
    public let sourceLines: [Int]
    /// Number of source lines.
    public let lineCount: Int

    public init(blocks: [MarkdownBlock], baseURL: URL? = nil, sourceLines: [Int] = [], lineCount: Int = 0) {
        self.blocks = blocks
        self.baseURL = baseURL
        self.sourceLines = sourceLines
        self.lineCount = lineCount
    }
}
