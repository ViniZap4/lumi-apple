import Foundation

/// LRU cache of parsed `MarkdownDocument` values keyed by file URL and
/// modification time. Callers (`MarkdownReader` in the app) check the
/// cache before parsing; a hit on the right `(url, mtime)` pair returns
/// the previously-parsed document instantly. A stale mtime evicts the
/// entry and falls back to parsing.
///
/// The cache lives on the main actor — markdown parsing happens on the
/// UI thread, so contention isn't a concern. We bound the cache so that
/// a user paging through hundreds of notes in a session doesn't blow out
/// memory on a long-running app.
@MainActor
public final class MarkdownDocumentCache {
    public static let shared = MarkdownDocumentCache(capacity: 64)

    private struct Entry {
        var key: String
        var mtime: Date
        var document: MarkdownDocument
    }

    private var entries: [Entry]
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.entries = []
        self.entries.reserveCapacity(self.capacity)
    }

    /// Returns the cached document for `(url, mtime)` if present, else nil.
    /// On hit, the entry moves to the front (LRU touch). On `mtime` drift
    /// the entry is evicted and the lookup misses.
    public func document(for url: URL, mtime: Date) -> MarkdownDocument? {
        let key = url.standardizedFileURL.path
        guard let idx = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries[idx]
        // Compare with millisecond granularity so APFS sub-second
        // resolutions don't cause spurious misses on the same write.
        if abs(entry.mtime.timeIntervalSince(mtime)) > 0.001 {
            entries.remove(at: idx)
            return nil
        }
        // LRU touch — move to front.
        entries.remove(at: idx)
        entries.insert(entry, at: 0)
        return entry.document
    }

    public func store(_ document: MarkdownDocument, for url: URL, mtime: Date) {
        let key = url.standardizedFileURL.path
        entries.removeAll(where: { $0.key == key })
        entries.insert(Entry(key: key, mtime: mtime, document: document), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    /// Drop everything. Used by tests; the app rarely needs this since
    /// the LRU bound keeps growth in check.
    public func clear() {
        entries.removeAll()
    }
}
