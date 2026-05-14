import Foundation
import Markdown

/// Parses a markdown source string into a `MarkdownDocument` of our own AST.
/// Wraps `swift-markdown` so the rest of the codebase doesn't depend on it
/// directly — this keeps the renderer tied to a stable internal shape.
public enum MarkdownParser {
    public static func parse(_ source: String, baseURL: URL? = nil) -> MarkdownDocument {
        let transformed = preprocessWikilinks(source)
        let document = Document(parsing: transformed)
        let blocks = document.children.compactMap { convertBlock($0, baseURL: baseURL) }
        return MarkdownDocument(blocks: blocks, baseURL: baseURL)
    }

    /// Rewrites Obsidian-style wikilinks into standard markdown so the
    /// upstream parser handles them without any custom AST node. Two forms
    /// are supported:
    ///
    ///   [[note-id]]            → [note-id](note-id.md)
    ///   [[note-id|Display]]    → [Display](note-id.md)
    ///   ![[note-id]]           → ![note-id](note-id.md)
    ///   ![[note-id|alt]]       → ![alt](note-id.md)
    ///
    /// The output uses bare `.md` filenames so they resolve relative to the
    /// active note's `baseURL` via `resolve(source:baseURL:)`. In-app
    /// navigation for `.md` taps is wired in `NoteDetailView.openMarkdownLink`.
    ///
    /// Code spans and fenced code blocks are skipped so a literal `[[id]]`
    /// inside backticks survives untouched.
    public static func preprocessWikilinks(_ source: String) -> String {
        var out = String()
        out.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var inFence = false
        var inBacktick = false
        var atLineStart = true

        while i < chars.count {
            let c = chars[i]

            // Fenced code blocks: ``` opens/closes at line start.
            if atLineStart && i + 2 < chars.count && c == "`" && chars[i + 1] == "`" && chars[i + 2] == "`" {
                inFence.toggle()
                out.append("```")
                i += 3
                atLineStart = false
                continue
            }
            if inFence {
                out.append(c)
                if c == "\n" { atLineStart = true } else { atLineStart = false }
                i += 1
                continue
            }

            // Inline code span: single backtick toggles.
            if c == "`" {
                inBacktick.toggle()
                out.append(c)
                i += 1
                atLineStart = false
                continue
            }
            if inBacktick {
                out.append(c)
                if c == "\n" { atLineStart = true } else { atLineStart = false }
                i += 1
                continue
            }

            // Embed form: `![[id]]` or `![[id|alt]]`.
            if c == "!" && i + 1 < chars.count && chars[i + 1] == "[" && i + 2 < chars.count && chars[i + 2] == "[" {
                if let end = findWikilinkClose(chars: chars, from: i + 3) {
                    let inner = String(chars[(i + 3)..<end])
                    let (target, label) = splitWikilink(inner)
                    out.append("![\(label ?? target)](\(target).md)")
                    i = end + 2
                    atLineStart = false
                    continue
                }
            }

            // Link form: `[[id]]` or `[[id|display]]`.
            if c == "[" && i + 1 < chars.count && chars[i + 1] == "[" {
                if let end = findWikilinkClose(chars: chars, from: i + 2) {
                    let inner = String(chars[(i + 2)..<end])
                    let (target, label) = splitWikilink(inner)
                    out.append("[\(label ?? target)](\(target).md)")
                    i = end + 2
                    atLineStart = false
                    continue
                }
            }

            out.append(c)
            atLineStart = (c == "\n")
            i += 1
        }
        return out
    }

    /// Find the closing `]]` for a wikilink that opens at `start`. Bails out
    /// on the next newline so malformed `[[ ... ` never spans paragraphs.
    private static func findWikilinkClose(chars: [Character], from start: Int) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "\n" { return nil }
            if chars[j] == "]" && chars[j + 1] == "]" { return j }
            j += 1
        }
        return nil
    }

    /// Splits `target|display` form. Returns `(target, display?)`. Trimmed.
    private static func splitWikilink(_ inner: String) -> (String, String?) {
        if let pipe = inner.firstIndex(of: "|") {
            let target = String(inner[..<pipe]).trimmingCharacters(in: .whitespaces)
            let display = String(inner[inner.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
            return (target, display.isEmpty ? nil : display)
        }
        return (inner.trimmingCharacters(in: .whitespaces), nil)
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
