import Foundation
import Markdown

/// Parses a markdown source string into a `MarkdownDocument` of our own AST.
/// Wraps `swift-markdown` so the rest of the codebase doesn't depend on it
/// directly — this keeps the renderer tied to a stable internal shape.
public enum MarkdownParser {
    public static func parse(_ source: String, baseURL: URL? = nil) -> MarkdownDocument {
        // Math first, wikilinks second. Math extraction replaces `$$ … $$`
        // and `$ … $` with sentinel tokens so swift-markdown's escape
        // handling (which would eat `\;`, `\,`, etc.) doesn't touch the
        // LaTeX source. The wikilink pass runs on the already-tokenised
        // text — math tokens are inert there.
        let mathExtraction = extractMath(source)
        let withWikilinks = preprocessWikilinks(mathExtraction.transformed)
        let document = Document(parsing: withWikilinks)
        let context = ParseContext(math: mathExtraction.expressions, baseURL: baseURL)
        var blocks = document.children.compactMap { convertBlock($0, context: context) }
        // Lift any paragraph whose only meaningful content is a single
        // display-mode math expression into a top-level `.mathBlock` so
        // the renderer can center + size it as a separate block.
        blocks = liftDisplayMathParagraphs(blocks)
        return MarkdownDocument(blocks: blocks, baseURL: baseURL)
    }

    /// Carries everything the recursive AST conversion needs that isn't
    /// already on the swift-markdown nodes. Keeping it in one struct
    /// means the convertBlock / convertInline call surface doesn't grow
    /// each time a new pre-processing pass lands.
    fileprivate struct ParseContext {
        let math: [String: MathExpression]
        let baseURL: URL?
    }

    /// One math expression extracted from the source. The token (a
    /// private-use Unicode sequence) gets injected into the source where
    /// the original `$ … $` / `$$ … $$` stood, and survives swift-markdown's
    /// inline processing untouched so we can resubstitute later.
    fileprivate struct MathExpression {
        let latex: String
        let display: MathDisplay
    }

    fileprivate struct MathExtraction {
        let transformed: String
        let expressions: [String: MathExpression]
    }

    /// Walks the source and lifts every math span (`$ … $` and `$$ … $$`)
    /// into a private-use-region token. The mapping `token → (latex, display)`
    /// is handed to the AST post-processor.
    ///
    /// Skips fenced code blocks (```), inline code spans (`...`), and
    /// backslash-escaped `\$` so literal dollar signs survive in prose.
    /// Newlines inside `$$ … $$` are allowed (display math often spans
    /// multiple lines); a `$ … $` span must close on the same paragraph
    /// to be recognised — anything else stays as plain text.
    fileprivate static func extractMath(_ source: String) -> MathExtraction {
        let chars = Array(source)
        var out = String()
        out.reserveCapacity(source.count)
        var expressions: [String: MathExpression] = [:]
        var nextIndex = 0
        var i = 0
        var inFence = false
        var inBacktick = false
        var atLineStart = true

        while i < chars.count {
            let c = chars[i]

            // ``` fences pass through verbatim.
            if atLineStart && i + 2 < chars.count && c == "`" && chars[i + 1] == "`" && chars[i + 2] == "`" {
                inFence.toggle()
                out.append("```")
                i += 3
                atLineStart = false
                continue
            }
            if inFence {
                out.append(c)
                atLineStart = (c == "\n")
                i += 1
                continue
            }

            // Inline code span: `…` stays untouched.
            if c == "`" {
                inBacktick.toggle()
                out.append(c)
                i += 1
                atLineStart = false
                continue
            }
            if inBacktick {
                out.append(c)
                atLineStart = (c == "\n")
                i += 1
                continue
            }

            // Backslash escape: `\$` is a literal dollar; copy both chars
            // unchanged so swift-markdown still sees the escape.
            if c == "\\" && i + 1 < chars.count {
                out.append(c)
                out.append(chars[i + 1])
                let advanced = chars[i + 1] == "\n"
                atLineStart = advanced
                i += 2
                continue
            }

            // Block math: `$$ … $$`. Newlines allowed inside.
            if c == "$" && i + 1 < chars.count && chars[i + 1] == "$" {
                if let endStart = findClosing(chars, from: i + 2, delim: .block) {
                    let latex = String(chars[(i + 2)..<endStart])
                    let token = makeToken(&nextIndex)
                    expressions[token] = MathExpression(latex: latex, display: .block)
                    out.append(token)
                    i = endStart + 2
                    atLineStart = false
                    continue
                }
            }

            // Inline math: `$ … $`. No newlines inside; no empty body.
            if c == "$" {
                if let endStart = findClosing(chars, from: i + 1, delim: .inline) {
                    let latex = String(chars[(i + 1)..<endStart])
                    if !latex.trimmingCharacters(in: .whitespaces).isEmpty {
                        let token = makeToken(&nextIndex)
                        expressions[token] = MathExpression(latex: latex, display: .inline)
                        out.append(token)
                        i = endStart + 1
                        atLineStart = false
                        continue
                    }
                }
            }

            out.append(c)
            atLineStart = (c == "\n")
            i += 1
        }
        return MathExtraction(transformed: out, expressions: expressions)
    }

