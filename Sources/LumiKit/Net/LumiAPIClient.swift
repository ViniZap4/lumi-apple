import Foundation

/// Thin URLSession-backed REST client for talking to a `lumi-server`
/// instance. Owns the base URL + session token; both are mutable via actor
/// methods so the rest of the app sees a Sendable surface.
///
/// All requests:
/// * encode JSON bodies with `JSONEncoder()` (server expects camel_case
///   keys in the v2 spec — but the existing endpoints accept snake_case JSON;
///   we encode using the DTO's CodingKeys so each request DTO carries the
///   exact wire shape it needs).
/// * include `X-Lumi-Token` when a token is set.
/// * decode 2xx responses with `decoder`.
/// * map non-2xx responses through `decodeServerError` into `LumiAPIError`.
public actor LumiAPIClient {
    public private(set) var baseURL: URL?
    public private(set) var token: String?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    public func setBaseURL(_ url: URL?) {
        self.baseURL = url
    }

    public func setToken(_ token: String?) {
        self.token = token
    }

    /// `POST /api/auth/login` — username + password, returns session token + user.
    public func login(username: String, password: String) async throws(LumiAPIError) -> SessionResponse {
        let body = LoginRequest(username: username, password: password)
        return try await request(method: "POST", path: "/api/auth/login", body: body, requireToken: false)
    }

    /// `POST /api/auth/register` — only allowed when the server's
    /// `RegistrationPolicy` is `open`; otherwise a 403 with code
    /// `registration_closed` is returned. `consent` is required if the server
    /// has `tos_version` / `privacy_version` configured — the values must
    /// match the server's current versions exactly (no legal-fetch endpoint
    /// exists yet on the server side). Pass empty strings when the server
    /// doesn't require consent.
    public func register(
        username: String,
        password: String,
        displayName: String,
        tosVersion: String,
        privacyVersion: String
    ) async throws(LumiAPIError) -> SessionResponse {
        let body = RegisterRequest(
            username: username,
            password: password,
            displayName: displayName,
            consent: ConsentBody(tosVersion: tosVersion, privacyVersion: privacyVersion)
        )
        return try await request(method: "POST", path: "/api/auth/register", body: body, requireToken: false)
    }

    /// `POST /api/auth/logout` — invalidates the current token server-side.
    /// Caller is still responsible for clearing local state.
    public func logout() async throws(LumiAPIError) {
        let _: EmptyResponse = try await request(method: "POST", path: "/api/auth/logout", body: EmptyBody(), requireToken: true)
    }

    /// `GET /api/users/me` — validates the current token and returns the user.
    public func currentUser() async throws(LumiAPIError) -> UserDTO {
        try await request(method: "GET", path: "/api/users/me", body: nil as EmptyBody?, requireToken: true)
    }

    /// `GET /api/invites/:token` — public preview, no auth required. Used
    /// to render a "join Work as Editor?" confirmation screen before the user
    /// commits.
    public func previewInvite(token: String) async throws(LumiAPIError) -> InvitePreview {
        try await request(method: "GET", path: "/api/invites/\(token)", body: nil as EmptyBody?, requireToken: false)
    }

    /// `POST /api/invites/:token/accept` (authenticated). Attaches membership
    /// to the user the client is currently signed in as. Server returns just
    /// the vault descriptor.
    public func acceptInviteAsExistingUser(token: String) async throws(LumiAPIError) -> AcceptedVault {
        let envelope: AcceptExistingResponse = try await request(method: "POST", path: "/api/invites/\(token)/accept", body: EmptyBody(), requireToken: true)
        return envelope.vault
    }

    /// `POST /api/invites/:token/accept` (signup variant). Used when no
    /// session exists yet — the server creates the user, attaches them to
    /// the invited vault, and returns a fresh session token. `acceptedAt`
    /// defaults to "now" if the caller doesn't provide one.
    public func acceptInviteWithSignup(
        token: String,
        username: String,
        password: String,
        displayName: String,
        tosVersion: String,
        privacyVersion: String,
        acceptedAt: Date = Date()
    ) async throws(LumiAPIError) -> AcceptedInviteSession {
        let body = AcceptSignupRequest(
            username: username,
            password: password,
            displayName: displayName,
            consent: AcceptSignupConsent(
                tosVersion: tosVersion,
                privacyVersion: privacyVersion,
                acceptedAt: acceptedAt
            )
        )
        let envelope: AcceptSignupResponse = try await request(method: "POST", path: "/api/invites/\(token)/accept", body: body, requireToken: false)
        return AcceptedInviteSession(token: envelope.token, expiresAt: envelope.expiresAt, vault: envelope.vault)
    }

    /// `GET /api/vaults` — list vaults the authenticated user is a member of.
    public func listVaults() async throws(LumiAPIError) -> [RemoteVault] {
        let envelope: VaultListResponse = try await request(method: "GET", path: "/api/vaults", body: nil as EmptyBody?, requireToken: true)
        return envelope.vaults
    }

    /// `GET /api/vaults/:vault` — vault detail.
    public func vaultDetail(id: UUID) async throws(LumiAPIError) -> RemoteVault {
        try await request(method: "GET", path: "/api/vaults/\(id.uuidString.lowercased())", body: nil as EmptyBody?, requireToken: true)
    }

    /// `POST /api/vaults` — create a new vault. Caller becomes its Admin.
    /// `slug` is optional; the server derives one from `name` when omitted.
    /// On slug collision the server returns 409 with code `slug_taken`.
    public func createVault(name: String, slug: String? = nil) async throws(LumiAPIError) -> RemoteVault {
        let body = CreateVaultRequest(name: name, slug: slug?.isEmpty == true ? nil : slug)
        return try await request(method: "POST", path: "/api/vaults", body: body, requireToken: true)
    }

    /// `PATCH /api/vaults/:vault` — rename. Capability `vault.manage` required.
    public func renameVault(vaultID: UUID, name: String) async throws(LumiAPIError) -> RemoteVault {
        let body = UpdateVaultRequest(name: name)
        return try await request(method: "PATCH", path: "/api/vaults/\(vaultID.uuidString.lowercased())", body: body, requireToken: true)
    }

    /// `DELETE /api/vaults/:vault` — destructive. Capability `vault.manage`
    /// required. Server returns 204.
    public func deleteVault(vaultID: UUID) async throws(LumiAPIError) {
        let _: EmptyResponse = try await request(
            method: "DELETE",
            path: "/api/vaults/\(vaultID.uuidString.lowercased())",
            body: EmptyBody(),
            requireToken: true
        )
    }

    /// `GET /api/vaults/:vault/members`.
    public func listMembers(vaultID: UUID) async throws(LumiAPIError) -> [RemoteMember] {
        let envelope: MemberListResponse = try await request(method: "GET", path: "/api/vaults/\(vaultID.uuidString.lowercased())/members", body: nil as EmptyBody?, requireToken: true)
        return envelope.members
    }

    /// `GET /api/vaults/:vault/roles`.
    public func listRoles(vaultID: UUID) async throws(LumiAPIError) -> [RemoteRole] {
        let envelope: RoleListResponse = try await request(method: "GET", path: "/api/vaults/\(vaultID.uuidString.lowercased())/roles", body: nil as EmptyBody?, requireToken: true)
        return envelope.roles
    }

    /// `POST /api/vaults/:vault/invites` — capability `members.invite` required.
    public func createInvite(
        vaultID: UUID,
        roleID: UUID,
        maxUses: Int,
        expiresAt: Date,
        emailHint: String?
    ) async throws(LumiAPIError) -> CreatedInvite {
        let body = CreateInviteRequest(
            roleID: roleID.uuidString.lowercased(),
            maxUses: maxUses,
            expiresAt: expiresAt,
            emailHint: emailHint?.isEmpty == true ? nil : emailHint
        )
        return try await request(
            method: "POST",
            path: "/api/vaults/\(vaultID.uuidString.lowercased())/invites",
            body: body,
            requireToken: true
        )
    }

    /// `GET /api/vaults/:vault/invites` — capability `members.invite` required.
    public func listInvites(vaultID: UUID) async throws(LumiAPIError) -> [VaultInvite] {
        let envelope: InviteListResponse = try await request(
            method: "GET",
            path: "/api/vaults/\(vaultID.uuidString.lowercased())/invites",
            body: nil as EmptyBody?,
            requireToken: true
        )
        return envelope.invites
    }

    /// `DELETE /api/vaults/:vault/invites/:token` — capability `members.invite`
    /// required. Server responds 204; we synthesize an empty JSON body so the
    /// generic decoder is happy.
    public func revokeInvite(vaultID: UUID, token: String) async throws(LumiAPIError) {
        let _: EmptyResponse = try await request(
            method: "DELETE",
            path: "/api/vaults/\(vaultID.uuidString.lowercased())/invites/\(token)",
            body: EmptyBody(),
            requireToken: true
        )
    }

    /// `GET /api/vaults/:vault/audit?limit=&offset=` — capability `audit.read`
    /// required. Returns the paginated audit log.
    public func listAuditEntries(vaultID: UUID, limit: Int = 50, offset: Int = 0) async throws(LumiAPIError) -> AuditListResponse {
        var path = "/api/vaults/\(vaultID.uuidString.lowercased())/audit"
        var query: [String] = []
        if limit > 0 { query.append("limit=\(limit)") }
        if offset > 0 { query.append("offset=\(offset)") }
        if !query.isEmpty { path += "?" + query.joined(separator: "&") }
        return try await request(method: "GET", path: path, body: nil as EmptyBody?, requireToken: true)
    }

    /// `GET /api/vaults/:vault/notes?limit=&offset=` — capability `note.read`
    /// required. Returns the paginated list of notes (metadata only, no body).
    public func listNotes(vaultID: UUID, limit: Int = 50, offset: Int = 0) async throws(LumiAPIError) -> RemoteNoteListResponse {
        var path = "/api/vaults/\(vaultID.uuidString.lowercased())/notes"
        var query: [String] = []
        if limit > 0 { query.append("limit=\(limit)") }
        if offset > 0 { query.append("offset=\(offset)") }
        if !query.isEmpty { path += "?" + query.joined(separator: "&") }
        return try await request(method: "GET", path: path, body: nil as EmptyBody?, requireToken: true)
    }

    /// `GET /api/vaults/:vault/notes/:id/content` — capability `note.read`
    /// required. Returns the full note payload: metadata + parsed
    /// frontmatter + raw body. The `frontmatter` JSON field is currently
    /// dropped by the client (E.1.2 slice 2 renders body only); slice 3 will
    /// surface it for the editor.
    public func getNoteContent(vaultID: UUID, noteID: String) async throws(LumiAPIError) -> RemoteNoteContent {
        let escaped = noteID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? noteID
        let path = "/api/vaults/\(vaultID.uuidString.lowercased())/notes/\(escaped)/content"
        return try await request(method: "GET", path: path, body: nil as EmptyBody?, requireToken: true)
    }

    /// `POST /api/vaults/:vault/notes` — capability `note.create` required.
    /// Returns the new note's metadata row (matching the list endpoint
    /// shape). Server derives the slug id from `title`; tags default to an
    /// empty list when omitted.
    public func createNote(
        vaultID: UUID,
        title: String,
        body: String = "",
        tags: [String] = []
    ) async throws(LumiAPIError) -> RemoteNote {
        let path = "/api/vaults/\(vaultID.uuidString.lowercased())/notes"
        let req = CreateNoteRequest(title: title, body: body, tags: tags)
        return try await request(method: "POST", path: path, body: req, requireToken: true)
    }

    /// `DELETE /api/vaults/:vault/notes/:id` — capability `note.delete`
    /// required. Server responds 204 No Content.
    public func deleteNote(vaultID: UUID, noteID: String) async throws(LumiAPIError) {
        let escaped = noteID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? noteID
        let path = "/api/vaults/\(vaultID.uuidString.lowercased())/notes/\(escaped)"
        let _: EmptyResponse = try await request(method: "DELETE", path: path, body: EmptyBody(), requireToken: true)
    }

    /// `PATCH /api/vaults/:vault/notes/:id` — capability `note.write` required
    /// (plus `note.move` if `path` is provided). Each field is optional; nil
    /// means "leave alone". Returns the updated note metadata DTO (matching
    /// the list endpoint's row shape) so the caller can refresh its cache.
    ///
    /// Slice 3 only wires `body`; title/path/tags surfaces land later.
    public func updateNote(
        vaultID: UUID,
        noteID: String,
        title: String? = nil,
        body: String? = nil,
        path: String? = nil,
        tags: [String]? = nil
    ) async throws(LumiAPIError) -> RemoteNote {
        let escaped = noteID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? noteID
        let urlPath = "/api/vaults/\(vaultID.uuidString.lowercased())/notes/\(escaped)"
        let body = UpdateNoteRequest(title: title, body: body, path: path, tags: tags)
        return try await request(method: "PATCH", path: urlPath, body: body, requireToken: true)
    }

    private func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        path: String,
        body: Body?,
        requireToken: Bool
    ) async throws(LumiAPIError) -> Response {
        guard let baseURL else {
            throw .network(message: "no server configured")
        }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw .network(message: "invalid path \(path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body, !(body is EmptyBody) {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                req.httpBody = try encoder.encode(body)
            } catch {
                throw .decoding(message: "failed to encode request body: \(error.localizedDescription)")
            }
        }
        if requireToken {
            guard let token else { throw .unauthorized }
            req.setValue(token, forHTTPHeaderField: "X-Lumi-Token")
        } else if let token {
            // Send the token even for non-required calls (e.g. logout after
            // re-issuing) — server ignores it if not needed.
            req.setValue(token, forHTTPHeaderField: "X-Lumi-Token")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw .network(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw .invalidResponse(status: -1)
        }

        if (200..<300).contains(http.statusCode) {
            if Response.self == EmptyResponse.self || data.isEmpty {
                // EmptyResponse decodes from an empty body fine if we hand it
                // a "null"; just synthesize one.
                let empty = "null".data(using: .utf8)!
                do {
                    return try decoder.decode(Response.self, from: empty)
                } catch {
                    throw .decoding(message: "expected empty body but decode failed: \(error.localizedDescription)")
                }
            }
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw .decoding(message: error.localizedDescription)
            }
        }

        if http.statusCode == 401 {
            throw .unauthorized
        }

        // Try to parse the server's `{ "error": code, "detail": message? }` envelope.
        if let envelope = try? decoder.decode(ServerErrorEnvelope.self, from: data) {
            throw .server(status: http.statusCode, code: envelope.error, detail: envelope.detail)
        }
        throw .invalidResponse(status: http.statusCode)
    }
}

