import Foundation

/// `i` (inner) vs `a` (around). The "around" variant includes the surrounding
/// delimiters (and trailing whitespace, for word objects).
public enum TextObjectKind: Sendable, Hashable {
    case inner
    case around
}

/// Concrete text object that resolves to a `(from, to)` half-open character
/// range when given a buffer.
public enum TextObject: Sendable, Hashable {
    case word
    case quote(Character)
    case bracket(open: Character, close: Character)
}

public extension TextObject {
    /// Map a follow-up character (the `w` in `daw`, the `(` in `da(`) to a
    /// concrete text object. Returns nil for unknown selectors.
    static func from(char: Character) -> TextObject? {
        switch char {
        case "w": return .word
        case "\"": return .quote("\"")
        case "'": return .quote("'")
        case "`": return .quote("`")
        case "(", ")", "b": return .bracket(open: "(", close: ")")
        case "{", "}", "B": return .bracket(open: "{", close: "}")
        case "[", "]": return .bracket(open: "[", close: "]")
        case "<", ">": return .bracket(open: "<", close: ">")
        default: return nil
        }
    }

    /// Resolve to a half-open `(from, to)` character range, or nil if the
    /// object isn't found at the cursor (e.g. no surrounding parens).
    func resolve(in buffer: TextBuffer, kind: TextObjectKind) -> (from: Int, to: Int)? {
        switch self {
        case .word: return resolveWord(in: buffer, kind: kind)
        case let .quote(q): return resolveQuote(in: buffer, quote: q, kind: kind)
        case let .bracket(o, c): return resolveBracket(in: buffer, open: o, close: c, kind: kind)
        }
    }
}

private extension TextObject {
    func resolveWord(in buffer: TextBuffer, kind: TextObjectKind) -> (from: Int, to: Int)? {
        let chars = Array(buffer.text)
        guard !chars.isEmpty else { return nil }
        let cursor = max(0, min(buffer.cursor, chars.count - 1))

        var start = cursor
        if isWordChar(chars[cursor]) {
            while start > 0, isWordChar(chars[start - 1]) { start -= 1 }
        } else {
            while start < chars.count, !isWordChar(chars[start]) { start += 1 }
            if start == chars.count { return nil }
        }

        var end = start
        while end < chars.count, isWordChar(chars[end]) { end += 1 }

        if kind == .around {
            // Include trailing whitespace (but not newlines) in `aw`.
            while end < chars.count, chars[end].isWhitespace, chars[end] != "\n" {
                end += 1
            }
        }
        return (start, end)
    }

    func resolveQuote(in buffer: TextBuffer, quote: Character, kind: TextObjectKind) -> (from: Int, to: Int)? {
        let chars = Array(buffer.text)
        guard !chars.isEmpty else { return nil }
        let cursor = max(0, min(buffer.cursor, chars.count - 1))

        var leftOpt: Int?
        var i = cursor
        while i >= 0 {
            if chars[i] == quote { leftOpt = i; break }
            i -= 1
        }
        guard let left = leftOpt else { return nil }

        var rightOpt: Int?
        i = (left == cursor) ? cursor + 1 : cursor
        if i <= left { i = left + 1 }
        while i < chars.count {
            if chars[i] == quote { rightOpt = i; break }
            i += 1
        }
        guard let right = rightOpt, right > left else { return nil }

        return kind == .inner ? (left + 1, right) : (left, right + 1)
    }

    func resolveBracket(in buffer: TextBuffer, open: Character, close: Character, kind: TextObjectKind) -> (from: Int, to: Int)? {
        let chars = Array(buffer.text)
        guard !chars.isEmpty else { return nil }
        let cursor = max(0, min(buffer.cursor, chars.count - 1))

        var depth = 0
        var leftOpt: Int?
        var i = cursor
        while i >= 0 {
            if chars[i] == close, i != cursor { depth += 1 }
            else if chars[i] == open {
                if depth == 0 { leftOpt = i; break }
                depth -= 1
            }
            i -= 1
        }
        guard let left = leftOpt else { return nil }

        depth = 0
        var rightOpt: Int?
        i = left + 1
        while i < chars.count {
            if chars[i] == open { depth += 1 }
            else if chars[i] == close {
                if depth == 0 { rightOpt = i; break }
                depth -= 1
            }
            i += 1
        }
        guard let right = rightOpt else { return nil }

        return kind == .inner ? (left + 1, right) : (left, right + 1)
    }

    func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
