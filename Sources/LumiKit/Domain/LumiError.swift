import Foundation

/// Top-level error vocabulary surfaced from `LumiKit`. UI layer maps these to
/// human-readable messages.
public enum LumiError: Error, Sendable, Equatable {
    case vaultNotFound(id: UUID)
    case noteNotFound(id: String)
    case bookmarkStale
    case bookmarkInvalid
    case ioFailure(underlying: String)
    case authRequired
    case authInvalid
    case serverUnreachable
    case decodingFailure(underlying: String)
}