// MARK: - DTOs

public struct LoginRequest: Codable, Sendable {
    public let username: String
    public let password: String
}

public struct RegisterRequest: Codable, Sendable {
    public let username: String
    public let password: String
    public let displayName: String
    public let consent: ConsentBody

    enum CodingKeys: String, CodingKey {
        case username
        case password
        case displayName = "display_name"
        case consent
    }
}

public struct ConsentBody: Codable, Sendable, Equatable {
    public let tosVersion: String
    public let privacyVersion: String

    enum CodingKeys: String, CodingKey {
        case tosVersion = "tos_version"
        case privacyVersion = "privacy_version"
    }
}

public struct SessionResponse: Codable, Sendable, Equatable {
    public let token: String
    public let expiresAt: Date?
    public let user: UserDTO

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case user
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try container.decode(String.self, forKey: .token)
        self.user = try container.decode(UserDTO.self, forKey: .user)
        // Server emits RFC3339 with offset; tolerate the absence too. Try
        // with fractional seconds first (`.SSSSSSZ`), then without.
        if let raw = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
            self.expiresAt = SessionResponse.parseISO8601(raw)
        } else {
            self.expiresAt = nil
        }
    }

    public init(token: String, expiresAt: Date?, user: UserDTO) {
        self.token = token
        self.expiresAt = expiresAt
        self.user = user
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(user, forKey: .user)
        if let expiresAt {
            // Value-type FormatStyle is Sendable and doesn't need a cached
            // global formatter.
            let str = expiresAt.ISO8601Format(.iso8601(timeZone: .gmt))
            try container.encode(str, forKey: .expiresAt)
        }
    }

    static func parseISO8601(_ raw: String) -> Date? {
        // Try fractional first, then plain.
        if let d = try? Date(raw, strategy: .iso8601.year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: true).timeZone(separator: .omitted)) {
            return d
        }
        return try? Date(raw, strategy: .iso8601)
    }
}

