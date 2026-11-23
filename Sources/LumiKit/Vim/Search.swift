import Foundation

/// `/` and `?` — regex search direction.
public enum SearchDirection: Sendable, Hashable {
    case forward
    case backward

    public var reversed: SearchDirection {
        switch self {
        case .forward: return .backward
        case .backward: return .forward
        }
    }

    public static func from(prefix: Character) -> SearchDirection? {
        switch prefix {
        case "/": return .forward
        case "?": return .backward
        default: return nil
        }
    }
}

/// Memory of the most recent successful search (`n`, `N`, empty `/<CR>`).
public struct SearchMemory: Sendable, Hashable {
    public let pattern: String
    public let direction: SearchDirection

    public init(pattern: String, direction: SearchDirection) {
        self.pattern = pattern
        self.direction = direction
    }
}

/// Case handling for searches (`ignorecase`, `smartcase`).
public struct SearchCaseOptions: Sendable, Hashable {
    public var ignorecase: Bool
    public var smartcase: Bool

    public init(ignorecase: Bool = true, smartcase: Bool = true) {
        self.ignorecase = ignorecase
        self.smartcase = smartcase
    }

    public static let standard = SearchCaseOptions()
}

/// Compile a vim pattern (magic syntax: `\<word\>`, `\(group\)`, `a\+`,
/// `x\{2,3}`, `\v` very-magic, `\c` / `\C`) into an `NSRegularExpression`
/// with `^` / `$` matching at line boundaries. nil when it doesn't compile.
public func compileVimPattern(_ pattern: String, case caseOptions: SearchCaseOptions = .standard) -> NSRegularExpression? {
    let analysis = analyzeCaseFlags(pattern, options: caseOptions)
    guard !analysis.effectivePattern.isEmpty else { return nil }
    var opts: NSRegularExpression.Options = [.anchorsMatchLines]
    if analysis.caseInsensitive { opts.insert(.caseInsensitive) }
    return try? NSRegularExpression(pattern: VimRegex.translate(analysis.effectivePattern), options: opts)
}

/// Next match of `pattern` from `charOffset` (character offsets), wrapping
/// at the buffer ends. Forward skips a match starting at the cursor;
/// backward takes the last match starting before it.
public func nextMatch(
    in text: String,
    pattern: String,
    from charOffset: Int,
    direction: SearchDirection,
    case caseOptions: SearchCaseOptions = .standard
) -> Range<Int>? {
    nextMatchWrapping(in: text, pattern: pattern, from: charOffset, direction: direction, case: caseOptions)?.range
}

/// Like `nextMatch`, also reporting whether the search wrapped.
func nextMatchWrapping(
    in text: String,
    pattern: String,
    from charOffset: Int,
    direction: SearchDirection,
    case caseOptions: SearchCaseOptions = .standard
) -> (range: Range<Int>, wrapped: Bool)? {
    guard !pattern.isEmpty, let regex = compileVimPattern(pattern, case: caseOptions) else { return nil }
    let nsText = text as NSString
    guard nsText.length > 0 else { return nil }
    let cursorUTF16 = utf16Offset(in: text, characterOffset: charOffset)
    let all = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    switch direction {
    case .forward:
        if let m = all.first(where: { $0.range.location > cursorUTF16 }), let r = characterRange(in: text, utf16Range: m.range) {
            return (r, false)
        }
        if let m = all.first, let r = characterRange(in: text, utf16Range: m.range) { return (r, true) }
    case .backward:
        if let m = all.last(where: { $0.range.location < cursorUTF16 }), let r = characterRange(in: text, utf16Range: m.range) {
            return (r, false)
        }
        if let m = all.last, let r = characterRange(in: text, utf16Range: m.range) { return (r, true) }
    }
    return nil
}

struct CaseFlagAnalysis: Sendable, Hashable {
    let effectivePattern: String
    let caseInsensitive: Bool
}

/// Strip `\c` / `\C` and decide case sensitivity: `\C` wins, then `\c`,
/// then `ignorecase` + `smartcase` (insensitive unless the pattern has an
/// upper-case letter that is not part of an escape like `\S`).
func analyzeCaseFlags(_ pattern: String, options: SearchCaseOptions = .standard) -> CaseFlagAnalysis {
    var stripped = ""
    stripped.reserveCapacity(pattern.count)
    var sawSensitive = false
    var sawInsensitive = false
    var hasUpper = false
    var it = pattern.makeIterator()
    while let c = it.next() {
        guard c == "\\" else {
            if c.isUppercase { hasUpper = true }
            stripped.append(c)
            continue
        }
        guard let next = it.next() else {
            stripped.append(c)
            break
        }
        switch next {
        case "C": sawSensitive = true
        case "c": sawInsensitive = true
        default:
            stripped.append(c)
            stripped.append(next)
        }
    }
    let insensitive: Bool
    if sawSensitive { insensitive = false }
    else if sawInsensitive { insensitive = true }
    else if !options.ignorecase { insensitive = false }
    else { insensitive = !(options.smartcase && hasUpper) }
    return CaseFlagAnalysis(effectivePattern: stripped, caseInsensitive: insensitive)
}

