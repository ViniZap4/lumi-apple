import Foundation

/// A single peer's presence on a server-vault note. Broadcast over the
/// WS sync channel's awareness frame; the server relays it opaquely
/// (never persists), so a peer's last sent state is canonical until
/// they disconnect or send a new frame.
///
/// Phase H slice 4 ships the shape; the server already fans out
/// awareness frames between subscribers via `Room.BroadcastAwareness`,
/// so no server-side change is needed. The format is lumi-internal
/// JSON (NOT Yjs's canonical lib0 awareness encoding) because yswift
/// 0.2.1 doesn't expose the Awareness type — when we eventually
/// interop with web/Yjs awareness, both sides will need a coordinated
/// migration.
public struct PresenceState: Codable, Sendable, Equatable, Identifiable {
    /// Stable client identity for the duration of the session. Set
    /// once at sign-in; survives reconnects on the same session. Used
    /// to dedupe our own echoes and to key the peer list.
    public let clientID: UUID
    /// Server-canonical username (lowercase). Stable across renames.
    public let username: String
    /// Display name as shown in the UI. Falls back to `username` when
    /// empty.
    public let displayName: String

    /// Hex color (`"#rrggbb"`) assigned to this peer for highlight /
    /// cursor rendering. Deterministically derived from `clientID` so
    /// every observer agrees on the same color without coordination.
    public let color: String

    /// Departure signal. When `true`, the frame is a server-emitted
    /// "this peer just disconnected" notification — observers should
    /// drop the entry from their presence map immediately rather than
    /// waiting on the per-peer TTL. `nil` (the wire default for
    /// regular heartbeat frames) is treated the same as `false`.
    /// Post-H follow-up.
    public let left: Bool?

    public var id: UUID { clientID }

    public init(clientID: UUID, username: String, displayName: String, color: String, left: Bool? = nil) {
        self.clientID = clientID
        self.username = username
        self.displayName = displayName
        self.color = color
        self.left = left
    }

    /// Pick a stable hex color for `clientID` from a small palette.
    /// 12-entry palette chosen so any two peers in a typical session
    /// have visually distinct colors with high probability. Matches
    /// the 12-theme accent set so the presence chips don't clash with
    /// the active theme.
    public static func deriveColor(for clientID: UUID) -> String {
        let palette: [String] = [
            "#7aa2f7", // blue
            "#9ece6a", // green
            "#e0af68", // amber
            "#f7768e", // pink
            "#bb9af7", // purple
            "#7dcfff", // cyan
            "#ff9e64", // orange
            "#73daca", // teal
            "#c0caf5", // lavender
            "#e06c75", // red
            "#d19a66", // gold
            "#56b6c2"  // sea
        ]
        // Fold the 16 UUID bytes into a single byte by XOR — gives a
        // stable, uniform-ish distribution across the palette without
        // pulling in CryptoKit.
        var folded: UInt8 = 0
        let bytes = withUnsafeBytes(of: clientID.uuid) { Data($0) }
        for b in bytes { folded ^= b }
        return palette[Int(folded) % palette.count]
    }

    /// Build a presence state from a logged-in session. Caller supplies
    /// a fresh `clientID` (typically `UUID()` per app launch — different
    /// devices for the same user need to be visible to each other as
    /// distinct peers).
    public static func make(clientID: UUID, username: String, displayName: String) -> PresenceState {
        let resolvedDisplay = displayName.isEmpty ? username : displayName
        return PresenceState(
            clientID: clientID,
            username: username,
            displayName: resolvedDisplay,
            color: deriveColor(for: clientID)
        )
    }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case username
        case displayName = "display_name"
        case color
        case left
    }

    /// Build a synthetic "this peer has left" frame. Mirrors the shape
    /// the server fans out on disconnect — empty user fields, `left:
    /// true`. Useful in tests; production never constructs leave
    /// frames on the client side (servers do).
    public static func makeLeave(clientID: UUID) -> PresenceState {
        PresenceState(
            clientID: clientID,
            username: "",
            displayName: "",
            color: "",
            left: true
        )
    }

    /// JSON-encode for the awareness frame. Uses a stable encoder
    /// (`.sortedKeys`) so byte equality holds across encodes — useful
    /// for the receiver's dedupe path.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    /// Decode a peer's presence from an awareness frame payload.
    /// Throws on malformed/foreign-format input — callers should treat
    /// a throw as "ignore this frame" (a stray frame from a different
    /// presence protocol shouldn't crash the room).
    public static func decoded(from data: Data) throws -> PresenceState {
        try JSONDecoder().decode(PresenceState.self, from: data)
    }
}
