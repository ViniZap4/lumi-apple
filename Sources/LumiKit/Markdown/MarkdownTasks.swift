import Foundation

/// GFM task markers (`- [ ]` / `- [x]`) in markdown source: where they
/// are and the single-character edit that toggles one. Mirrors the web
/// client's `taskMarkers` / `taskToggle` so every client counts tasks
/// the same way (document order, fenced code skipped) — the reader's
/// N-th checkbox is the N-th marker here.
public enum MarkdownTasks {
    private static let taskLine = try! NSRegularExpression(
        pattern: "^(\\s*(?:>\\s*)*(?:[-*+]|\\d{1,9}[.)])\\s+)\\[([ xX])\\](?=\\s|$)"
    )
    private static let fence = try! NSRegularExpression(pattern: "^\\s{0,3}(`{3,}|~{3,})")

    /// Per line: inside a fenced code block (fence lines included).
    public static func codeLines(_ lines: [String]) -> [Bool] {
        var out: [Bool] = []
        out.reserveCapacity(lines.count)
        var open: String?
        for line in lines {
            let ns = line as NSString
            let m = fence.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
            let run = m.map { ns.substring(with: $0.range(at: 1)) }
            if let f = open {
                out.append(true)
                if let run, run.first == f.first, run.count >= f.count { open = nil }
            } else if let run {
                open = run
                out.append(true)
            } else {
                out.append(false)
            }
        }
        return out
    }

    /// UTF-16 offsets of the character inside each task marker, in
    /// document order.
    public static func markers(in src: String) -> [Int] {
        var out: [Int] = []
        let lines = src.components(separatedBy: "\n")
        let code = codeLines(lines)
        var offset = 0
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            if !code[i], let m = taskLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                out.append(offset + m.range(at: 1).length + 1)
            }
            offset += ns.length + 1
        }
        return out
    }

    /// The ranged edit (one UTF-16 unit) that toggles task `index`, or
    /// nil when there is no such task.
    public static func toggle(in src: String, index: Int) -> TextEdit? {
        let all = markers(in: src)
        guard index >= 0, index < all.count else { return nil }
        let pos = all[index]
        let ns = src as NSString
        guard pos < ns.length else { return nil }
        let current = ns.substring(with: NSRange(location: pos, length: 1))
        return TextEdit(location: pos, length: 1, replacement: current == " " ? "x" : " ")
    }
}

/// Small text helpers shared by the reader and the editor chrome.
public enum MarkdownText {
    /// Words: runs of letters / digits in any script, so `**bold**`, `#`
    /// and list markers don't count (web `countWords`).
    public static func wordCount(_ text: String) -> Int {
        var n = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let props = scalar.properties
            let isWordStart = props.isAlphabetic || props.numericType != nil
            if inWord {
                if isWordStart || scalar == "'" || scalar == "\u{2019}" || scalar == "_" || scalar == "-" { continue }
                inWord = false
            } else if isWordStart {
                inWord = true
                n += 1
            }
        }
        return n
    }

    /// Reading time in whole minutes (≈230 wpm), at least 1 for any text.
    public static func readingMinutes(words: Int, wpm: Int = 230) -> Int {
        words <= 0 ? 0 : max(1, Int((Double(words) / Double(wpm)).rounded()))
    }

    /// Whether the body opens with a level-1 heading equal to `title`
    /// (ignoring case, spacing, emphasis marks and closing `#`s) — the
    /// reader then skips its own title so it isn't printed twice.
    public static func startsWithTitle(_ src: String, title: String) -> Bool {
        let want = normTitle(title)
        guard !want.isEmpty else { return false }
        let body = src.hasPrefix("\u{FEFF}") ? String(src.dropFirst()) : src
        guard let first = body.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        var line = Substring(first)
        var lead = 0
        while line.first == " ", lead < 3 { line = line.dropFirst(); lead += 1 }
        guard line.first == "#" else { return false }
        line = line.dropFirst()
        guard let sp = line.first, sp == " " || sp == "\t" else { return false }
        var text = line.trimmingCharacters(in: .whitespaces)
        // Closing `#`s (`# Title ##`).
        if let r = text.range(of: "[ \\t]+#+$", options: .regularExpression) { text.removeSubrange(r) }
        return normTitle(text) == want
    }

    private static func normTitle(_ s: String) -> String {
        s.filter { !"*_`~".contains($0) }
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .lowercased()
    }

    /// Heading slug (`h-` prefixed, like the web's anchors).
    public static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        var pendingDash = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else if ch.isWhitespace || ch == "-" {
                pendingDash = true
            }
            if out.count >= 64 { break }
        }
        return "h-" + (out.isEmpty ? "section" : out)
    }
}
