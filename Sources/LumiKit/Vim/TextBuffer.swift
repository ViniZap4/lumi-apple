import Foundation

/// Plain-text buffer with a character-offset cursor. Engine code stays
/// platform-agnostic; conversion to UTF-16 / NSRange happens at the UI bridge.
public struct TextBuffer: Sendable, Hashable {
    public var text: String
    /// Character offset, `0 ≤ cursor ≤ text.count`. Insert-mode allows the
    /// past-end position; normal mode clamps to `text.count - 1` when the
    /// buffer is non-empty.
    public var cursor: Int

    public init(text: String = "", cursor: Int = 0) {
        self.text = text
        self.cursor = cursor
    }

    public static let empty = TextBuffer()
}

public extension TextBuffer {
    var count: Int { text.count }

    func clampedCursor(allowPastEnd: Bool) -> Int {
        if text.isEmpty { return 0 }
        let upper = allowPastEnd ? text.count : text.count - 1
        return max(0, min(cursor, upper))
    }

    /// Cursor as a `String.Index`, clamped to `text.endIndex`. Cheap for short
    /// buffers; future perf work can add a UTF-16 line cache.
    var cursorIndex: String.Index {
        let safe = max(0, min(cursor, text.count))
        return text.index(text.startIndex, offsetBy: safe)
    }

    /// Convert a `String.Index` back to a character offset.
    func offset(of index: String.Index) -> Int {
        text.distance(from: text.startIndex, to: index)
    }

    /// All lines (excluding their trailing `\n`). An empty buffer is a single
    /// empty line. A trailing `\n` produces an extra empty line.
    var lines: [Substring] {
        if text.isEmpty { return [""] }
        var result = text.split(separator: "\n", omittingEmptySubsequences: false)
        // `split(omittingEmptySubsequences: false)` keeps the trailing empty
        // for "abc\n", which matches vim's "phantom empty last line" view.
        if result.last == "" { result.removeLast() }
        return result
    }

    /// Line index containing the cursor (0-based). Falls back to 0 on empty.
    var cursorLine: Int {
        guard !text.isEmpty else { return 0 }
        let prefix = text.prefix(cursor)
        return prefix.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    /// Column within the cursor's line (0-based, character count).
    var cursorColumn: Int {
        guard !text.isEmpty else { return 0 }
        let prefix = text.prefix(cursor)
        if let lastNewline = prefix.lastIndex(of: "\n") {
            return prefix.distance(from: prefix.index(after: lastNewline), to: prefix.endIndex)
        }
        return cursor
    }

    /// Offset of the start of `line` (0-based). If the line index is past the
    /// last line, returns `text.count`.
    func lineStart(of line: Int) -> Int {
        if line <= 0 { return 0 }
        var seen = 0
        var offset = 0
        for char in text {
            if seen == line { return offset }
            offset += 1
            if char == "\n" { seen += 1 }
        }
        return offset
    }

    /// Offset of the end of `line` (the position of `\n` or `text.count` for
    /// the last line). Empty lines return `lineStart(line)`.
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

    /// Length of `line` (excluding `\n`). 0 for empty lines.
    func lineLength(of line: Int) -> Int {
        lineEnd(of: line) - lineStart(of: line)
    }

    var lineCount: Int { lines.count }
}
