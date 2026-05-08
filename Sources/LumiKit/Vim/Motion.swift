import Foundation

/// A vim motion. Each case resolves to a target offset given a buffer and a
/// count, via `Motion.resolve`.
public enum Motion: Sendable, Hashable {
    case left
    case right
    case up
    case down
    case wordForward
    case wordBack
    case wordEnd
    case lineStart        // 0
    case lineFirstNonBlank // ^
    case lineEnd          // $
    case fileStart        // gg
    case fileEnd          // G
}

public extension Motion {
    /// True when the motion includes the character at the destination (e.g.
    /// `e` and `$`). Operators consume an inclusive motion as `[from, to]`,
    /// exclusive ones as `[from, to)`.
    var isInclusive: Bool {
        switch self {
        case .wordEnd, .lineEnd: return true
        default: return false
        }
    }

    /// True when the motion targets entire lines (e.g. `j` after `d` removes
    /// whole lines). Linewise motions widen the operator range to line bounds.
    var isLinewise: Bool {
        switch self {
        case .up, .down, .fileStart, .fileEnd: return true
        default: return false
        }
    }
}

public extension Motion {
    /// Resolve this motion to a destination character offset within `buffer`,
    /// applied `count` times.
    func resolve(in buffer: TextBuffer, count: Int) -> Int {
        var offset = buffer.cursor
        for _ in 0..<max(1, count) {
            offset = step(in: buffer, from: offset)
        }
        return offset
    }

    private func step(in buffer: TextBuffer, from offset: Int) -> Int {
        switch self {
        case .left:
            return max(0, offset - 1)
        case .right:
            return min(buffer.text.count, offset + 1)
        case .up:
            return verticalStep(buffer: buffer, offset: offset, delta: -1)
        case .down:
            return verticalStep(buffer: buffer, offset: offset, delta: +1)
        case .wordForward:
            return wordForward(buffer: buffer, from: offset)
        case .wordBack:
            return wordBack(buffer: buffer, from: offset)
        case .wordEnd:
            return wordEnd(buffer: buffer, from: offset)
        case .lineStart:
            return buffer.lineStart(of: lineIndex(buffer: buffer, offset: offset))
        case .lineFirstNonBlank:
            let line = lineIndex(buffer: buffer, offset: offset)
            let start = buffer.lineStart(of: line)
            let end = buffer.lineEnd(of: line)
            var idx = start
            var i = buffer.text.index(buffer.text.startIndex, offsetBy: start)
            while idx < end, isWhitespace(buffer.text[i]) {
                idx += 1
                i = buffer.text.index(after: i)
            }
            return idx
        case .lineEnd:
            let line = lineIndex(buffer: buffer, offset: offset)
            let end = buffer.lineEnd(of: line)
            return max(0, end - 1)
        case .fileStart:
            return 0
        case .fileEnd:
            let lastLine = max(0, buffer.lineCount - 1)
            return buffer.lineStart(of: lastLine)
        }
    }

    private func lineIndex(buffer: TextBuffer, offset: Int) -> Int {
        var saved = buffer
        saved.cursor = offset
        return saved.cursorLine
    }

    private func verticalStep(buffer: TextBuffer, offset: Int, delta: Int) -> Int {
        var saved = buffer
        saved.cursor = offset
        let targetLine = max(0, min(buffer.lineCount - 1, saved.cursorLine + delta))
        let column = saved.cursorColumn
        let lineStart = buffer.lineStart(of: targetLine)
        let lineLen = buffer.lineLength(of: targetLine)
        let clampedColumn = min(column, max(0, lineLen - 1))
        return lineStart + clampedColumn
    }

    private func isWordChar(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_"
    }

    private func isWhitespace(_ char: Character) -> Bool {
        char.isWhitespace
    }

    private enum CharClass { case word, nonWord, whitespace }
    private func charClass(_ c: Character) -> CharClass {
        if isWhitespace(c) { return .whitespace }
        return isWordChar(c) ? .word : .nonWord
    }

    private func wordForward(buffer: TextBuffer, from offset: Int) -> Int {
        let chars = Array(buffer.text)
        guard offset < chars.count else { return offset }
        var i = offset
        let originalClass = charClass(chars[i])
        // Move through the current run.
        while i < chars.count, charClass(chars[i]) == originalClass, !isWhitespace(chars[i]) {
            i += 1
        }
        // Skip whitespace runs.
        while i < chars.count, isWhitespace(chars[i]) {
            i += 1
        }
        return i
    }

    private func wordBack(buffer: TextBuffer, from offset: Int) -> Int {
        let chars = Array(buffer.text)
        if chars.isEmpty || offset == 0 { return 0 }
        var i = offset - 1
        // Skip whitespace runs going back.
        while i > 0, isWhitespace(chars[i]) {
            i -= 1
        }
        // Move through the current run to its start.
        let cls = charClass(chars[i])
        while i > 0, charClass(chars[i - 1]) == cls, !isWhitespace(chars[i - 1]) {
            i -= 1
        }
        return i
    }

    private func wordEnd(buffer: TextBuffer, from offset: Int) -> Int {
        let chars = Array(buffer.text)
        guard !chars.isEmpty else { return 0 }
        var i = offset
        // If currently on whitespace or about to leave a run, advance to the
        // start of the next run first.
        if i < chars.count, isWhitespace(chars[i]) {
            while i < chars.count, isWhitespace(chars[i]) { i += 1 }
        } else if i + 1 < chars.count, charClass(chars[i + 1]) != charClass(chars[i]) {
            i += 1
            while i < chars.count, isWhitespace(chars[i]) { i += 1 }
        }
        guard i < chars.count else { return chars.count - 1 }
        let cls = charClass(chars[i])
        while i + 1 < chars.count, charClass(chars[i + 1]) == cls, !isWhitespace(chars[i + 1]) {
            i += 1
        }
        return i
    }
}
