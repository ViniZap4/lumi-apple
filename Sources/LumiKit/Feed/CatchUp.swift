import Foundation

/// Result of bringing one book's note list up to `head`.
public struct CatchUpOutcome: Sendable, Equatable {
    /// Notes created/changed since the cursor (incremental mode).
    public var upserts: [RemoteNote] = []
    /// Note ids deleted since the cursor (tombstones).
    public var deleted: [String] = []
    /// Full list after a `410 resync_required` (replaces the cache).
    public var fullList: [RemoteNote]?
    public var newCursor: Int64
}

/// `GET /api/vaults/:vault/changes?after=cursor` until `more == false`
/// (SPEC-LIVROS §3.5). On `410`: read the head *first* (vault detail),
/// then list every note, and set the cursor to that head — changes that
/// land meanwhile come back on the next pass, and reapplying is idempotent.
public enum CatchUp {
    public static func run(client: LumiAPIClient, vaultID: UUID, cursor: Int64,
                           pageLimit: Int = 500) async throws(LumiAPIError) -> CatchUpOutcome {
        var outcome = CatchUpOutcome(newCursor: cursor)
        var after = cursor
        do {
            while true {
                let page = try await client.vaultChanges(vaultID: vaultID, after: after, limit: pageLimit)
                outcome.upserts.append(contentsOf: page.notes)
                outcome.deleted.append(contentsOf: page.deleted.map(\.id))
                after = max(after, page.head)
                outcome.newCursor = after
                if !page.more { break }
            }
            return outcome
        } catch let error where error.isResyncRequired {
            return try await fullResync(client: client, vaultID: vaultID)
        }
    }

    public static func fullResync(client: LumiAPIClient, vaultID: UUID) async throws(LumiAPIError) -> CatchUpOutcome {
        let head = try await client.vaultDetail(id: vaultID).head ?? 0
        var all: [RemoteNote] = []
        var offset = 0
        let pageSize = 200
        while true {
            let page = try await client.listNotes(vaultID: vaultID, limit: pageSize, offset: offset)
            all.append(contentsOf: page.notes)
            if page.notes.count < pageSize { break }
            offset += page.notes.count
        }
        return CatchUpOutcome(fullList: all, newCursor: head)
    }

    /// Merge an outcome into a cached list (idempotent).
    public static func apply(_ outcome: CatchUpOutcome, to notes: [RemoteNote]) -> [RemoteNote] {
        if let full = outcome.fullList { return full }
        var byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var order = notes.map(\.id)
        for n in outcome.upserts {
            if byID[n.id] == nil { order.append(n.id) }
            byID[n.id] = n
        }
        let gone = Set(outcome.deleted)
        return order.filter { !gone.contains($0) }.compactMap { byID[$0] }
    }
}
