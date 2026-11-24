import Foundation

/// What a structured view (board, canvas) needs from a live note session
/// (CRDT-CLIENT-PROTOCOL §2): the document plus its join state. Read-only
/// until the first SyncStep2 (`hasSynced`); `emptyAtSync` with a non-empty
/// REST body is the legacy uninitialised note (§2.2.5).
@MainActor
public protocol StructuredSession: CollaborativeDocument {
    var phase: EditorSnapshot.Phase { get }
    var hasSynced: Bool { get }
    var emptyAtSync: Bool { get }
    var termination: SessionTermination? { get }
    var peers: [PeerPresence] { get }
    var isDestroyed: Bool { get }
    /// "Load file contents" (§2.2.5), explicit user action.
    func initialiseFromFile(_ body: String) -> Bool
}

extension OpenNoteSession: StructuredSession {}

public extension StructuredSession {
    /// Toolbar status (web `StructuredNoteView` parity), nil when live
    /// and alone.
    var structuredStatus: String? {
        if termination == .lineageChanged { return "conflict copy saved" }
        if termination != nil { return "live editing unavailable" }
        if !isEditable { return "connecting… (read-only)" }
        if phase != .live { return "offline" }
        return peers.isEmpty ? nil : "\(peers.count + 1) editing"
    }
}
