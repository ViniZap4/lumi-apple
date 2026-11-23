import Foundation

/// Scroll sync between the source editor and the split preview (web
/// `lib/scroll-sync.ts`). The preview's top-level blocks know the source
/// line they start at; measuring their offsets gives a monotonic table
/// line → y, and both directions interpolate linearly inside a block so
/// a long paragraph or code block scrolls the other side smoothly.
public enum ScrollSync {
    public struct Anchor: Equatable, Sendable {
        /// 0-based source line (fractional for the end sentinel).
        public var line: Double
        /// Offset of the block's top in the preview document.
        public var top: Double

        public init(line: Double, top: Double) {
            self.line = line
            self.top = top
        }
    }

    /// Sort, drop non-monotonic anchors, add a start and an end sentinel.
    public static func normalize(_ raw: [Anchor], totalLines: Int, contentHeight: Double) -> [Anchor] {
        let sorted = raw.sorted { $0.line != $1.line ? $0.line < $1.line : $0.top < $1.top }
        var out = [Anchor(line: 0, top: 0)]
        for a in sorted {
            guard let last = out.last else { continue }
            if a.line < last.line || a.top < last.top { continue }
            if a.line == last.line {
                out[out.count - 1].top = max(last.top, a.top)
                continue
            }
            out.append(a)
        }
        let last = out[out.count - 1]
        let endLine = max(Double(totalLines), last.line + 1)
        out.append(Anchor(line: endLine, top: max(contentHeight, last.top)))
        return out
    }

    private static func segment(_ anchors: [Anchor], _ key: (Anchor) -> Double, _ v: Double) -> Int {
        var lo = 0
        var hi = anchors.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if key(anchors[mid]) <= v { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Source line (fractional) → preview offset.
    public static func offset(forLine line: Double, anchors: [Anchor]) -> Double {
        guard let first = anchors.first else { return 0 }
        if line <= first.line { return first.top }
        let i = segment(anchors, { $0.line }, line)
        let a = anchors[i]
        guard i + 1 < anchors.count else { return a.top }
        let b = anchors[i + 1]
        let span = b.line - a.line
        let f = (line - a.line) / (span == 0 ? 1 : span)
        return a.top + f * (b.top - a.top)
    }

    /// Preview offset → source line (fractional).
    public static func line(forOffset top: Double, anchors: [Anchor]) -> Double {
        guard let first = anchors.first else { return 0 }
        if top <= first.top { return first.line }
        let i = segment(anchors, { $0.top }, top)
        let a = anchors[i]
        guard i + 1 < anchors.count else { return a.line }
        let b = anchors[i + 1]
        let span = b.top - a.top
        let f = (top - a.top) / (span == 0 ? 1 : span)
        return a.line + f * (b.line - a.line)
    }

    /// Which pane drives: only the side the user last touched (wheel,
    /// click, key) propagates, so a programmatic scroll of the follower
    /// never echoes back.
    public enum Side: Sendable { case source, preview }

    /// Split preview re-render delay after the last keystroke.
    public static let previewDebounce: Duration = .milliseconds(120)

    /// Divider ratio bounds (editor share of the width).
    public static let ratioRange: ClosedRange<Double> = 0.25...0.75

    public static func clampRatio(_ r: Double) -> Double {
        guard r.isFinite else { return 0.5 }
        return min(ratioRange.upperBound, max(ratioRange.lowerBound, r))
    }
}

/// Hint mode (Vimium style): prefix-free home-row labels for every
/// visible clickable thing (web `lib/hints.ts`).
public enum HintLabels {
    public static let alphabet = Array("asdfghjklqwertyuiopzxcvbnm")

    /// `n` labels, shortest first: single letters while they suffice,
    /// else all the same length (so no label prefixes another).
    public static func make(_ n: Int, alphabet: [Character] = alphabet) -> [String] {
        guard n > 0 else { return [] }
        let k = alphabet.count
        var len = 1
        var cap = k
        while cap < n { len += 1; cap *= k }
        return (0..<n).map { i in
            var s = ""
            var v = i
            for _ in 0..<len {
                s = String(alphabet[v % k]) + s
                v /= k
            }
            return s
        }
    }

    /// Labels still matching `typed`; `hit` when one equals it.
    public static func filter(_ labels: [String], typed: String) -> (live: [Int], hit: Int?) {
        var live: [Int] = []
        var hit: Int?
        for (i, l) in labels.enumerated() {
            if l.hasPrefix(typed) { live.append(i) }
            if l == typed { hit = i }
        }
        return (live, hit)
    }
}
