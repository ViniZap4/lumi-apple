import Foundation

/// Lineage guard for persisted replicas: a replica must never be merged
/// into a *different* CRDT history of the "same" note (deleted and
/// recreated with the same id, server CRDT reset or re-initialised from
/// the file, vault re-created, account switched).
///
/// **Primary: the server's `crdt_epoch`.** An opaque id per (vault, note)
/// that the server rotates whenever a new CRDT history starts (create,
/// delete + recreate, lazy init / init from file). It is carried by the
/// note DTO, `/snapshot`, `/diff` and — authoritatively for the doc being
/// joined — the ws-ticket (a ticket whose lineage changed before redeem is
/// refused with 4401). The replica records the epoch it was synced under.
/// When both the replica and the server know an epoch, equality decides
/// alone (`compareEpoch`).
///
/// **Fallback** (server or replica without an epoch — pre-epoch servers,
/// replicas persisted before the upgrade):
///
/// 1. **Identity stamp** — `notes.created_at` from `GET
///    /api/vaults/:vault/notes/:id`, recorded when the replica first
///    synced. A delete + recreate inserts a new row with a new stamp.
///    Checked before dialing.
/// 2. **State-vector dominance** — inside one lineage a Yjs doc's state
///    vector only grows (GC and compaction keep clocks). The replica
///    records every vector the server provably held (its SyncStep1 at
///    join, plus each probe-acknowledged state). On reconnect the
///    server's SyncStep1 vector MUST dominate that record.
///
/// Once the fallback accepts a replica, it adopts the server's epoch so
/// later checks are exact. Fallback blind spot (documented): a doc that
/// was *empty* and never edited when we last synced relies on the stamp
/// alone, so a recreate within the same second would pass.
///
/// A mismatch is never merged: the local text becomes a `RecoveredNote`
/// ("<title> (conflito offline)") and the client closes its socket with
/// the client-side code `closeLineageChanged` (4409).
public enum ReplicaLineage {
    /// Client-side WebSocket close code used when the client drops a
    /// connection because the server doc is another lineage. Never sent
    /// by the server.
    public static let closeLineageChanged = 4409

    public enum EpochVerdict: Sendable, Equatable {
        /// Both epochs known and equal: same history, no further check.
        case same
        /// Both known and different: another history — never merge.
        case changed
        /// At least one side lacks an epoch: use the fallback checks.
        case unknown
    }

    /// Epoch comparison (opaque strings, equality only; empty = absent).
    public static func compareEpoch(replica: String?, server: String?) -> EpochVerdict {
        guard let a = normalized(replica), let b = normalized(server) else { return .unknown }
        return a == b ? .same : .changed
    }

    /// nil for absent or empty epochs.
    public static func normalized(_ epoch: String?) -> String? {
        guard let epoch, !epoch.isEmpty else { return nil }
        return epoch
    }

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
