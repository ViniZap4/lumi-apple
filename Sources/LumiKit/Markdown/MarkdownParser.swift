import Foundation
import Markdown

/// Parses a markdown source string into a `MarkdownDocument` of our own AST.
/// Wraps `swift-markdown` so the rest of the codebase doesn't depend on it
/// directly — this keeps the renderer tied to a stable internal shape.
public enum MarkdownParser {
    public static func parse(_ source: String, baseURL: URL? = nil) -> MarkdownDocument {
        let normalized = source.contains("\r") ? source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : source
        // Footnotes and callout markers are line-level and keep the line
        // count. Math, footnote refs and `==mark==` are lifted next into
        // private-use tokens so swift-markdown's escape handling never
        // touches them (and records which output line came from which
        // source line — `$$ … $$` spans collapse lines). The wikilink
        // pass runs on the tokenised text; tokens are inert there.
        let footnotes = scanFootnotes(normalized)
        let callouts = markCallouts(footnotes.source)
        let extraction = extractInline(callouts.source, footnoteIDs: Set(footnotes.order))
        let withWikilinks = preprocessWikilinks(extraction.transformed)
        let document = Document(parsing: withWikilinks)
        let context = ParseContext(
            math: extraction.expressions,
            baseURL: baseURL,
            footnotes: extraction.footnoteRefs,
            footnoteNumbers: Dictionary(uniqueKeysWithValues: footnotes.order.enumerated().map { ($1, $0 + 1) }),
            callouts: callouts.markers
        )
        var blocks: [MarkdownBlock] = []
        var lines: [Int] = []
        for child in document.children {
            guard let block = convertBlock(child, context: context) else { continue }
            blocks.append(liftDisplayMath(in: block))
            let outLine = max(0, (child.range?.lowerBound.line ?? 1) - 1)
            lines.append(outLine < extraction.lineMap.count ? extraction.lineMap[outLine] : (extraction.lineMap.last ?? 0))
        }
        let lineCount = normalized.reduce(into: 1) { n, c in if c == "\n" { n += 1 } }
        if !footnotes.order.isEmpty {
            let items: [MarkdownFootnote] = footnotes.order.enumerated().compactMap { i, id in
                guard let def = footnotes.defs[id] else { return nil }
                let inline: [InlineNode]
                if case let .paragraph(nodes)? = MarkdownParser.parse(def.text, baseURL: baseURL).blocks.first {
                    inline = nodes
                } else {
                    inline = [.text(def.text)]
                }
                return MarkdownFootnote(id: id, number: i + 1, inline: inline)
            }
            if !items.isEmpty {
                blocks.append(.footnotes(items))
                let first = footnotes.order.compactMap { footnotes.defs[$0]?.line }.min() ?? 0
                lines.append(max(first, lines.last ?? 0))
            }
        }
        return MarkdownDocument(blocks: blocks, baseURL: baseURL, sourceLines: lines, lineCount: lineCount)
    }

    // MARK: - Footnotes

    struct FootnoteScan {
        /// Source with definition lines blanked (line count unchanged).
        var source: String
        var defs: [String: (text: String, line: Int)]
        /// Referenced ids that have a definition, in first-reference order.
        var order: [String]
    }

    private static let footnoteDef = try! NSRegularExpression(pattern: "^\\[\\^([^\\]\\s]+)\\]:[ \\t]+(.*)$")
    private static let footnoteRef = try! NSRegularExpression(pattern: "\\[\\^([^\\]\\s]+)\\](?!:)")

