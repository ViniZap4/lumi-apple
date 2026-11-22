import Foundation
import LumiKit

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Title / tags shown above the body, rendered into the same text flow.
public struct MarkdownHeader: Hashable, Sendable {
    public var title: String
    public var tags: [String]

    public init(title: String, tags: [String] = []) {
        self.title = title
        self.tags = tags
    }
}

/// Process-wide LRU of rendered block fragments keyed by
/// `(block id, style)`. A hit is verified against the stored block value
/// so a hash collision can never surface the wrong text.
@MainActor
final class MarkdownFragmentCache {
    static let shared = MarkdownFragmentCache(capacity: 6_000)

    private struct Key: Hashable {
        let id: MarkdownBlockID
        let style: MarkdownRenderStyle
    }

    private struct Entry {
        let block: MarkdownBlock
        let fragment: NSAttributedString
        var tick: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var tick: UInt64 = 0
    let capacity: Int
    private(set) var hits = 0
    private(set) var misses = 0

    init(capacity: Int) {
        self.capacity = max(16, capacity)
    }

    func fragment(
        id: MarkdownBlockID,
        block: MarkdownBlock,
        style: MarkdownRenderStyle,
        build: () -> NSAttributedString
    ) -> NSAttributedString {
        tick &+= 1
        let key = Key(id: id, style: style)
        if var entry = entries[key], entry.block == block {
            entry.tick = tick
            entries[key] = entry
            hits += 1
            return entry.fragment
        }
        misses += 1
        let made = build()
        entries[key] = Entry(block: block, fragment: made, tick: tick)
        if entries.count > capacity { evictOldestHalf() }
        return made
    }

    func removeAll() {
        entries.removeAll()
        hits = 0
        misses = 0
    }

    var count: Int { entries.count }

    private func evictOldestHalf() {
        let sorted = entries.sorted { $0.value.tick < $1.value.tick }
        for (key, _) in sorted.prefix(entries.count / 2) {
            entries.removeValue(forKey: key)
        }
    }
}

/// Keeps a text storage in sync with a `MarkdownDocument`, re-rendering
/// only what changed.
///
/// The storage is a concatenation of *segments*: an optional header
/// followed by one fragment per top-level block. Each segment has a
/// stable id (`MarkdownBlockIdentity`), so an update is: diff old vs new
/// ids → keep the common prefix/suffix untouched in the storage → splice
/// in fragments for the middle (served from `MarkdownFragmentCache` when
/// the block was rendered before). A one-word edit in a 5k-line note
/// replaces one paragraph; a theme change rebuilds everything (the style
/// is part of every cache key).
@MainActor
final class MarkdownDocumentRenderer {
    struct Update {
        /// Range in the storage *before* the update to replace.
        let range: NSRange
        let replacement: NSAttributedString
        let rebuiltSegments: Int
        let reusedSegments: Int
        let isFullReload: Bool
    }

    private let cache: MarkdownFragmentCache
    private(set) var segmentIDs: [MarkdownBlockID] = []
    private(set) var segmentLengths: [Int] = []
    private(set) var style: MarkdownRenderStyle?
    private var header: MarkdownHeader?
    private var lastDocument: MarkdownDocument?

    init(cache: MarkdownFragmentCache = .shared) {
        self.cache = cache
    }

    private static func headerID(_ header: MarkdownHeader) -> MarkdownBlockID {
        MarkdownBlockID(contentHash: header.hashValue, occurrence: -1)
    }

    /// Computes the storage edit that turns the current state into
    /// `(header, document, style)`. Returns nil when nothing changed —
    /// the host's `update` path is then free, which is what breaks the
    /// old "every SwiftUI update re-sets the text" loop.
    func update(header newHeader: MarkdownHeader?, document: MarkdownDocument, style newStyle: MarkdownRenderStyle) -> Update? {
        // Fast path for the common SwiftUI re-update with identical
        // inputs: `Array ==` short-circuits on a shared buffer, so this
        // is O(1) when the host passes the same parsed document back.
        if newStyle == style, newHeader == header, let lastDocument, lastDocument == document {
            return nil
        }
        defer { lastDocument = document }
        let blockIDs = document.blockIDs
        let newIDs = (newHeader.map { [Self.headerID($0)] } ?? []) + blockIDs
        let headerOffset = newHeader == nil ? 0 : 1

        let styleChanged = newStyle != style
        let splice: MarkdownBlockIdentity.Splice
        if styleChanged {
            splice = .init(prefix: 0, removed: 0..<segmentIDs.count, inserted: 0..<newIDs.count)
        } else {
            splice = MarkdownBlockIdentity.splice(from: segmentIDs, to: newIDs)
            if splice.isEmpty { return nil }
        }

        let builder = MarkdownAttributedBuilder(style: newStyle)
        let replacement = NSMutableAttributedString()
        var newLengths: [Int] = []
        newLengths.reserveCapacity(splice.inserted.count)
        var rebuilt = 0
        var reused = 0
        for index in splice.inserted {
            let fragment: NSAttributedString
            if index < headerOffset, let newHeader {
                fragment = builder.header(title: newHeader.title, tags: newHeader.tags)
                rebuilt += 1
            } else {
                let blockIndex = index - headerOffset
                let before = cache.misses
                fragment = cache.fragment(id: blockIDs[blockIndex], block: document.blocks[blockIndex], style: newStyle) {
                    builder.fragment(for: document.blocks[blockIndex])
                }
                if cache.misses > before { rebuilt += 1 } else { reused += 1 }
            }
            replacement.append(fragment)
            newLengths.append(fragment.length)
        }

        let oldCount = segmentIDs.count
        let start = segmentLengths[..<splice.prefix].reduce(0, +)
        let removedLength = segmentLengths[splice.removed].reduce(0, +)

        segmentLengths.replaceSubrange(splice.removed, with: newLengths)
        segmentIDs = newIDs
        style = newStyle
        header = newHeader

        return Update(
            range: NSRange(location: start, length: removedLength),
            replacement: replacement,
            rebuiltSegments: rebuilt,
            reusedSegments: reused,
            isFullReload: splice.removed == 0..<oldCount && splice.inserted == 0..<newIDs.count
        )
    }

    /// Total storage length the renderer believes it owns.
    var totalLength: Int { segmentLengths.reduce(0, +) }

    /// Forget everything (next update is a full build).
    func reset() {
        segmentIDs = []
        segmentLengths = []
        style = nil
        header = nil
        lastDocument = nil
    }
}

extension NSAttributedString {
    /// Pasteboard text for `range`: attachment characters become their
    /// markdown source, line separators become newlines.
    func lumiCopyText(in range: NSRange) -> String {
        var out = ""
        enumerateAttribute(.lumiSourceText, in: range, options: []) { value, sub, _ in
            if let source = value as? String {
                out += source
            } else {
                out += (string as NSString).substring(with: sub)
            }
        }
        return out
            .replacingOccurrences(of: markdownLineSeparator, with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{00A0}\n", with: "\n")
    }
}
