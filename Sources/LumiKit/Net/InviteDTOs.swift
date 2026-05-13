import Foundation

/// Public preview of an invite (`GET /api/invites/:token`). Anyone holding
/// the token can read this — auth is not required. The `requiresSignup` flag
/// echoes the request: when no token header is present the server flags this
/// `true` to nudge the client into the signup branch.
public struct InvitePreview: Codable, Sendable, Equatable {
    public let vaultID: UUID
    public let vaultName: String
    public let vaultSlug: String
    public let roleID: UUID
    public let roleName: String
    public let inviterUserID: UUID
    public let expiresAt: Date?
    public let maxUses: Int?
    public let useCount: Int
    public let emailHint: String?
    public let requiresSignup: Bool

    enum CodingKeys: String, CodingKey {
        case vaultID = "vault_id"
        case vaultName = "vault_name"
        case vaultSlug = "vault_slug"
        case roleID = "role_id"
        case roleName = "role_name"
        case inviterUserID = "inviter_user_id"
        case expiresAt = "expires_at"
        case maxUses = "max_uses"
        case useCount = "use_count"
        case emailHint = "email_hint"
        case requiresSignup = "requires_signup"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.vaultID = try c.decode(UUID.self, forKey: .vaultID)
        self.vaultName = try c.decode(String.self, forKey: .vaultName)
        self.vaultSlug = try c.decode(String.self, forKey: .vaultSlug)
        self.roleID = try c.decode(UUID.self, forKey: .roleID)
        self.roleName = try c.decode(String.self, forKey: .roleName)
        self.inviterUserID = try c.decode(UUID.self, forKey: .inviterUserID)
        self.maxUses = try c.decodeIfPresent(Int.self, forKey: .maxUses)
        self.useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        self.emailHint = try c.decodeIfPresent(String.self, forKey: .emailHint)
        self.requiresSignup = try c.decodeIfPresent(Bool.self, forKey: .requiresSignup) ?? false
        if let raw = try c.decodeIfPresent(String.self, forKey: .expiresAt) {
            self.expiresAt = SessionResponse.parseISO8601(raw)
        } else {
            self.expiresAt = nil
        }
    }

    public init(vaultID: UUID, vaultName: String, vaultSlug: String, roleID: UUID,
                roleName: String, inviterUserID: UUID, expiresAt: Date?,
                maxUses: Int?, useCount: Int, emailHint: String?, requiresSignup: Bool) {
        self.vaultID = vaultID; self.vaultName = vaultName; self.vaultSlug = vaultSlug
        self.roleID = roleID; self.roleName = roleName; self.inviterUserID = inviterUserID
        self.expiresAt = expiresAt; self.maxUses = maxUses; self.useCount = useCount
        self.emailHint = emailHint; self.requiresSignup = requiresSignup
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vaultID, forKey: .vaultID)
        try c.encode(vaultName, forKey: .vaultName)
        try c.encode(vaultSlug, forKey: .vaultSlug)
        try c.encode(roleID, forKey: .roleID)
        try c.encode(roleName, forKey: .roleName)
        try c.encode(inviterUserID, forKey: .inviterUserID)
        try c.encode(useCount, forKey: .useCount)
        try c.encode(requiresSignup, forKey: .requiresSignup)
        try c.encodeIfPresent(maxUses, forKey: .maxUses)
        try c.encodeIfPresent(emailHint, forKey: .emailHint)
        if let expiresAt {
            try c.encode(expiresAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .expiresAt)
        }
    }
}

/// Compact vault descriptor returned by both accept paths.
public struct AcceptedVault: Codable, Sendable, Equatable {
    public let id: UUID
    public let slug: String
    public let name: String

    public init(id: UUID, slug: String, name: String) {
        self.id = id; self.slug = slug; self.name = name
    }
}

/// Body for `POST /api/invites/:token/accept` when accepting as a new user.
struct AcceptSignupRequest: Codable, Sendable {
    let username: String
    let password: String
    let displayName: String
    let consent: AcceptSignupConsent

    enum CodingKeys: String, CodingKey {
        case username, password
        case displayName = "display_name"
        case consent
    }
}

struct AcceptSignupConsent: Codable, Sendable {
    let tosVersion: String
    let privacyVersion: String
    let acceptedAt: Date

    enum CodingKeys: String, CodingKey {
        case tosVersion = "tos_version"
        case privacyVersion = "privacy_version"
        case acceptedAt = "accepted_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tosVersion, forKey: .tosVersion)
        try c.encode(privacyVersion, forKey: .privacyVersion)
        try c.encode(acceptedAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .acceptedAt)
    }
}

/// Response envelopes for the two accept paths.
struct AcceptExistingResponse: Decodable, Sendable {
    let vault: AcceptedVault
}

struct AcceptSignupResponse: Decodable, Sendable {
    let token: String
    let expiresAt: Date?
    let vault: AcceptedVault

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case vault
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try c.decode(String.self, forKey: .token)
        self.vault = try c.decode(AcceptedVault.self, forKey: .vault)
        if let raw = try c.decodeIfPresent(String.self, forKey: .expiresAt) {
            self.expiresAt = SessionResponse.parseISO8601(raw)
        } else {
            self.expiresAt = nil
        }
    }
}

/// Result of a signup-style invite accept: session token + vault. The auth
/// service uses this to build an `AuthSession` and persist it.
public struct AcceptedInviteSession: Sendable, Equatable {
    public let token: String
    public let expiresAt: Date?
    public let vault: AcceptedVault

    public init(token: String, expiresAt: Date?, vault: AcceptedVault) {
        self.token = token; self.expiresAt = expiresAt; self.vault = vault
    }
}
