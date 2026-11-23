import Foundation

/// Subsequence fuzzy matcher for the command palette (fzf-style, tiny).
///
/// Every query character must appear in order in the candidate
/// (case- and diacritic-insensitive). The score rewards consecutive runs,
/// matches at word starts (after `/`, space, `-`, `_`, `.` or a
/// lower→upper case change) and a match at the very start; it lightly
/// penalises long candidates so `todo` beats `notes/old/todo-archive`.
public enum FuzzyMatch {
    /// nil when `query` is not a subsequence of `candidate`.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(fold(query).filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let original = Array(candidate)
        let c = Array(fold(candidate))
        guard c.count == original.count else { return substringScore(q, c) }

        var score = 0
        var qi = 0
        var prevMatch = -2
        var run = 0
        for (i, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            var s = 1
            if i == prevMatch + 1 {
                run += 1
                s += 4 * run
            } else {
                run = 0
            }
            if i == 0 {
                s += 8
            } else {
                let before = original[i - 1]
                if "/ -_.".contains(before) {
                    s += 6
                } else if before.isLowercase && original[i].isUppercase {
                    s += 4
                }
            }
            score += s
            prevMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score * 100 - min(c.count, 200)
    }

    /// Candidates whose folding changed their length (rare ligatures):
    /// plain substring test.
    private static func substringScore(_ q: [Character], _ c: [Character]) -> Int? {
        String(c).contains(String(q)) ? 1 : nil
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Rank `items` by `key`, best first; non-matches dropped. Stable for
    /// equal scores.
    public static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return items }
        return items.enumerated()
            .compactMap { pair -> (Int, Int, T)? in
                guard let s = score(q, key(pair.element)) else { return nil }
                return (s, pair.offset, pair.element)
            }
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map(\.2)
    }
}
