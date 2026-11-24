import Foundation

// Minimal ranged text edits for structured note views (kanban board,
// canvas) — port of web-client `lib/text-diff.ts`.
//
// Structured views never write a whole text: they compute the smallest
// differing range against the CURRENT replica text and apply it as
// delete + insert in one transaction (CRDT-CLIENT-PROTOCOL §3.2).
// Offsets are UTF-16 code units, which is what `Y.Text` indexes.
//
// Coordinates: unlike the editor's *sequential* `TextEdit` lists, a
// planner's edits are **disjoint and all in the coordinates of the text
// they were planned against**. `RangedEdits.apply` / `LiveText.apply`
// take them in that form and apply them right to left.

public extension TextEdit {
    /// `[from, to)` replaced by `insert` (the web's `{from, to, insert}`).
    init(from: Int, to: Int, insert: String) {
        self.init(location: from, length: to - from, replacement: insert)
    }

    /// Start of the replaced range (web `from`).
    var from: Int { location }
    /// End of the replaced range (web `to`).
    var to: Int { location + length }
    /// Inserted text (web `insert`).
    var insert: String { replacement }
}

public enum RangedEdits {
    @inline(__always) static func isHigh(_ c: UInt16) -> Bool { c >= 0xD800 && c <= 0xDBFF }
    @inline(__always) static func isLow(_ c: UInt16) -> Bool { c >= 0xDC00 && c <= 0xDFFF }

    /// The single smallest edit turning `a` into `b` (common prefix /
    /// suffix), or nil when they are equal. Never splits a surrogate pair.
    /// `offset` shifts the result, for diffing a slice of a larger text.
    public static func diff(_ a: String, _ b: String, offset: Int = 0) -> TextEdit? {
        if a == b { return nil }
        let x = Array(a.utf16)
        let y = Array(b.utf16)
        if x == y { return nil }
        let maxLen = min(x.count, y.count)
        var p = 0
        while p < maxLen, x[p] == y[p] { p += 1 }
        var s = 0
        let maxS = maxLen - p
        while s < maxS, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        if p > 0, isHigh(x[p - 1]) { p -= 1 }
        if s > 0, isLow(x[x.count - s]) { s -= 1 }
        let insert = String(decoding: y[p..<(y.count - s)], as: UTF16.self)
        return TextEdit(from: offset + p, to: offset + x.count - s, insert: insert)
    }

    /// Edits sorted right to left so earlier offsets stay valid while
    /// applying. Applied in this order they form a valid *sequential* list.
    public static func sortedDescending(_ edits: [TextEdit]) -> [TextEdit] {
        edits.sorted { l, r in l.from != r.from ? l.from > r.from : l.to > r.to }
    }

    /// False when edits overlap (a planner bug).
    public static func isDisjoint(_ edits: [TextEdit]) -> Bool {
        let asc = edits.sorted { l, r in l.from != r.from ? l.from < r.from : l.to < r.to }
        for i in asc.indices.dropFirst() where asc[i].from < asc[i - 1].to { return false }
        return true
    }

    /// Apply disjoint edits (all in original coordinates) to a string.
    /// Overlapping edits are refused (returns `text` unchanged).
    public static func apply(_ edits: [TextEdit], to text: String) -> String {
        guard isDisjoint(edits) else { return text }
        let ns = NSMutableString(string: text)
        for e in sortedDescending(edits) {
            guard e.from >= 0, e.from <= e.to, e.to <= ns.length else { continue }
            ns.replaceCharacters(in: NSRange(location: e.from, length: e.to - e.from), with: e.insert)
        }
        return ns as String
    }

    /// Total UTF-16 units touched (deleted + inserted): a minimality metric.
    public static func cost(_ edits: [TextEdit]) -> Int {
        edits.reduce(0) { $0 + ($1.to - $1.from) + $1.insert.utf16.count }
    }
}