/// Every match of `pattern` (character offsets) — hlsearch.
public func allMatches(in text: String, pattern: String, case caseOptions: SearchCaseOptions = .standard) -> [Range<Int>] {
    guard !pattern.isEmpty, let regex = compileVimPattern(pattern, case: caseOptions) else { return [] }
    let nsText = text as NSString
    guard nsText.length > 0 else { return [] }
    var results: [Range<Int>] = []
    regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
        guard let match, match.range.length > 0 else { return }
        if let range = characterRange(in: text, utf16Range: match.range) { results.append(range) }
    }
    return results
}

/// Every match of `pattern` as UTF-16 ranges (the editor's coordinate
/// space) — avoids the character conversion for highlighting.
public func allMatchesUTF16(in text: String, pattern: String, case caseOptions: SearchCaseOptions = .standard) -> [NSRange] {
    guard !pattern.isEmpty, let regex = compileVimPattern(pattern, case: caseOptions) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        .map(\.range).filter { $0.length > 0 }
}

func utf16Offset(in text: String, characterOffset: Int) -> Int {
    let safe = max(0, min(characterOffset, text.count))
    return text.index(text.startIndex, offsetBy: safe).utf16Offset(in: text)
}

func characterRange(in text: String, utf16Range: NSRange) -> Range<Int>? {
    let u = text.utf16
    guard let s16 = u.index(u.startIndex, offsetBy: utf16Range.location, limitedBy: u.endIndex),
          let e16 = u.index(u.startIndex, offsetBy: utf16Range.location + utf16Range.length, limitedBy: u.endIndex)
    else { return nil }
    let start = text.distance(from: text.startIndex, to: s16.samePosition(in: text) ?? roundDown(s16, in: text))
    let end = text.distance(from: text.startIndex, to: e16.samePosition(in: text) ?? roundDown(e16, in: text))
    return start..<max(start, end)
}

private func roundDown(_ idx: String.Index, in text: String) -> String.Index {
    var i = idx
    while i > text.startIndex, i.samePosition(in: text) == nil { i = text.utf16.index(before: i) }
    return i
}

