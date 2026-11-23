import Foundation

/// Plain-text buffer with a character-offset cursor. Engine code stays
/// platform-agnostic; conversion to UTF-16 / NSRange happens at the UI bridge.
///
/// Every text change the engine makes goes through `replaceCharacters`,
/// which also appends a ranged UTF-16 `TextEdit` to `edits`. The host
/// clears `edits` before an engine step and forwards what accumulated to
/// the text view and the CRDT — so a change reaches Yjs as minimal ranged
/// ops (a `:s` over many lines is one edit per match), never a
/// replace-all. `edits` is bookkeeping: it is ignored by `==`.
public struct TextBuffer: Sendable {
    public var text: String
    /// Character offset, `0 ≤ cursor ≤ text.count`. Insert-mode allows the
    /// past-end position; normal mode clamps to the last character of the
    /// line.
    public var cursor: Int
    /// Sequential UTF-16 edits applied since the host last cleared it.
    public var edits: [TextEdit]

    public init(text: String = "", cursor: Int = 0) {
        self.text = text
        self.cursor = cursor
        self.edits = []
    }

    public static let empty = TextBuffer()
}

extension TextBuffer: Hashable {
    public static func == (lhs: TextBuffer, rhs: TextBuffer) -> Bool {
        lhs.cursor == rhs.cursor && lhs.text == rhs.text
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(cursor)
    }
}

public extension TextBuffer {
    var count: Int { text.count }

    func clampedCursor(allowPastEnd: Bool) -> Int {
        if text.isEmpty { return 0 }
        let upper = allowPastEnd ? text.count : text.count - 1
        return max(0, min(cursor, upper))
    }

    /// Cursor as a `String.Index`, clamped to `text.endIndex`.
    var cursorIndex: String.Index {
        let safe = max(0, min(cursor, text.count))
        return text.index(text.startIndex, offsetBy: safe)
    }

    /// Convert a `String.Index` back to a character offset.
    func offset(of index: String.Index) -> Int {
        text.distance(from: text.startIndex, to: index)
    }

    /// All lines (excluding their `\n`). Every `\n` separates two lines,
    /// so `"abc\n"` has a second, empty line (CodeMirror / web parity).
    var lines: [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Line index containing the cursor (0-based).
    var cursorLine: Int {
        guard !text.isEmpty else { return 0 }
        return text.prefix(cursor).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    /// Column within the cursor's line (0-based, character count).
    var cursorColumn: Int {
        guard !text.isEmpty else { return 0 }
        let prefix = text.prefix(cursor)
        if let lastNewline = prefix.lastIndex(of: "\n") {
            return prefix.distance(from: prefix.index(after: lastNewline), to: prefix.endIndex)
        }
        return min(cursor, text.count)
    }

    /// Offset of the start of `line` (0-based). Past the last line →
    /// `text.count`.
    func lineStart(of line: Int) -> Int {
        if line <= 0 { return 0 }
        var seen = 0
        var offset = 0
        for char in text {
            offset += 1
            if char == "\n" {
                seen += 1
                if seen == line { return offset }
            }
        }
        return text.count
    }

    /// Offset of the end of `line` (the position of its `\n`, or
    /// `text.count` for the last line).
    func lineEnd(of line: Int) -> Int {
        let start = lineStart(of: line)
        var offset = start
        var index = text.index(text.startIndex, offsetBy: start)
        while index < text.endIndex && text[index] != "\n" {
            offset += 1
            index = text.index(after: index)
        }
        return offset
    }

    /// Length of `line` (excluding `\n`).
    func lineLength(of line: Int) -> Int {
        lineEnd(of: line) - lineStart(of: line)
    }

    var lineCount: Int { text.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) } }

    /// Replace the characters `[from, to)` with `replacement` and log the
    /// change as one ranged UTF-16 edit. Offsets are clamped.
    mutating func replaceCharacters(from: Int, to: Int, with replacement: String) {
        let lo = text.index(text.startIndex, offsetBy: max(0, from), limitedBy: text.endIndex) ?? text.endIndex
        let hi = text.index(lo, offsetBy: max(0, to - max(0, from)), limitedBy: text.endIndex) ?? text.endIndex
        guard lo < hi || !replacement.isEmpty else { return }
        let location = text.utf16.distance(from: text.utf16.startIndex, to: lo)
        let length = text.utf16.distance(from: lo, to: hi)
        text.replaceSubrange(lo..<hi, with: replacement)
        appendEdit(TextEdit(location: location, length: length, replacement: replacement))
    }

