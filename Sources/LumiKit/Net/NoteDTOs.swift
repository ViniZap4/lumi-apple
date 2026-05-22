import Foundation

/// One note in a server-hosted vault. Mirrors the server's `noteDTO` from
/// `GET /api/vaults/:vault/notes` and the per-id metadata endpoint.
///
/// `id` is the slugified stem (e.g. `"hello-world"`), not a UUID — slugs are
/// the stable cross-client identifier for a note. `path` is vault-relative
/// (e.g. `"folder/hello-world.md"`).
public struct RemoteNote: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let vaultID: UUID
    public let path: String
    public let title: String
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, path, title
        case vaultID = "vault_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        vaultID: UUID,
        path: String,
        title: String,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.vaultID = vaultID
        self.path = path
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.vaultID = try c.decode(UUID.self, forKey: .vaultID)
        self.path = try c.decode(String.self, forKey: .path)
        self.title = try c.decode(String.self, forKey: .title)
        if let raw = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            self.createdAt = SessionResponse.parseISO8601(raw)
        } else {
            self.createdAt = nil
        }
        if let raw = try c.decodeIfPresent(String.self, forKey: .updatedAt) {
            self.updatedAt = SessionResponse.parseISO8601(raw)
        } else {
            self.updatedAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vaultID, forKey: .vaultID)
        try c.encode(path, forKey: .path)
        try c.encode(title, forKey: .title)
        if let createdAt {
            try c.encode(createdAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .createdAt)
        }
        if let updatedAt {
            try c.encode(updatedAt.ISO8601Format(.iso8601(timeZone: .gmt)), forKey: .updatedAt)
        }
    }
}

/// Envelope returned by `GET /api/vaults/:vault/notes`. The server includes
/// the echoed `limit` and `offset` so paginated views don't have to track
/// state separately.
public struct RemoteNoteListResponse: Decodable, Sendable, Equatable {
    public let notes: [RemoteNote]
    public let limit: Int
    public let offset: Int

    public init(notes: [RemoteNote], limit: Int, offset: Int) {
        self.notes = notes
        self.limit = limit
        self.offset = offset
    }
}

/// Full note payload returned by `GET /api/vaults/:vault/notes/:id/content`.
/// The wire JSON also carries a parsed `frontmatter` map, but slice 2 only
/// renders the body (title + tags come from the row in the list endpoint).
/// JSONDecoder ignores unknown keys, so the `frontmatter` field decodes as
/// a no-op — slice 3 (edit) re-enables it.
public struct RemoteNoteContent: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let vaultID: UUID
    public let path: String
    public let body: String

    enum CodingKeys: String, CodingKey {
        case id, path, body
        case vaultID = "vault_id"
    }

    public init(id: String, vaultID: UUID, path: String, body: String) {
        self.id = id
        self.vaultID = vaultID
        self.path = path
        self.body = body
    }
}

/// CRDT-aware payload returned by `GET /api/vaults/:vault/notes/:id/snapshot`
/// and `POST /api/vaults/:vault/notes/:id/diff`. The `vectorClock` is the
/// base64-encoded lib0-v1 state vector; clients send it back as
/// `base_clock` on the next diff so the server can place the patch
/// correctly against the CRDT's history (advisory in server slice 2.2,
/// load-bearing once 4e's WS sync lands).
///
/// Unlike `RemoteNoteContent`, the snapshot does NOT carry frontmatter or
/// `vault_id` — it's the body + clock pair. The slice 4d load path uses
/// snapshot because the same round-trip seeds the editor *and* arms the
/// clock for the eventual `applyDiff` save.
public struct RemoteNoteSnapshot: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let text: String
    /// Base64-encoded lib0-v1 state vector.
    public let vectorClock: String

    enum CodingKeys: String, CodingKey {
        case id, path, text
        case vectorClock = "vector_clock"
    }

    public init(id: String, path: String, text: String, vectorClock: String) {
        self.id = id
        self.path = path
        self.text = text
        self.vectorClock = vectorClock
    }
}