public struct UserDTO: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let username: String
    public let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
    }

    public init(id: String, username: String, displayName: String) {
        self.id = id
        self.username = username
        self.displayName = displayName
    }
}

struct ServerErrorEnvelope: Decodable, Sendable {
    let error: String
    let detail: String?
}

struct VaultListResponse: Decodable, Sendable {
    let vaults: [RemoteVault]
}

struct CreateVaultRequest: Codable, Sendable {
    let name: String
    let slug: String?
}

struct UpdateVaultRequest: Codable, Sendable {
    let name: String
}

struct MemberListResponse: Decodable, Sendable {
    let members: [RemoteMember]
}

struct RoleListResponse: Decodable, Sendable {
    let roles: [RemoteRole]
}

/// Body for `POST /api/vaults/:vault/notes`. Tags default to an empty
/// list (and are omitted from the wire when empty so the server's
/// `omitempty` JSON tag round-trips cleanly).
struct CreateNoteRequest: Encodable, Sendable {
    let title: String
    let body: String
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case title, body, tags
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        // Omit when empty so the JSON matches the server's `tags,omitempty`
        // tag — symmetric with how we'd receive it back.
        if !tags.isEmpty {
            try c.encode(tags, forKey: .tags)
        }
    }
}

/// Body for `PATCH /api/vaults/:vault/notes/:id`. All fields optional — the
/// server treats nil as "leave alone".
struct UpdateNoteRequest: Encodable, Sendable {
    let title: String?
    let body: String?
    let path: String?
    let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case title, body, path, tags
    }

    func encode(to encoder: Encoder) throws {
        // Explicit encoder so nil fields are *omitted* rather than emitted
        // as `null` (the server treats nil and null differently — null
        // would mean "clear the field", we mean "don't touch it").
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let title { try c.encode(title, forKey: .title) }
        if let body { try c.encode(body, forKey: .body) }
        if let path { try c.encode(path, forKey: .path) }
        if let tags { try c.encode(tags, forKey: .tags) }
    }
}

struct EmptyBody: Codable, Sendable {}
struct EmptyResponse: Codable, Sendable {
    init(from decoder: Decoder) throws {
        // Tolerate null or empty objects equivalently.
        _ = try? decoder.singleValueContainer().decodeNil()
    }
}
