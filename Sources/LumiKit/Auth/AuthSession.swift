import Foundation

/// Persisted server connection state. The token is stored separately in the
/// Keychain (see `Keychain.swift`); this struct is serialized to UserDefaults
/// as a JSON sidecar for the non-secret fields.
public struct AuthSession: Codable, Sendable, Equatable {
    /// The server this session belongs to. Used as the Keychain account key
    /// so multiple servers stay distinct.
    public let serverURL: URL
    /// Cached user info from the most recent `/users/me` call.
    public let user: UserDTO
    /// Optional expiry hint from the server. Not enforced locally — a 401 on
    /// any request invalidates the session regardless.
    public let expiresAt: Date?

    public init(serverURL: URL, user: UserDTO, expiresAt: Date?) {
        self.serverURL = serverURL
        self.user = user
        self.expiresAt = expiresAt
    }
}
