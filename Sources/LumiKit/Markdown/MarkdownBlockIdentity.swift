import Foundation

/// Stable identity for one block of a `MarkdownDocument`.
///
/// Identity is `(content hash, occurrence)`: the hash of the block's full
/// value plus how many identical blocks precede it. That makes ids
/// stable under the edits that matter for rendering:
///
/// - inserting / deleting a block shifts *positions* but not the ids of
///   the untouched blocks around it (unlike `ForEach(id: \.offset)`,
///   which re-binds every later row's `@State` to a different block);
/// - two byte-identical blocks (e.g. two `---` rules) still get distinct
///   ids via `occurrence`, so `ForEach` never sees duplicates.
///
/// `contentHash` uses Swift's per-process seeded `Hasher`, so ids are
/// stable within a run (all the renderer caches need) but must not be
/// persisted.
public struct MarkdownBlockID: Hashable, Sendable, CustomStringConvertible {
    public let contentHash: Int
    public let occurrence: Int

    public init(contentHash: Int, occurrence: Int) {
        self.contentHash = contentHash
        self.occurrence = occurrence
    }

    public var description: String { "\(String(UInt(bitPattern: contentHash), radix: 36))#\(occurrence)" }
}

public enum MarkdownBlockIdentity {
    /// Ids for `blocks`, index-aligned. O(n) in the block count plus the
    /// cost of hashing each block once.
    public static func ids(for blocks: [MarkdownBlock]) -> [MarkdownBlockID] {
        var seen: [Int: Int] = [:]
        seen.reserveCapacity(blocks.count)
        return blocks.map { block in
            let hash = block.hashValue
            let occurrence = seen[hash, default: 0]
            seen[hash] = occurrence + 1
            return MarkdownBlockID(contentHash: hash, occurrence: occurrence)
        }
    }

    /// Minimal contiguous replacement turning `old` into `new`: the
    /// common prefix and suffix are kept, everything between is
    /// replaced. A single-block edit (the common case — typing, a sync
    /// patch) therefore touches exactly one block. Worst case
    /// (everything changed) degrades to a full replace, never to
    /// incorrect output.
    public struct Splice: Equatable, Sendable {
        /// Number of leading blocks shared by both sides.
        public let prefix: Int
        /// Range of `old` indices to remove.
        public let removed: Range<Int>
        /// Range of `new` indices to insert in their place.
        public let inserted: Range<Int>

        public init(prefix: Int, removed: Range<Int>, inserted: Range<Int>) {
            self.prefix = prefix
            self.removed = removed
            self.inserted = inserted
        }

        public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty }
    }

    public static func splice(from old: [MarkdownBlockID], to new: [MarkdownBlockID]) -> Splice {
        var prefix = 0
        let maxPrefix = min(old.count, new.count)
        while prefix < maxPrefix, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        let maxSuffix = min(old.count, new.count) - prefix
        while suffix < maxSuffix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        return Splice(
            prefix: prefix,
            removed: prefix..<(old.count - suffix),
            inserted: prefix..<(new.count - suffix)
        )
    }
}

public extension MarkdownDocument {
    /// See `MarkdownBlockIdentity.ids(for:)`.
    var blockIDs: [MarkdownBlockID] { MarkdownBlockIdentity.ids(for: blocks) }
}
