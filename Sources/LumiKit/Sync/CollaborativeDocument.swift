import Foundation

/// A change the replica asks the editor to replay.
public enum DocumentChange: Sendable, Equatable {
    /// A peer's update (or a merged REST snapshot): sequential ranged
    /// edits. Map the caret/selection through them; not undoable.
    case remote([TextEdit])
    /// This user's undo/redo, already applied to the replica. Move the
    /// caret to the first edit.
    case undo([TextEdit])
    /// The editor and the replica disagreed (should never happen):
    /// replace the editor text wholesale.
    case resync(String)
}

/// What an editor binds to when it edits a collaborative note. The
/// editor is the single owner of its text buffer; it pushes every local
/// edit here as ranged ops and replays `changeHandler` changes in place.
@MainActor
public protocol CollaborativeDocument: AnyObject {
    /// Replica text, read once when the editor mounts (§2.2.4: an editor
    /// must start from the Y.Text, never empty).
    var text: String { get }
    /// False before the first SyncStep2 (§2.2.3) and for read-only
    /// sessions. Editors must refuse input while false.
    var isEditable: Bool { get }
    /// Set by the mounted editor. Called synchronously on the main actor
    /// for every non-local change.
    var changeHandler: ((DocumentChange) -> Void)? { get set }
    /// Apply local ranged edits (UTF-16, sequential) in one transaction.
    func applyLocal(_ edits: [TextEdit])
    /// CRDT undo/redo of this user's own change groups (§8). The edits
    /// come back through `changeHandler` as `.undo`.
    @discardableResult func undo() -> Bool
    @discardableResult func redo() -> Bool
    /// Close the current undo group (vim change boundary).
    func breakUndoGroup()
}

/// Why a session stopped for good (§5 fatal closes).
public enum SessionTermination: Sendable, Equatable {
    /// 4401 / probe 401 / ticket 401: token dead → sign in again.
    case unauthorized
    /// 4403 / auth permission-denied: no `note.edit` → read-only.
    case forbidden
    /// 4404: note deleted.
    case notFound
    /// 1008: per-user concurrent socket cap.
    case policy
    /// No server URL / token configured.
    case notConfigured
    /// The persisted replica belongs to another CRDT lineage than the
    /// server's doc (note recreated, CRDT reset): it was not merged. The
    /// store replaces the session with a fresh one (`ReplicaConflict`).
    case lineageChanged
}