/// Vim regex (magic) → ICU regex.
enum VimRegex {
    static func translate(_ pattern: String) -> String {
        var out = ""
        let chars = Array(pattern)
        var i = 0
        var veryMagic = false
        var noMagic = false
        while i < chars.count {
            let c = chars[i]
            if c == "[" && !noMagic {
                // Copy a character class verbatim (escaping nested `[`).
                var j = i + 1
                var cls = "["
                if j < chars.count, chars[j] == "^" { cls.append("^"); j += 1 }
                if j < chars.count, chars[j] == "]" { cls.append("\\]"); j += 1 }
                var closed = false
                while j < chars.count {
                    let d = chars[j]
                    if d == "]" { closed = true; break }
                    if d == "\\", j + 1 < chars.count { cls.append(d); cls.append(chars[j + 1]); j += 2; continue }
                    if d == "[" { cls.append("\\[") } else { cls.append(d) }
                    j += 1
                }
                if closed {
                    out += cls + "]"
                    i = j + 1
                } else {
                    out += "\\["
                    i += 1
                }
                continue
            }
            if c == "\\", i + 1 < chars.count {
                let d = chars[i + 1]
                i += 2
                switch d {
                case "v": veryMagic = true; noMagic = false
                case "m", "M": veryMagic = false; noMagic = false
                case "V": noMagic = true; veryMagic = false
                case "<", ">": out += veryMagic ? "\\" + String(d) : "\\b"
                case "(": out += veryMagic ? "\\(" : "("
                case ")": out += veryMagic ? "\\)" : ")"
                case "%":
                    if !veryMagic, i < chars.count, chars[i] == "(" { out += "(?:"; i += 1 } else { out += "%" }
                case "|": out += veryMagic ? "\\|" : "|"
                case "+": out += veryMagic ? "\\+" : "+"
                case "?", "=": out += veryMagic ? "\\" + String(d) : "?"
                case "{":
                    if veryMagic { out += "\\{" } else {
                        // \{n,m}  \{-}  \{-n,m}
                        var j = i
                        var body = ""
                        while j < chars.count, chars[j] != "}" { body.append(chars[j]); j += 1 }
                        if j < chars.count {
                            if j > 0, chars[j - 1] == "\\" { body.removeLast() }
                            i = j + 1
                            out += quantifier(body)
                        } else {
                            out += "\\{"
                        }
                    }
                case "}": out += "\\}"
                case "a": out += "[A-Za-z]"
                case "A": out += "[^A-Za-z]"
                case "l": out += "[a-z]"
                case "L": out += "[^a-z]"
                case "u": out += "[A-Z]"
                case "U": out += "[^A-Z]"
                case "h": out += "[A-Za-z_]"
                case "H": out += "[^A-Za-z_]"
                case "x": out += "[0-9A-Fa-f]"
                case "X": out += "[^0-9A-Fa-f]"
                case "o": out += "[0-7]"
                case "e": out += "\\x{1b}"
                case "_":
                    if i < chars.count, chars[i] == "s" { out += "\\s"; i += 1 } else { out += "_" }
                case "/": out += "/"
                case "~": out += "~"
                case "*", ".", "[", "]":
                    out += noMagic && (d == "*" || d == ".") ? String(d) : "\\" + String(d)
                default:
                    out += "\\" + String(d)
                }
                continue
            }
            if noMagic {
                out += NSRegularExpression.escapedPattern(for: String(c))
                i += 1
                continue
            }
            switch c {
            case "(", ")", "|", "+", "?", "{", "}", "=":
                if veryMagic {
                    if c == "=" { out += "?" }
                    else if c == "{" {
                        var j = i + 1
                        var body = ""
                        while j < chars.count, chars[j] != "}" { body.append(chars[j]); j += 1 }
                        if j < chars.count { out += quantifier(body); i = j + 1; continue }
                        out += "\\{"
                    } else { out += String(c) }
                } else {
                    out += c == "=" ? "=" : "\\" + String(c)
                }
            case "<", ">":
                out += veryMagic ? "\\b" : String(c)
            case "~":
                out += "\\~"
            default:
                out.append(c)
            }
            i += 1
        }
        return out
    }

    private static func quantifier(_ body: String) -> String {
        var b = body
        var lazy = false
        if b.hasPrefix("-") { lazy = true; b.removeFirst() }
        let q: String
        if b.isEmpty { q = "*" }
        else if b.hasPrefix(",") { q = "{0" + b + "}" }
        else { q = "{" + b + "}" }
        return lazy ? q + "?" : q
    }
}

/// Escape text so it matches literally in a vim (magic) pattern.
func escapeVimPattern(_ s: String) -> String {
    var out = ""
    for c in s {
        if "\\/.*$^~[]".contains(c) { out.append("\\") }
        out.append(c)
    }
    return out
}

extension VimEngine {
    /// Search `count` times from `from`; sets the wrap / not-found message.
    static func searchTarget(
        doc: Doc,
        pattern: String,
        from: Int,
        direction: SearchDirection,
        count: Int,
        state: inout VimState,
        smartcase: Bool = true
    ) -> Int? {
        var opts = SearchCaseOptions(ignorecase: state.options.ignorecase, smartcase: state.options.smartcase && smartcase)
        if !smartcase { opts.smartcase = false }
        guard compileVimPattern(pattern, case: opts) != nil else {
            state.message = VimMessage("E486: Pattern not found: \(pattern)", isError: true)
            return nil
        }
        var pos = from
        var wrapped = false
        for _ in 0..<max(1, count) {
            guard let hit = nextMatchWrapping(in: doc.string, pattern: pattern, from: pos, direction: direction, case: opts) else {
                state.message = VimMessage("E486: Pattern not found: \(pattern)", isError: true)
                return nil
            }
            if hit.wrapped { wrapped = true }
            pos = hit.range.lowerBound
        }
        if wrapped {
            state.message = VimMessage(direction == .forward ? "search hit BOTTOM, continuing at TOP" : "search hit TOP, continuing at BOTTOM", isError: true)
        }
        return pos
    }

    static func appendSearchHistory(_ entry: String, state: inout VimState) {
        guard !entry.isEmpty, state.searchHistory.last != entry else { return }
        state.searchHistory.append(entry)
        if state.searchHistory.count > VimState.commandLineHistoryLimit {
            state.searchHistory.removeFirst(state.searchHistory.count - VimState.commandLineHistoryLimit)
        }
    }
}
