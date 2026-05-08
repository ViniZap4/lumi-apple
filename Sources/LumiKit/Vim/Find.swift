import Foundation

/// `f F t T` — find/till motions, all line-scoped (don't cross newlines).
public enum FindKind: Sendable, Hashable {
    case forwardOnto    // f<c> — first occurrence forward, on it
    case backwardOnto   // F<c> — first occurrence backward, on it
    case forwardBefore  // t<c> — first occurrence forward, just before
    case backwardAfter  // T<c> — first occurrence backward, just after
}

public extension FindKind {
    static func from(char: Character) -> FindKind? {
        switch char {
        case "f": return .forwardOnto
        case "F": return .backwardOnto
        case "t": return .forwardBefore
        case "T": return .backwardAfter
        default: return nil
        }
    }

    /// Find the *target character's* position on the cursor's line. All four
    /// kinds share this scan; cursor placement and operator range are derived
    /// from it via `cursorPosition(of:)` and `operatorRange(cursor:targetChar:)`.
    func locateTargetChar(in buffer: TextBuffer, target: Character, count: Int = 1) -> Int? {
        let chars = Array(buffer.text)
        guard !chars.isEmpty else { return nil }
        let cursor = max(0, min(buffer.cursor, chars.count - 1))
        let lineStart = lineStartOffset(buffer: buffer, cursor: cursor)
        let lineEnd = lineEndOffset(buffer: buffer, cursor: cursor)
        let n = max(1, count)

        switch self {
        case .forwardOnto, .forwardBefore:
            return scanForward(chars: chars, from: cursor + 1, to: lineEnd, target: target, count: n)
        case .backwardOnto, .backwardAfter:
            return scanBackward(chars: chars, from: cursor - 1, to: lineStart, target: target, count: n)
        }
    }

    /// Where the cursor lands for a plain motion (no operator). `f`/`F` land
    /// on the target; `t` stops one before, `T` one after.
    func cursorPosition(ofTargetChar target: Int) -> Int {
        switch self {
        case .forwardOnto, .backwardOnto: return target
        case .forwardBefore: return target - 1
        case .backwardAfter: return target + 1
        }
    }

    /// Half-open operator range from `cursor` to the target character.
    /// `f`/`F` include the target; `t`/`T` stop short of it.
    func operatorRange(cursor: Int, targetChar: Int) -> (from: Int, to: Int) {
        switch self {
        case .forwardOnto:
            return (cursor, targetChar + 1)
        case .backwardOnto:
            return (targetChar, cursor + 1)
        case .forwardBefore:
            return (cursor, targetChar)
        case .backwardAfter:
            return (targetChar + 1, cursor + 1)
        }
    }

    private func scanForward(chars: [Character], from: Int, to: Int, target: Character, count: Int) -> Int? {
        var found = 0
        var i = from
        while i < to {
            if chars[i] == target {
                found += 1
                if found == count { return i }
            }
            i += 1
        }
        return nil
    }

    private func scanBackward(chars: [Character], from: Int, to: Int, target: Character, count: Int) -> Int? {
        var found = 0
        var i = from
        while i >= to {
            if chars[i] == target {
                found += 1
                if found == count { return i }
            }
            i -= 1
        }
        return nil
    }

    private func lineStartOffset(buffer: TextBuffer, cursor: Int) -> Int {
        var b = buffer
        b.cursor = cursor
        return b.lineStart(of: b.cursorLine)
    }

    private func lineEndOffset(buffer: TextBuffer, cursor: Int) -> Int {
        var b = buffer
        b.cursor = cursor
        return b.lineEnd(of: b.cursorLine)
    }
}
