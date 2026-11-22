import Foundation

/// Style classes of the editor's lightweight markdown highlighting. The UI
/// layer maps each to font/colour attributes.
public enum MarkdownSyntaxStyle: Sendable, Hashable, CaseIterable {
    case heading
    case bold
    case inlineCode
    case fence
    case quote
    case link
    case bullet
    case frontmatterDelimiter
}

/// Line-local markdown highlighting for the source editor. Every pattern
/// matches within a single line, so re-highlighting only the paragraphs
/// an edit touched gives exactly the same result as a full pass — the
/// editor never re-scans the whole document per keystroke.
public enum MarkdownSyntaxHighlighter {
    public struct Span: Sendable, Equatable {
        public let range: NSRange
        public let style: MarkdownSyntaxStyle
    }

    private static let rules: [(NSRegularExpression, MarkdownSyntaxStyle)] = {
        let table: [(String, MarkdownSyntaxStyle)] = [
            ("^#{1,6} .*$", .heading),
            ("\\*\\*[^*\\n]+\\*\\*", .bold),
            ("`[^`\\n]+`", .inlineCode),
            ("^```.*$", .fence),
            ("^>\\s.*$", .quote),
            ("\\[[^\\]\\n]+\\]\\([^)\\n]+\\)", .link),
            ("^[ \\t]*[-*+][ \\t]", .bullet),
            ("^---$", .frontmatterDelimiter),
        ]
        return table.compactMap { pattern, style in
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])).map { ($0, style) }
        }
    }()

    /// Spans inside `range` (which should cover whole lines).
    public static func spans(in text: NSString, range: NSRange) -> [Span] {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return [] }
        var out: [Span] = []
        let string = text as String
        for (regex, style) in rules {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                if let r = match?.range, r.length > 0 { out.append(Span(range: r, style: style)) }
            }
        }
        return out
    }

    /// The whole-line range a sequential edit list dirtied in the *new*
    /// text: the union of the paragraphs around every replaced span.
    /// Returns nil when nothing needs re-highlighting.
    public static func dirtyRange(for edits: [TextEdit], in text: NSString) -> NSRange? {
        guard !edits.isEmpty else { return nil }
        var union: NSRange?
        var shifted: [NSRange] = []
        for e in edits {
            // Earlier dirty ranges move with later edits.
            shifted = shifted.map { r in
                let s = PositionMapper.map(r.location, through: e, assoc: .before)
                let end = max(s, PositionMapper.map(NSMaxRange(r), through: e, assoc: .after))
                return NSRange(location: s, length: end - s)
            }
            // +1: the character after the replacement, so a split line's
            // tail (re-styled out of its old line's context) is included.
            shifted.append(NSRange(location: e.location, length: e.replacementLength + 1))
        }
        for r in shifted {
            let clamped = NSRange(location: min(r.location, text.length), length: max(0, min(NSMaxRange(r), text.length) - min(r.location, text.length)))
            let lines = text.lineRange(for: clamped)
            union = union.map { NSUnionRange($0, lines) } ?? lines
        }
        return union
    }
}
