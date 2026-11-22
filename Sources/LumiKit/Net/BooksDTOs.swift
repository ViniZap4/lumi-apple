import Foundation

/// `GET /api/info` (public, SPEC-LIVROS §3.5). Used by "Add server" to show
/// the name/version and to detect two URLs pointing at the same server
/// (same `public_key`).
public struct ServerInfo: Codable, Sendable, Equatable {
    public let name: String?
    public let version: String?
    public let protocolVersion: Int?
    public let publicKey: String?
    public let registration: String?

    enum CodingKeys: String, CodingKey {
        case name, version, registration
        case protocolVersion = "protocol"
        case publicKey = "public_key"
    }

    public init(name: String?, version: String?, protocolVersion: Int?, publicKey: String?, registration: String?) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
        self.publicKey = publicKey
        self.registration = registration
    }
}

/// `federation` block on a vault row (SPEC-LIVROS §3.5).
public struct VaultFederation: Codable, Sendable, Equatable, Hashable {
    /// `"home"`, `"follower"` or nil (not federated).
    public let role: String?
    public let homeURL: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case role, status
        case homeURL = "home_url"
    }

    public init(role: String?, homeURL: String?, status: String?) {
        self.role = role
        self.homeURL = homeURL
        self.status = status
    }

    public var isHome: Bool { role == "home" }
}

/// `GET /api/vaults/:vault/changes` envelope.
public struct VaultChangesResponse: Decodable, Sendable, Equatable {
    public struct Deleted: Decodable, Sendable, Equatable {
        public let id: String
        public let seq: Int64
    }

    public let notes: [RemoteNote]
    public let deleted: [Deleted]
    public let head: Int64
    public let more: Bool

    enum CodingKeys: String, CodingKey { case notes, deleted, head, more }

    public init(notes: [RemoteNote], deleted: [Deleted], head: Int64, more: Bool) {
        self.notes = notes
        self.deleted = deleted
        self.head = head
        self.more = more
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = try c.decodeIfPresent([RemoteNote].self, forKey: .notes) ?? []
        deleted = try c.decodeIfPresent([Deleted].self, forKey: .deleted) ?? []
        head = try c.decode(Int64.self, forKey: .head)
        more = try c.decodeIfPresent(Bool.self, forKey: .more) ?? false
    }
}

extension LumiAPIError {
    /// `410 {"error":"resync_required","head":N}` from `GET …/changes`.
    public var isResyncRequired: Bool {
        if case let .server(status, _, _) = self, status == 410 { return true }
        if case let .invalidResponse(status) = self, status == 410 { return true }
        return false
    }

    /// True for "this server doesn't have the endpoint" (pre-feed servers).
    public var isEndpointMissing: Bool {
        switch self {
        case let .server(status, _, _), let .invalidResponse(status):
            return status == 404 || status == 405 || status == 501
        default:
            return false
        }
    }

    /// Non-transient failures count toward the "3 strikes → Error" rule
    /// (SPEC-LIVROS §4.1): 5xx, invalid JSON.
    public var isNonTransient: Bool {
        switch self {
        case .decoding: return true
        case let .server(status, _, _), let .invalidResponse(status): return status >= 500
        default: return false
        }
    }
}