    static func scanFootnotes(_ src: String) -> FootnoteScan {
        guard src.contains("[^") else { return FootnoteScan(source: src, defs: [:], order: []) }
        var lines = src.components(separatedBy: "\n")
        let code = MarkdownTasks.codeLines(lines)
        var defs: [String: (text: String, line: Int)] = [:]
        var order: [String] = []
        for i in lines.indices where !code[i] {
            let ns = lines[i] as NSString
            if let m = footnoteDef.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)) {
                let id = ns.substring(with: m.range(at: 1))
                if defs[id] == nil { defs[id] = (ns.substring(with: m.range(at: 2)), i) }
                lines[i] = ""
                continue
            }
            for m in footnoteRef.matches(in: lines[i], range: NSRange(location: 0, length: ns.length)) {
                let id = ns.substring(with: m.range(at: 1))
                if !order.contains(id) { order.append(id) }
            }
        }
        return FootnoteScan(
            source: defs.isEmpty ? src : lines.joined(separator: "\n"),
            defs: defs,
            order: order.filter { defs[$0] != nil }
        )
    }

    // MARK: - Callouts

    struct CalloutMarker: Hashable {
        var rawKind: String
        var fold: MarkdownCallout.Fold
    }

    private static let calloutLine = try! NSRegularExpression(pattern: "^([ ]{0,3}(?:>[ \\t]?)+)[ \\t]*\\[!([A-Za-z][\\w-]*)\\]([+-]?)")

    /// Replaces `[!kind]±` at the start of a quote line with a token the
    /// block converter recognises (swift-markdown would otherwise read
    /// it as a link reference and split it into pieces).
    static func markCallouts(_ src: String) -> (source: String, markers: [Int: CalloutMarker]) {
        guard src.contains("[!") else { return (src, [:]) }
        var lines = src.components(separatedBy: "\n")
        let code = MarkdownTasks.codeLines(lines)
        var markers: [Int: CalloutMarker] = [:]
        for i in lines.indices where !code[i] {
            let ns = lines[i] as NSString
            guard let m = calloutLine.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)) else { continue }
            let n = markers.count
            let fold: MarkdownCallout.Fold
            switch ns.substring(with: m.range(at: 3)) {
            case "+": fold = .open
            case "-": fold = .closed
            default: fold = .none
            }
            markers[n] = CalloutMarker(rawKind: ns.substring(with: m.range(at: 2)).lowercased(), fold: fold)
            let prefix = ns.substring(with: m.range(at: 1))
            let rest = ns.substring(from: NSMaxRange(m.range))
            lines[i] = prefix + "\u{E000}c\(n)\u{E001}" + rest
        }
        return (markers.isEmpty ? src : lines.joined(separator: "\n"), markers)
    }

    /// Carries everything the recursive AST conversion needs that isn't
    /// already on the swift-markdown nodes. Keeping it in one struct
    /// means the convertBlock / convertInline call surface doesn't grow
    /// each time a new pre-processing pass lands.
    fileprivate struct ParseContext {
        let math: [String: MathExpression]
        let baseURL: URL?
        /// Footnote-ref token → footnote id.
        var footnotes: [String: String] = [:]
        var footnoteNumbers: [String: Int] = [:]
        var callouts: [Int: CalloutMarker] = [:]
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
        /// Footnote-ref token → id.
        var footnoteRefs: [String: String] = [:]
        /// Output line → source line (0-based).
        var lineMap: [Int] = [0]
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
    fileprivate static func extractInline(_ source: String, footnoteIDs: Set<String>) -> MathExtraction {
        let chars = Array(source)
        var out = String()
        out.reserveCapacity(source.count)
        var expressions: [String: MathExpression] = [:]
        var footnoteRefs: [String: String] = [:]
        var lineMap: [Int] = [0]
        var srcLine = 0
        var nextIndex = 0
        var i = 0
        var inFence = false
        var inBacktick = false
        var atLineStart = true
        var markCloses = Set<Int>()

        /// Append one consumed source character.
        func emit(_ c: Character) {
            out.append(c)
            if c == "\n" {
                srcLine += 1
                lineMap.append(srcLine)
            }
        }
        func consumedHidden(_ s: ArraySlice<Character>) {
            for c in s where c == "\n" { srcLine += 1 }
        }

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
                emit(c)
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
                emit(c)
                atLineStart = (c == "\n")
                if c == "\n", i + 1 < chars.count, chars[i + 1] == "\n" { inBacktick = false }
                i += 1
                continue
            }

            // Backslash escape: `\$` is a literal dollar; copy both chars
            // unchanged so swift-markdown still sees the escape.
            if c == "\\" && i + 1 < chars.count {
                out.append(c)
                emit(chars[i + 1])
                atLineStart = chars[i + 1] == "\n"
                i += 2
                continue
            }

            if markCloses.contains(i) {
                out.append("\u{E003}")
                markCloses.remove(i)
                i += 2
                atLineStart = false
                continue
            }

            // Block math: `$$ … $$`. Newlines allowed inside.
            if c == "$" && i + 1 < chars.count && chars[i + 1] == "$" {
                if let endStart = findClosing(chars, from: i + 2, delim: .block) {
                    let latex = String(chars[(i + 2)..<endStart])
                    let token = makeToken(&nextIndex)
                    expressions[token] = MathExpression(latex: latex, display: .block)
                    out.append(token)
                    consumedHidden(chars[(i + 2)..<endStart])
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

            // Footnote reference `[^id]` (only ids with a definition).
            if c == "[", !footnoteIDs.isEmpty, i + 2 < chars.count, chars[i + 1] == "^" {
                var j = i + 2
                var id = ""
                while j < chars.count, chars[j] != "]", !chars[j].isWhitespace { id.append(chars[j]); j += 1 }
                if j < chars.count, chars[j] == "]", !id.isEmpty, footnoteIDs.contains(id),
                   !(j + 1 < chars.count && chars[j + 1] == ":") {
                    let token = "\u{E000}f\(nextIndex)\u{E001}"
                    nextIndex += 1
                    footnoteRefs[token] = id
                    out.append(token)
                    i = j + 1
                    atLineStart = false
                    continue
                }
            }

            // `==highlight==` on one line, no `=` inside, non-space edges.
            if c == "=", i + 2 < chars.count, chars[i + 1] == "=", chars[i + 2] != "=", !chars[i + 2].isWhitespace,
               i == 0 || chars[i - 1] != "=" {
                var j = i + 2
                var close: Int?
                while j + 1 < chars.count, chars[j] != "\n" {
                    if chars[j] == "=" {
                        if chars[j + 1] == "=", !chars[j - 1].isWhitespace, !(j + 2 < chars.count && chars[j + 2] == "=") {
                            close = j
                        }
                        break
                    }
                    j += 1
                }
                if let close {
                    out.append("\u{E002}")
                    markCloses.insert(close)
                    i += 2
                    atLineStart = false
                    continue
                }
            }

            emit(c)
            atLineStart = (c == "\n")
            i += 1
        }
        return MathExtraction(transformed: out, expressions: expressions, footnoteRefs: footnoteRefs, lineMap: lineMap)
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

    /// Pattern for every sentinel: `\u{E000}<kind><n>\u{E001}` tokens
    /// (math, footnote ref, callout) and the `==mark==` delimiters.
    private static let tokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\u{E000}([mfc])([0-9]+)\u{E001}|[\u{E002}\u{E003}]", options: [])
    }()

    /// Splits a text node at sentinels into `.text`, `.math`,
    /// `.footnoteRef` and bare mark delimiters (grouped afterwards by
    /// `groupSpans`). Each surviving text region keeps its whitespace;
    /// empty runs are skipped so the AST stays compact.
    private static func splitTokens(_ s: String, context: ParseContext) -> [InlineNode] {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = tokenRegex.matches(in: s, options: [], range: range)
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
            if token == "\u{E002}" || token == "\u{E003}" {
                out.append(.text(token))
            } else if let expr = context.math[token] {
                out.append(.math(latex: expr.latex, display: expr.display))
            } else if let id = context.footnotes[token], let n = context.footnoteNumbers[id] {
                out.append(.footnoteRef(id: id, number: n))
            } else if m.numberOfRanges > 2, ns.substring(with: m.range(at: 1)) == "c",
                      let n = Int(ns.substring(with: m.range(at: 2))), let marker = context.callouts[n] {
                // A callout marker that doesn't open a blockquote: show it.
                out.append(.text("[!\(marker.rawKind)]"))
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

    /// Pairs `==` (E002/E003) and `<kbd>` (E004/E005) delimiters that
    /// sit in the same inline list into `.mark` / `.kbd`; unpaired
    /// delimiters fall back to their literal text.
    static func groupSpans(_ nodes: [InlineNode]) -> [InlineNode] {
        let open: [String: String] = ["\u{E002}": "\u{E003}", "\u{E004}": "\u{E005}"]
        let literal: [String: String] = ["\u{E002}": "==", "\u{E003}": "==", "\u{E004}": "", "\u{E005}": ""]
        var out: [InlineNode] = []
        var i = 0
        while i < nodes.count {
            if case let .text(t) = nodes[i], let closer = open[t] {
                if let j = nodes[(i + 1)...].firstIndex(where: { if case let .text(u) = $0 { return u == closer } else { return false } }) {
                    let inner = groupSpans(Array(nodes[(i + 1)..<j]))
                    if t == "\u{E002}" {
                        out.append(.mark(inner))
                    } else {
                        out.append(.kbd(plainText(inner)))
                    }
                    i = j + 1
                    continue
                }
            }
            if case let .text(t) = nodes[i], let lit = literal[t] {
                if !lit.isEmpty { out.append(.text(lit)) }
            } else {
                out.append(nodes[i])
            }
            i += 1
        }
        return out
    }

    /// Visible text of an inline tree (kbd labels, slugs, alt text).
    public static func plainText(_ nodes: [InlineNode]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case let .text(s), let .code(s), let .kbd(s): out += s
            case let .strong(c), let .emphasis(c), let .strikethrough(c), let .mark(c): out += plainText(c)
            case let .link(_, c): out += plainText(c)
            case let .image(_, alt): out += alt
            case let .math(latex, _): out += latex
            case .lineBreak, .softBreak: out += " "
            case let .footnoteRef(_, n): out += "\(n)"
            }
        }
        return out
    }

    /// Lift any paragraph whose visible content is a single display-mode
    /// math expression (optionally surrounded by whitespace text or soft
    /// breaks) up to a top-level `.mathBlock`. Other paragraphs — incl.
    /// those with inline math next to prose — stay as paragraphs and the
    /// renderer dispatches them to the paragraph-level KaTeX WebView.
    private static func liftDisplayMath(in block: MarkdownBlock) -> MarkdownBlock {
        switch block {
        case let .paragraph(inline):
            if let latex = soleDisplayMath(in: inline) {
                return .mathBlock(latex: latex)
            }
            return .paragraph(inline: inline)
        case let .blockQuote(children):
            return .blockQuote(blocks: children.map { liftDisplayMath(in: $0) })
        case var .callout(c):
            c.blocks = c.blocks.map { liftDisplayMath(in: $0) }
            return .callout(c)
        case let .unorderedList(items):
            return .unorderedList(items: items.map { item in
                ListItemContent(
                    checkbox: item.checkbox,
                    blocks: item.blocks.map { liftDisplayMath(in: $0) }
                )
            })
        case let .orderedList(start, items):
            return .orderedList(start: start, items: items.map { item in
                ListItemContent(
                    checkbox: item.checkbox,
                    blocks: item.blocks.map { liftDisplayMath(in: $0) }
                )
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
            if let callout = convertCallout(blockQuote, context: context) { return .callout(callout) }
            return .blockQuote(blocks: blockQuote.children.compactMap { convertBlock($0, context: context) })

        case let table as Markdown.Table:
            let alignments: [MarkdownTableAlignment] = table.columnAlignments.map {
                switch $0 {
                case .left?: return .left
                case .center?: return .center
                case .right?: return .right
                case nil: return .none
                }
            }
            let header: [[InlineNode]] = Array(table.head.cells.map { convertInline($0.children, context: context) })
            let rows: [[[InlineNode]]] = Array(table.body.rows.map { row in
                Array(row.cells.map { convertInline($0.children, context: context) })
            })
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            func pad(_ r: [[InlineNode]]) -> [[InlineNode]] { r + Array(repeating: [], count: max(0, columns - r.count)) }
            return .table(MarkdownTable(
                alignments: alignments + Array(repeating: .none, count: max(0, columns - alignments.count)),
                header: pad(header),
                rows: rows.map(pad)
            ))

        case let html as HTMLBlock:
            // Only `<kbd>` survives; other raw HTML is not rendered.
            let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.lowercased().contains("<kbd>") else { return nil }
            return .paragraph(inline: convertInline(Document(parsing: raw.replacingOccurrences(of: "\n", with: " ")).children.flatMap { Array($0.children) }, context: context))

        case let list as UnorderedList:
            return .unorderedList(items: list.listItems.map { item in
                convertListItem(item, context: context)
            })

        case let list as OrderedList:
            let start = Int(list.startIndex)
            return .orderedList(
                start: start,
                items: list.listItems.map { item in
                    convertListItem(item, context: context)
                }
            )

        case is ThematicBreak:
            return .thematicBreak

        default:
            return nil
        }
    }

    /// `> [!kind]± Title` + body → callout. The marker token was put in
    /// by `markCallouts`; the title is the rest of the first line, the
    /// body everything after it.
    private static func convertCallout(_ quote: BlockQuote, context: ParseContext) -> MarkdownCallout? {
        guard !context.callouts.isEmpty,
              let first = quote.child(at: 0) as? Paragraph,
              let text = first.child(at: 0) as? Markdown.Text,
              text.string.hasPrefix("\u{E000}c"),
              let close = text.string.firstIndex(of: "\u{E001}"),
              let n = Int(text.string[text.string.index(text.string.startIndex, offsetBy: 2)..<close]),
              let marker = context.callouts[n]
        else { return nil }
        var inline = convertInline(first.children, context: context)
        // Drop the marker (rendered as "[!kind]" by splitTokens).
        if case let .text(t)? = inline.first, t == "[!\(marker.rawKind)]" { inline.removeFirst() }
        var title: [InlineNode] = []
        var bodyInline: [InlineNode] = []
        var inTitle = true
        for node in inline {
            if inTitle {
                switch node {
                case .softBreak, .lineBreak: inTitle = false
                default: title.append(node)
                }
            } else {
                bodyInline.append(node)
            }
        }
        if case let .text(t)? = title.first {
            let trimmed = String(t.drop(while: { $0 == " " || $0 == "\t" }))
            if trimmed.isEmpty { title.removeFirst() } else { title[0] = .text(trimmed) }
        }
        var blocks: [MarkdownBlock] = []
        if !bodyInline.isEmpty { blocks.append(.paragraph(inline: bodyInline)) }
        for child in quote.children.dropFirst() {
            if let b = convertBlock(child, context: context) { blocks.append(b) }
        }
        return MarkdownCallout(
            kind: MarkdownCallout.canonicalKind(marker.rawKind),
            rawKind: marker.rawKind,
            title: title,
            fold: marker.fold,
            blocks: blocks
        )
    }

    /// Convert a swift-markdown `ListItem` into our internal descriptor,
    /// preserving the GFM checkbox state when present.
    private static func convertListItem(_ item: ListItem, context: ParseContext) -> ListItemContent {
        let checkbox: ListItemCheckbox? = {
            switch item.checkbox {
            case .checked: return .checked
            case .unchecked: return .unchecked
            case nil: return nil
            @unknown default: return nil
            }
        }()
        let blocks = item.children.compactMap { convertBlock($0, context: context) }
        return ListItemContent(checkbox: checkbox, blocks: blocks)
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
        let title = image.title.flatMap { $0.isEmpty ? nil : $0 }
        return MediaReference(url: url, alt: alt, kind: kind, title: title)
    }

    private static func convertInline(_ markups: MarkupChildren, context: ParseContext) -> [InlineNode] {
        groupSpans(markups.flatMap { convertInlineNode($0, context: context) })
    }

    private static func convertInline(_ markups: [any Markup], context: ParseContext) -> [InlineNode] {
        groupSpans(markups.flatMap { convertInlineNode($0, context: context) })
    }

    /// Returns 0+ nodes for the input. Most cases pass through 1-for-1;
    /// `.text` may explode into multiple nodes when math sentinels split
    /// it. Returning `[InlineNode]` instead of `InlineNode?` removes the
    /// need for a callee-side flatten loop everywhere else.
    private static func convertInlineNode(_ markup: any Markup, context: ParseContext) -> [InlineNode] {
        switch markup {
        case let text as Markdown.Text:
            return splitTokens(text.string, context: context)
        case let html as InlineHTML:
            switch html.rawHTML.lowercased().replacingOccurrences(of: " ", with: "") {
            case "<kbd>": return [.text("\u{E004}")]
            case "</kbd>": return [.text("\u{E005}")]
            case "<br>", "<br/>": return [.lineBreak]
            default: return []
            }
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
        // In-document anchors (`#h-intro`, footnotes) stay fragments.
        if trimmed.hasPrefix("#") { return URL(string: trimmed) }
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
