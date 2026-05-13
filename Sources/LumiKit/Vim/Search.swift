import Foundation

/// `/` and `?` — regex search direction. Used inside `VimMode.commandLine`'s
/// prefix and remembered across uses via `VimState.lastSearch`.
public enum SearchDirection: Sendable, Hashable {
    case forward
    case backward

    /// Direction-flipped variant used by `N` (reverse-repeat last search).
    public var reversed: SearchDirection {
        switch self {
        case .forward: return .backward
        case .backward: return .forward
        }
    }

    /// Map a command-line prefix character (`/` or `?`) to a direction.
    public static func from(prefix: Character) -> SearchDirection? {
        switch prefix {
        case "/": return .forward
        case "?": return .backward
        default: return nil
        }
    }
}

/// Memory of the most recent successful search. Used by `n`, `N`, and by
/// empty-pattern `<CR>` to reuse the prior pattern.
public struct SearchMemory: Sendable, Hashable {
    public let pattern: String
    public let direction: SearchDirection

    public init(pattern: String, direction: SearchDirection) {
        self.pattern = pattern
        self.direction = direction
    }
}

/// Pure regex search over the buffer text. Returns a *character-offset* range
/// (not UTF-16) of the next match, wrapping around at SOF/EOF.
///
/// Case sensitivity follows vim's smartcase: case-insensitive when the pattern
/// is all lowercase; case-sensitive as soon as it contains any uppercase letter.
/// `\C` in the pattern forces sensitive; `\c` forces insensitive. Both flags are
/// stripped before the pattern is compiled.
///
/// Forward semantics: skip the cursor's character itself, scan toward EOF, then
/// wrap to BOF and scan up to (but not including) the cursor's character.
///
/// Backward semantics: scan from BOF up to (not including) the cursor; the
/// last match before the cursor wins. If none, wrap and scan the whole buffer
/// for the last match.
///
/// `nil` is returned for:
///   - empty pattern (or one that becomes empty after stripping \C/\c)
///   - pattern that fails to compile as an `NSRegularExpression`
///   - no match anywhere in the buffer
public func nextMatch(
    in text: String,
    pattern: String,
    from charOffset: Int,
    direction: SearchDirection
) -> Range<Int>? {
    guard !pattern.isEmpty else { return nil }
    let analysis = analyzeCaseFlags(pattern)
    guard !analysis.effectivePattern.isEmpty else { return nil }
    let options: NSRegularExpression.Options = analysis.caseInsensitive ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(pattern: analysis.effectivePattern, options: options) else {
        return nil
    }
    let nsText = text as NSString
    let totalUTF16 = nsText.length
    guard totalUTF16 > 0 else { return nil }

    let cursorUTF16 = utf16Offset(in: text, characterOffset: charOffset)

    switch direction {
    case .forward:
        // Scan forward from just past the cursor, wrap to BOF if no hit.
        let startSearchAt = min(totalUTF16, cursorUTF16 + 1)
        if let m = firstMatch(regex: regex, in: nsText, range: NSRange(location: startSearchAt, length: totalUTF16 - startSearchAt)) {
            return characterRange(in: text, utf16Range: m.range)
        }
        // Wrap: scan from BOF up through the cursor position (inclusive in
        // UTF-16, so a match starting at the cursor itself is found on wrap).
        if let m = firstMatch(regex: regex, in: nsText, range: NSRange(location: 0, length: min(totalUTF16, cursorUTF16 + 1))) {
            return characterRange(in: text, utf16Range: m.range)
        }
        return nil

    case .backward:
        // Vim backward semantics: the match whose START is the largest offset
        // strictly less than the cursor wins. We enumerate matches across the
        // full buffer because a match can start before the cursor and extend
        // past it (e.g. `?bar` from cursor 10 on "bar foo bar" should find the
        // 'bar' at offset 8 even though it extends to 11).
        let allMatches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: totalUTF16))
        if let m = allMatches.last(where: { $0.range.location < cursorUTF16 }) {
            return characterRange(in: text, utf16Range: m.range)
        }
        // Wrap: last match anywhere.
        if let m = allMatches.last {
            return characterRange(in: text, utf16Range: m.range)
        }
        return nil
    }
}

/// Result of stripping vim's case-flag escapes (`\C`, `\c`) from a pattern and
/// deciding effective case sensitivity. `\C` wins over `\c`; absent both,
/// smartcase applies: insensitive unless the pattern contains an uppercase
/// letter. Non-flag backslash escapes (`\d`, `\.`, `\\`, …) pass through
/// untouched.
struct CaseFlagAnalysis: Sendable, Hashable {
    let effectivePattern: String
    let caseInsensitive: Bool
}

func analyzeCaseFlags(_ pattern: String) -> CaseFlagAnalysis {
    var stripped = ""
    stripped.reserveCapacity(pattern.count)
    var sawExplicitSensitive = false
    var sawExplicitInsensitive = false

    var iterator = pattern.makeIterator()
    while let c = iterator.next() {
        guard c == "\\" else {
            stripped.append(c)
            continue
        }
        guard let next = iterator.next() else {
            // Trailing backslash — keep so the regex compiler can decide.
            stripped.append(c)
            break
        }
        switch next {
        case "C":
            sawExplicitSensitive = true
        case "c":
            sawExplicitInsensitive = true
        default:
            stripped.append(c)
            stripped.append(next)
        }
    }

    let caseInsensitive: Bool
    if sawExplicitSensitive {
        caseInsensitive = false
    } else if sawExplicitInsensitive {
        caseInsensitive = true
    } else {
        caseInsensitive = !stripped.contains(where: { $0.isUppercase })
    }
    return CaseFlagAnalysis(effectivePattern: stripped, caseInsensitive: caseInsensitive)
}

/// Enumerate every match of `pattern` in `text`, returning character-offset
/// ranges. Same case-flag rules as `nextMatch` (smartcase + `\C` / `\c`).
/// Used by hlsearch to highlight all occurrences, not just the cursor's
/// destination.
public func allMatches(in text: String, pattern: String) -> [Range<Int>] {
    guard !pattern.isEmpty else { return [] }
    let analysis = analyzeCaseFlags(pattern)
    guard !analysis.effectivePattern.isEmpty else { return [] }
    let options: NSRegularExpression.Options = analysis.caseInsensitive ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(pattern: analysis.effectivePattern, options: options) else {
        return []
    }
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    guard fullRange.length > 0 else { return [] }

    var results: [Range<Int>] = []
    regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
        guard let match, match.range.length > 0 else { return }
        if let range = characterRange(in: text, utf16Range: match.range) {
            results.append(range)
        }
    }
    return results
}

private func firstMatch(regex: NSRegularExpression, in text: NSString, range: NSRange) -> NSTextCheckingResult? {
    guard range.length > 0 else { return nil }
    return regex.firstMatch(in: text as String, options: [], range: range)
}

private func utf16Offset(in text: String, characterOffset: Int) -> Int {
    let safe = max(0, min(characterOffset, text.count))
    return text.prefix(safe).utf16.count
}

private func characterRange(in text: String, utf16Range: NSRange) -> Range<Int>? {
    let utf16Start = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Range.location, limitedBy: text.utf16.endIndex)
    let utf16End = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Range.location + utf16Range.length, limitedBy: text.utf16.endIndex)
    guard let utf16Start, let utf16End,
          let scalarStart = utf16Start.samePosition(in: text),
          let scalarEnd = utf16End.samePosition(in: text)
    else { return nil }
    let start = text.distance(from: text.startIndex, to: scalarStart)
    let end = text.distance(from: text.startIndex, to: scalarEnd)
    return start..<end
}
