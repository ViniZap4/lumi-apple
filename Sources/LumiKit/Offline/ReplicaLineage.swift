import Foundation

/// Lineage guard for persisted replicas: a replica must never be merged
/// into a *different* CRDT history of the "same" note (deleted and
/// recreated with the same id, server CRDT reset or restored from an
/// older backup, vault re-created, account switched).
///
/// The server has no explicit doc generation, so the guard combines two
/// facts it already exposes — no server change needed:
///
/// 1. **Identity stamp** — `notes.created_at` from `GET
///    /api/vaults/:vault/notes/:id`, recorded when the replica first
///    synced. The row keeps it for life (`Upsert` never rewrites it); a
///    delete + recreate inserts a new row with a new stamp. Checked
///    before dialing.
/// 2. **State-vector dominance** — inside one lineage a Yjs doc's state
///    vector only grows (GC and compaction keep clocks). The replica
///    records every vector the server provably held (its SyncStep1 at
///    join, plus each probe-acknowledged state). On reconnect the
///    server's SyncStep1 vector MUST dominate that record; a reset,
///    recreated (fresh random clientIDs) or rolled-back doc fails. This
///    catches CRDT resets that keep the note row (lazy re-init, §10 S4).
///
/// Vault re-creation and account switches never even reach the guard:
/// the replica key is `(server, account, vault_id, note_id)`.
///
/// Residual blind spot (documented): a note whose server doc was *empty*
/// and never edited when we last synced (acknowledged vector empty)
/// relies on the stamp alone, so a recreate within the same second
/// (stamp resolution) would pass. A mismatch is never merged: the local
/// text becomes a `RecoveredNote` ("<title> (conflito offline)").
public enum ReplicaLineage {
    /// Same server doc history: the server's current vector dominates
    /// everything it ever acknowledged to this replica.
    public static func sameLineage(serverSV: StateVector, acknowledged: StateVector) -> Bool {
        serverSV.dominates(acknowledged)
    }

    /// `created_at` travels with second resolution (RFC 3339).
    public static func sameStamp(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince1970 - b.timeIntervalSince1970) < 1
    }
}

/// A persisted replica that could not be merged.
public struct ReplicaConflict: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The server's doc is another lineage than the replica's.
        case lineageChanged
        /// The note was deleted on the server while edits were pending.
        case noteDeleted
    }

    public var reason: Reason
    public var vaultID: UUID
    public var noteID: String
    /// Replica text at the time of the mismatch.
    public var text: String
    /// True when the replica carried unacknowledged local edits; only
    /// then is there anything to recover.
    public var hadPendingChanges: Bool
    public var title: String?
    public var path: String?

    public init(reason: Reason, vaultID: UUID, noteID: String, text: String, hadPendingChanges: Bool,
                title: String? = nil, path: String? = nil) {
        self.reason = reason
        self.vaultID = vaultID
        self.noteID = noteID
        self.text = text
        self.hadPendingChanges = hadPendingChanges
        self.title = title
        self.path = path
    }

    public var recoveredReason: RecoveredNote.Reason {
        switch reason {
        case .lineageChanged: return .lineageChanged
        case .noteDeleted: return .noteDeleted
        }
    }
}