    /// Record an edit, fusing it with the previous one when it simply
    /// continues typing (insert right after an insert) or erases what was
    /// just typed (backspace) — keeps an insert session to one op.
    mutating func appendEdit(_ edit: TextEdit) {
        if var last = edits.last {
            let lastEnd = last.location + last.replacementLength
            if edit.length == 0, edit.location == lastEnd {
                last.replacement += edit.replacement
                edits[edits.count - 1] = last
                return
            }
            if edit.replacement.isEmpty, edit.location + edit.length == lastEnd,
               edit.location >= last.location {
                let keep = edit.location - last.location
                let u = Array(last.replacement.utf16)
                last.replacement = String(decoding: u[0..<keep], as: UTF16.self)
                if last.isNoOp { edits.removeLast() } else { edits[edits.count - 1] = last }
                return
            }
        }
        edits.append(edit)
    }
}

/// Random-access snapshot of a buffer for motions and text objects:
/// characters plus line starts. Built per command (O(n)).
struct Doc {
    let string: String
    let chars: [Character]
    let lineStarts: [Int]

    init(_ text: String) {
        string = text
        chars = Array(text)
        var starts = [0]
        for (i, c) in chars.enumerated() where c == "\n" { starts.append(i + 1) }
        lineStarts = starts
    }

    var count: Int { chars.count }
    var lineCount: Int { lineStarts.count }
    var lastLine: Int { lineStarts.count - 1 }

    subscript(i: Int) -> Character { chars[i] }

    func clampLine(_ l: Int) -> Int { max(0, min(lastLine, l)) }

    /// Line containing `offset` (offsets past the end belong to the last line).
    func line(of offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func lineStart(_ l: Int) -> Int { lineStarts[clampLine(l)] }

    /// Offset of the line's `\n` (or `count` for the last line).
    func lineEnd(_ l: Int) -> Int {
        let l = clampLine(l)
        return l + 1 < lineStarts.count ? lineStarts[l + 1] - 1 : chars.count
    }

    /// End of the line including its `\n` (start of the next line).
    func lineEndInclusive(_ l: Int) -> Int {
        let l = clampLine(l)
        return l + 1 < lineStarts.count ? lineStarts[l + 1] : chars.count
    }

    func lineLength(_ l: Int) -> Int { lineEnd(l) - lineStart(l) }
    func isEmptyLine(_ l: Int) -> Bool { lineLength(l) == 0 }

    func column(of offset: Int) -> Int { offset - lineStart(line(of: offset)) }

    /// Last character of the line (its start when empty) — where normal
    /// mode may put the cursor.
    func lastChar(_ l: Int) -> Int { max(lineStart(l), lineEnd(l) - 1) }

    /// First non-blank of the line; on an all-blank line its last char.
    func firstNonBlank(_ l: Int) -> Int {
        var i = lineStart(l)
        let end = lineEnd(l)
        while i < end, chars[i] == " " || chars[i] == "\t" { i += 1 }
        return i < end ? i : lastChar(l)
    }

    /// Last non-blank of the line, or nil when blank.
    func lastNonBlank(_ l: Int) -> Int? {
        var i = lineEnd(l) - 1
        let start = lineStart(l)
        while i >= start, chars[i] == " " || chars[i] == "\t" { i -= 1 }
        return i >= start ? i : nil
    }

    /// Offset of `column` on line `l`, clamped to the line's last char.
    func offset(line l: Int, column: Int, allowEnd: Bool = false) -> Int {
        let start = lineStart(l)
        let limit = allowEnd ? lineEnd(l) : lastChar(l)
        return min(start + max(0, column), limit)
    }

    func text(_ from: Int, _ to: Int) -> String {
        let a = max(0, min(from, chars.count)), b = max(a, min(to, chars.count))
        return String(chars[a..<b])
    }

    func lineText(_ l: Int) -> String { text(lineStart(l), lineEnd(l)) }

    /// Leading whitespace of line `l`.
    func indent(_ l: Int) -> String {
        var i = lineStart(l)
        let end = lineEnd(l)
        var s = ""
        while i < end, chars[i] == " " || chars[i] == "\t" { s.append(chars[i]); i += 1 }
        return s
    }
}

/// Character classes for word motions and objects.
enum CharClass: Equatable {
    case newline, blank, punct, word

    init(_ c: Character, big: Bool) {
        if c == "\n" { self = .newline }
        else if c == " " || c == "\t" || c.isWhitespace { self = .blank }
        else if big { self = .word }
        else if c.isLetter || c.isNumber || c == "_" { self = .word }
        else { self = .punct }
    }

    var isWordish: Bool { self == .word || self == .punct }
}

func isKeywordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" }