    private enum MathDelimiter { case inline, block }

    /// Scan forward from `from` looking for the closing math delimiter.
    /// Honours `\$` escapes and short-circuits at code spans / fences so
    /// `$ … `weird` … $` doesn't form a math span that crosses a code
    /// boundary. For inline math, a newline aborts the search (a `$`
    /// hanging on a line by itself shouldn't eat the rest of the doc).
    private static func findClosing(_ chars: [Character], from start: Int, delim: MathDelimiter) -> Int? {
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                i += 2
                continue
            }
            switch delim {
            case .inline:
                if c == "\n" { return nil }
                if c == "$" { return i }
            case .block:
                if c == "$" && i + 1 < chars.count && chars[i + 1] == "$" { return i }
            }
            i += 1
        }
        return nil
    }

    /// Make a unique sentinel token using the Unicode private-use area so
    /// no plausible source text would collide. The leading/trailing
    /// markers are also private-use chars to keep the run easy to find
    /// on the post-parse pass.
    private static func makeToken(_ counter: inout Int) -> String {
        let idx = counter
        counter += 1
        return "\u{E000}m\(idx)\u{E001}"
    }

    /// Pattern that matches a single math token. Cached so the AST walk
    /// doesn't recompile the regex per text node.
    private static let mathTokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\u{E000}m([0-9]+)\u{E001}", options: [])
    }()

    /// Walks a text string for math sentinels and splits it into a
    /// sequence of `.text` and `.math` inline nodes. Each surviving text
    /// region keeps its original whitespace; empty runs are skipped so
    /// the AST stays compact.
    private static func splitMathTokens(_ s: String, expressions: [String: MathExpression]) -> [InlineNode] {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = mathTokenRegex.matches(in: s, options: [], range: range)
        if matches.isEmpty {
            return s.isEmpty ? [] : [.text(s)]
        }
        var out: [InlineNode] = []
        var cursor = 0
        for m in matches {
            let r = m.range
            if r.location > cursor {
                let head = ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                if !head.isEmpty { out.append(.text(head)) }
            }
            let token = ns.substring(with: r)
            if let expr = expressions[token] {
                out.append(.math(latex: expr.latex, display: expr.display))
            } else {
                // Unknown token — emit raw so the user sees the placeholder
                // rather than silently dropping a region.
                out.append(.text(token))
            }
            cursor = r.location + r.length
        }
        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            if !tail.isEmpty { out.append(.text(tail)) }
        }
        return out
    }

    /// Lift any paragraph whose visible content is a single display-mode
    /// math expression (optionally surrounded by whitespace text or soft
    /// breaks) up to a top-level `.mathBlock`. Other paragraphs — incl.
    /// those with inline math next to prose — stay as paragraphs and the
    /// renderer dispatches them to the paragraph-level KaTeX WebView.
    private static func liftDisplayMathParagraphs(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        blocks.map { liftDisplayMath(in: $0) }
    }

    private static func liftDisplayMath(in block: MarkdownBlock) -> MarkdownBlock {
        switch block {
        case let .paragraph(inline):
            if let latex = soleDisplayMath(in: inline) {
                return .mathBlock(latex: latex)
            }
            return .paragraph(inline: inline)
        case let .blockQuote(children):
            return .blockQuote(blocks: children.map { liftDisplayMath(in: $0) })
        case let .unorderedList(items):
            return .unorderedList(items: items.map { itemBlocks in
                itemBlocks.map { liftDisplayMath(in: $0) }
            })
        case let .orderedList(start, items):
            return .orderedList(start: start, items: items.map { itemBlocks in
                itemBlocks.map { liftDisplayMath(in: $0) }
            })
        default:
            return block
        }
    }

    /// Returns the LaTeX of a paragraph whose only visible content is a
    /// single `.math(display: .block)` (whitespace-only text nodes / line
    /// breaks on either side are allowed). Otherwise nil.
    private static func soleDisplayMath(in inline: [InlineNode]) -> String? {
        var found: String?
        for node in inline {
            switch node {
            case .lineBreak, .softBreak:
                continue
            case let .text(s) where s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                continue
            case let .math(latex, .block):
                if found != nil { return nil }
                found = latex
            default:
                return nil
            }
        }
        return found
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

    private static func convertBlock(_ markup: any Markup, context: ParseContext) -> MarkdownBlock? {
        if let p = markup as? Paragraph, let media = blockMedia(from: p, baseURL: context.baseURL) {
            return .media(media)
        }

        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, inline: convertInline(heading.children, context: context))

        case let paragraph as Paragraph:
            return .paragraph(inline: convertInline(paragraph.children, context: context))

        case let codeBlock as CodeBlock:
            return .codeBlock(language: codeBlock.language, code: codeBlock.code)

        case let blockQuote as BlockQuote:
            return .blockQuote(blocks: blockQuote.children.compactMap { convertBlock($0, context: context) })

        case let list as UnorderedList:
            return .unorderedList(items: list.listItems.map { item in
                item.children.compactMap { convertBlock($0, context: context) }
            })

        case let list as OrderedList:
            let start = Int(list.startIndex)
            return .orderedList(
                start: start,
                items: list.listItems.map { item in
                    item.children.compactMap { convertBlock($0, context: context) }
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

    private static func convertInline(_ markups: MarkupChildren, context: ParseContext) -> [InlineNode] {
        markups.flatMap { convertInlineNode($0, context: context) }
    }

    private static func convertInline(_ markups: [any Markup], context: ParseContext) -> [InlineNode] {
        markups.flatMap { convertInlineNode($0, context: context) }
    }

    /// Returns 0+ nodes for the input. Most cases pass through 1-for-1;
    /// `.text` may explode into multiple nodes when math sentinels split
    /// it. Returning `[InlineNode]` instead of `InlineNode?` removes the
    /// need for a callee-side flatten loop everywhere else.
    private static func convertInlineNode(_ markup: any Markup, context: ParseContext) -> [InlineNode] {
        switch markup {
        case let text as Markdown.Text:
            return splitMathTokens(text.string, expressions: context.math)
        case let strong as Strong:
            return [.strong(convertInline(strong.children, context: context))]
        case let emph as Emphasis:
            return [.emphasis(convertInline(emph.children, context: context))]
        case let strike as Strikethrough:
            return [.strikethrough(convertInline(strike.children, context: context))]
        case let code as InlineCode:
            return [.code(code.code)]
        case let link as Link:
            let raw = link.destination ?? ""
            // Resolve at parse time so the renderer doesn't need
            // baseURL plumbing. Relative paths like `./README.md`
            // become full file URLs; absolute URLs pass through.
            let resolved = resolve(source: raw, baseURL: context.baseURL)?.absoluteString ?? raw
            return [.link(
                destination: resolved,
                children: convertInline(link.children, context: context)
            )]
        case let image as Markdown.Image:
            let rawSource = image.source ?? ""
            let resolvedSource = resolve(source: rawSource, baseURL: context.baseURL)?.absoluteString ?? rawSource
            return [.image(source: resolvedSource, alt: image.plainText)]
        case is LineBreak:
            return [.lineBreak]
        case is SoftBreak:
            return [.softBreak]
        default:
            return []
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
