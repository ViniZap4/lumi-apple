import Foundation

/// Response from `POST /api/vaults/:vault/invites`. The server emits a
/// shareable `url` when its `LUMI_PUBLIC_BASE_URL` is configured; otherwise
/// the field is omitted and the caller renders just the token.
public struct CreatedInvite: Codable, Sendable, Equatable {
    public let token: String
    public let url: String?
    public let expiresAt: Date?
    public let maxUses: Int
    public let useCount: Int

    enum CodingKeys: String, CodingKey {
        case token, url
        case expiresAt = "expires_at"
        case maxUses = "max_uses"
        case useCount = "use_count"
    }

    public init(token: String, url: String?, expiresAt: Date?, maxUses: Int, useCount: Int) {
        self.token = token; self.url = url; self.expiresAt = expiresAt
        self.maxUses = maxUses; self.useCount = useCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try c.decode(String.self, forKey: .token)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.maxUses = try c.decode(Int.self, forKey: .maxUses)
        self.useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        if let raw = try c.decodeIfPresent(String.self, forKey: .expiresAt) {
            self.expiresAt = SessionResponse.parseISO8601(raw)
        } else {
            self.expiresAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encode(maxUses, forKey: .maxUses)
        try c.encode(useCount, forKey: .useCount)
        try c.encodeIfPresent(url, forKey: .url)
        if let expiresAt {
            try c.encode(expiresAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .expiresAt)
        }
    }
}

/// One row of `GET /api/vaults/:vault/invites`. The list endpoint reports
/// less than create (no `url`) but more than the public preview (caller is
/// already a vault member with `members.invite`).
public struct VaultInvite: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let token: String
    public let vaultID: UUID
    public let roleID: UUID
    public let inviterUserID: UUID
    public let emailHint: String?
    public let maxUses: Int
    public let useCount: Int
    public let expiresAt: Date?
    public let createdAt: Date?
    public let revokedAt: Date?

    public var id: String { token }
    public var isRevoked: Bool { revokedAt != nil }
    public var isExhausted: Bool { maxUses > 0 && useCount >= maxUses }
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }
    public var isActive: Bool { !isRevoked && !isExhausted && !isExpired }

    enum CodingKeys: String, CodingKey {
        case token
        case vaultID = "vault_id"
        case roleID = "role_id"
        case inviterUserID = "inviter_user_id"
        case emailHint = "email_hint"
        case maxUses = "max_uses"
        case useCount = "use_count"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
    }

    public init(token: String, vaultID: UUID, roleID: UUID, inviterUserID: UUID,
                emailHint: String?, maxUses: Int, useCount: Int,
                expiresAt: Date?, createdAt: Date?, revokedAt: Date?) {
        self.token = token; self.vaultID = vaultID; self.roleID = roleID
        self.inviterUserID = inviterUserID; self.emailHint = emailHint
        self.maxUses = maxUses; self.useCount = useCount
        self.expiresAt = expiresAt; self.createdAt = createdAt; self.revokedAt = revokedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try c.decode(String.self, forKey: .token)
        self.vaultID = try c.decode(UUID.self, forKey: .vaultID)
        self.roleID = try c.decode(UUID.self, forKey: .roleID)
        self.inviterUserID = try c.decode(UUID.self, forKey: .inviterUserID)
        self.emailHint = try c.decodeIfPresent(String.self, forKey: .emailHint)
        self.maxUses = try c.decodeIfPresent(Int.self, forKey: .maxUses) ?? 0
        self.useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        self.expiresAt = (try c.decodeIfPresent(String.self, forKey: .expiresAt)).flatMap(SessionResponse.parseISO8601)
        self.createdAt = (try c.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(SessionResponse.parseISO8601)
        self.revokedAt = (try c.decodeIfPresent(String.self, forKey: .revokedAt)).flatMap(SessionResponse.parseISO8601)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encode(vaultID, forKey: .vaultID)
        try c.encode(roleID, forKey: .roleID)
        try c.encode(inviterUserID, forKey: .inviterUserID)
        try c.encode(maxUses, forKey: .maxUses)
        try c.encode(useCount, forKey: .useCount)
        try c.encodeIfPresent(emailHint, forKey: .emailHint)
        if let expiresAt { try c.encode(expiresAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .expiresAt) }
        if let createdAt { try c.encode(createdAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .createdAt) }
        if let revokedAt { try c.encode(revokedAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .revokedAt) }
    }
}

/// Body for `POST /api/vaults/:vault/invites`. The server expects an ISO8601
/// `expires_at` in UTC (the SQL layer normalizes to UTC before storage).
struct CreateInviteRequest: Codable, Sendable {
    let roleID: String
    let maxUses: Int
    let expiresAt: Date
    let emailHint: String?

    enum CodingKeys: String, CodingKey {
        case roleID = "role_id"
        case maxUses = "max_uses"
        case expiresAt = "expires_at"
        case emailHint = "email_hint"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(roleID, forKey: .roleID)
        try c.encode(maxUses, forKey: .maxUses)
        try c.encode(expiresAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .expiresAt)
        try c.encodeIfPresent(emailHint, forKey: .emailHint)
    }
}

struct InviteListResponse: Decodable, Sendable {
    let invites: [VaultInvite]
}
