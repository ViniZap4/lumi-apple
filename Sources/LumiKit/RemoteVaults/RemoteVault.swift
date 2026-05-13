import Foundation

/// Server-side vault (`GET /api/vaults`, `GET /api/vaults/:id`). Mirrors the
/// server's `vaultDTO`. We model `id` and `createdBy` as Foundation UUIDs;
/// the server emits them as canonical strings.
public struct RemoteVault: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let slug: String
    public let name: String
    public let createdBy: UUID
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, slug, name
        case createdBy = "created_by"
        case createdAt = "created_at"
    }

    public init(id: UUID, slug: String, name: String, createdBy: UUID, createdAt: Date?) {
        self.id = id
        self.slug = slug
        self.name = name
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.slug = try container.decode(String.self, forKey: .slug)
        self.name = try container.decode(String.self, forKey: .name)
        self.createdBy = try container.decode(UUID.self, forKey: .createdBy)
        if let raw = try container.decodeIfPresent(String.self, forKey: .createdAt) {
            self.createdAt = SessionResponse.parseISO8601(raw)
        } else {
            self.createdAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(slug, forKey: .slug)
        try container.encode(name, forKey: .name)
        try container.encode(createdBy, forKey: .createdBy)
        if let createdAt {
            try container.encode(createdAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .createdAt)
        }
    }
}

/// One member of a vault. Mirrors the server's `memberDTO` from
/// `GET /api/vaults/:vault/members`.
public struct RemoteMember: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let vaultID: UUID
    public let userID: UUID
    public let username: String
    public let displayName: String
    public let roleID: UUID
    public let roleName: String
    public let capabilities: [String]
    public let isSeedRole: Bool
    public let joinedAt: Date?

    /// `userID` is unique within a vault — good enough for SwiftUI list IDs.
    public var id: UUID { userID }

    enum CodingKeys: String, CodingKey {
        case vaultID = "vault_id"
        case userID = "user_id"
        case username
        case displayName = "display_name"
        case roleID = "role_id"
        case roleName = "role_name"
        case capabilities
        case isSeedRole = "is_seed_role"
        case joinedAt = "joined_at"
    }

    public init(vaultID: UUID, userID: UUID, username: String, displayName: String,
                roleID: UUID, roleName: String, capabilities: [String],
                isSeedRole: Bool, joinedAt: Date?) {
        self.vaultID = vaultID
        self.userID = userID
        self.username = username
        self.displayName = displayName
        self.roleID = roleID
        self.roleName = roleName
        self.capabilities = capabilities
        self.isSeedRole = isSeedRole
        self.joinedAt = joinedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.vaultID = try c.decode(UUID.self, forKey: .vaultID)
        self.userID = try c.decode(UUID.self, forKey: .userID)
        self.username = try c.decode(String.self, forKey: .username)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.roleID = try c.decode(UUID.self, forKey: .roleID)
        self.roleName = try c.decode(String.self, forKey: .roleName)
        self.capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        self.isSeedRole = try c.decode(Bool.self, forKey: .isSeedRole)
        if let raw = try c.decodeIfPresent(String.self, forKey: .joinedAt) {
            self.joinedAt = SessionResponse.parseISO8601(raw)
        } else {
            self.joinedAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vaultID, forKey: .vaultID)
        try c.encode(userID, forKey: .userID)
        try c.encode(username, forKey: .username)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(roleID, forKey: .roleID)
        try c.encode(roleName, forKey: .roleName)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(isSeedRole, forKey: .isSeedRole)
        if let joinedAt {
            try c.encode(joinedAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .joinedAt)
        }
    }
}

/// A role defined on a vault (`GET /api/vaults/:vault/roles`). Capabilities
/// are stored as raw strings — the apple-client doesn't (yet) parse them into
/// the server's typed `Capability` enum; we treat them as opaque labels.
public struct RemoteRole: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let vaultID: UUID
    public let name: String
    public let capabilities: [String]
    public let isSeed: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case vaultID = "vault_id"
        case name
        case capabilities
        case isSeed = "is_seed"
    }

    public init(id: UUID, vaultID: UUID, name: String, capabilities: [String], isSeed: Bool) {
        self.id = id
        self.vaultID = vaultID
        self.name = name
        self.capabilities = capabilities
        self.isSeed = isSeed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.vaultID = try c.decode(UUID.self, forKey: .vaultID)
        self.name = try c.decode(String.self, forKey: .name)
        self.capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        self.isSeed = try c.decode(Bool.self, forKey: .isSeed)
    }
}
