import Foundation

/// One ranged replacement on a text, in **UTF-16 code units** — the
/// offset kind Yjs (`Y.Text`), yrs (`OffsetKind::Utf16`), `NSString`,
/// `NSTextStorage` and `UITextView` all share, so an edit moves between
/// the CRDT and a platform text view without any conversion
/// (CRDT-CLIENT-PROTOCOL §1 "Offsets").
///
/// A list of edits is **sequential**: each edit's coordinates are in the
/// text produced by applying every earlier edit of the list.
public struct TextEdit: Sendable, Equatable, CustomStringConvertible {
    /// UTF-16 offset where the replaced range starts.
    public var location: Int
    /// UTF-16 code units removed at `location`.
    public var length: Int
    /// Text inserted at `location` after the removal.
    public var replacement: String

    public init(location: Int, length: Int, replacement: String) {
        self.location = location
        self.length = length
        self.replacement = replacement
    }

    public var range: NSRange { NSRange(location: location, length: length) }

    /// UTF-16 length of `replacement`.
    public var replacementLength: Int { replacement.utf16.count }

    /// Net change in document length.
    public var delta: Int { replacementLength - length }

    public var isNoOp: Bool { length == 0 && replacement.isEmpty }

    public var description: String {
        "TextEdit(\(location), -\(length), +\(replacement.debugDescription))"
    }

    /// Apply to an `NSMutableString` (UTF-16 native). Returns false (and
    /// leaves the string untouched) when the range is out of bounds.
    @discardableResult
    public func apply(to string: NSMutableString) -> Bool {
        guard location >= 0, length >= 0, location + length <= string.length else { return false }
        string.replaceCharacters(in: range, with: replacement)
        return true
    }

    /// Apply a sequential edit list to `text`. Out-of-range edits are
    /// skipped. O(n) per call — meant for tests and the occasional
    /// resync, not per-keystroke hot paths.
    public static func apply(_ edits: [TextEdit], to text: String) -> String {
        let ns = NSMutableString(string: text)
        for e in edits { e.apply(to: ns) }
        return ns as String
    }
}

/// One element of a Yjs text delta (`event.delta`): retain / insert /
/// delete, lengths in UTF-16 code units.
public enum TextDelta: Sendable, Equatable {
    case retain(Int)
    case insert(String)
    case delete(Int)

    /// Convert a delta into sequential ranged edits at running offsets
    /// (CRDT-CLIENT-PROTOCOL §4.2). A delete directly followed by an
    /// insert at the same offset is fused into one replacement.
    public static func edits(from deltas: [TextDelta]) -> [TextEdit] {
        var out: [TextEdit] = []
        var pos = 0
        for d in deltas {
            switch d {
            case .retain(let n):
                pos += n
            case .delete(let n):
                guard n > 0 else { continue }
                // Adjacent to the previous edit's end → fuse (a delete
                // right after inserted text equals a wider replacement).
                if var last = out.last, last.location + last.replacementLength == pos {
                    last.length += n
                    out[out.count - 1] = last
                } else {
                    out.append(TextEdit(location: pos, length: n, replacement: ""))
                }
            case .insert(let s):
                guard !s.isEmpty else { continue }
                if var last = out.last, last.location + last.replacementLength == pos {
                    last.replacement += s
                    out[out.count - 1] = last
                } else {
                    out.append(TextEdit(location: pos, length: 0, replacement: s))
                }
                pos += s.utf16.count
            }
        }
        return out
    }
}

/// Which neighbour a mapped position sticks to when text is inserted
/// exactly at it — Yjs' `assoc` (`>= 0` → right item, `< 0` → left item).
public enum PositionAssoc: Sendable {
    /// Stick to the character on the right (Yjs default `assoc = 0`):
    /// an insert at the position pushes it forward.
    case after
    /// Stick to the character on the left: an insert at the position
    /// stays after it.
    case before
}

/// Maps editor positions (caret, selection anchor, marks) through a
/// sequential edit list — the change-mapping strategy of
/// CRDT-CLIENT-PROTOCOL §4.3 for editors that receive remote changes as
/// ranged edits (our `NSTextStorage` / `UITextView` path).
///
/// yswift 0.2.1 does not expose yrs `StickyIndex` (relative positions),
/// so live positions are mapped through each remote delta instead. The
/// result is identical to `createRelativePositionFromTypeIndex` →
/// apply → `createAbsolutePositionFromRelativePosition` for every edit
/// we observe (vector V14), because every remote change reaches the
/// editor as a delta. Positions that must survive a session (bookmarks,
/// comment anchors) are out of scope until yswift exposes StickyIndex.
public enum PositionMapper {
    public static func map(_ position: Int, through edits: [TextEdit], assoc: PositionAssoc = .after) -> Int {
        var pos = position
        for e in edits {
            pos = map(pos, through: e, assoc: assoc)
        }
        return pos
    }

    public static func map(_ pos: Int, through e: TextEdit, assoc: PositionAssoc = .after) -> Int {
        let start = e.location
        let end = e.location + e.length
        if pos < start { return pos }
        if e.length == 0 {
            // Pure insertion.
            if pos > start { return pos + e.replacementLength }
            return assoc == .after ? pos + e.replacementLength : pos
        }
        if pos >= end { return pos + e.delta }
        // Inside the removed span: collapse to the edit, after the
        // inserted text when sticking right (the right neighbour is the
        // first surviving character after the replacement).
        return assoc == .after ? start + e.replacementLength : start
    }

    /// Map a selection range (anchor/head) through edits.
    public static func map(_ range: NSRange, through edits: [TextEdit]) -> NSRange {
        if range.length == 0 {
            let p = map(range.location, through: edits, assoc: .after)
            return NSRange(location: p, length: 0)
        }
        let s = map(range.location, through: edits, assoc: .after)
        let e = max(s, map(range.location + range.length, through: edits, assoc: .before))
        return NSRange(location: s, length: e - s)
    }
}

/// Whole-text diffing (CRDT-CLIENT-PROTOCOL §3.2): the smallest single
/// contiguous replacement turning `old` into `new`, in UTF-16 code
/// units, never splitting a surrogate pair (vector V12).
public enum TextDiff {
    public static func edit(from old: String, to new: String) -> TextEdit? {
        let a = old.utf16
        let b = new.utf16
        // Common prefix.
        var ia = a.startIndex
        var ib = b.startIndex
        var p = 0
        while ia != a.endIndex, ib != b.endIndex, a[ia] == b[ib] {
            a.formIndex(after: &ia)
            b.formIndex(after: &ib)
            p += 1
        }
        let na = a.count
        let nb = b.count
        if p == na && p == nb { return nil }
        if p > 0, UTF16.isLeadSurrogate(a[a.index(before: ia)]) {
            p -= 1
            a.formIndex(before: &ia)
            b.formIndex(before: &ib)
        }
        // Common suffix, never overlapping the prefix.
        let maxS = min(na, nb) - p
        var s = 0
        var ja = a.endIndex
        var jb = b.endIndex
        while s < maxS {
            let pa = a.index(before: ja)
            let pb = b.index(before: jb)
            guard a[pa] == b[pb] else { break }
            ja = pa
            jb = pb
            s += 1
        }
        if s > 0, ja != a.endIndex, UTF16.isTrailSurrogate(a[ja]) {
            s -= 1
            a.formIndex(after: &ja)
            b.formIndex(after: &jb)
        }
        let deleteLength = na - p - s
        let insert = String(b[ib..<jb]) ?? ""
        return TextEdit(location: p, length: deleteLength, replacement: insert)
    }
}
