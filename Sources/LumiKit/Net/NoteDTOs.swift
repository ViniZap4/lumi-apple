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
    /// Opaque CRDT lineage id (`crdt_epoch`): changes whenever the server
    /// starts a new CRDT history for this note id (create, delete +
    /// recreate, init from file). Compare by equality only. Nil on
    /// servers predating it.
    public let crdtEpoch: String?
    /// `"markdown"` or `"canvas"` (CRDT-CLIENT-PROTOCOL §13). Nil on
    /// servers predating it — `NoteKind.resolve` falls back to the path.
    public let kind: String?

    enum CodingKeys: String, CodingKey {
        case id, path, title, kind
        case vaultID = "vault_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case crdtEpoch = "crdt_epoch"
    }

    public init(
        id: String,
        vaultID: UUID,
        path: String,
        title: String,
        createdAt: Date?,
        updatedAt: Date?,
        crdtEpoch: String? = nil,
        kind: String? = nil
    ) {
        self.id = id
        self.vaultID = vaultID
        self.path = path
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.crdtEpoch = crdtEpoch
        self.kind = kind
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
        self.crdtEpoch = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .crdtEpoch))
        self.kind = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .kind))
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vaultID, forKey: .vaultID)
        try c.encode(path, forKey: .path)
        try c.encode(title, forKey: .title)
        if let createdAt {
            // `.iso8601(timeZone:)` alone drops the `Z`, which the decoder
            // then rejects; the default style round-trips.
            try c.encode(createdAt.ISO8601Format(), forKey: .createdAt)
        }
        if let updatedAt {
            try c.encode(updatedAt.ISO8601Format(), forKey: .updatedAt)
        }
        try c.encodeIfPresent(crdtEpoch, forKey: .crdtEpoch)
        try c.encodeIfPresent(kind, forKey: .kind)
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
    /// `kanban-plugin` from the parsed `frontmatter` map (server bodies
    /// carry no frontmatter, so this is how a board is recognised).
    public let kanbanPlugin: String?

    enum CodingKeys: String, CodingKey {
        case id, path, body, frontmatter
        case vaultID = "vault_id"
    }

    private struct FrontmatterFlags: Decodable {
        let kanbanPlugin: String?
        enum CodingKeys: String, CodingKey { case kanbanPlugin = "kanban-plugin" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kanbanPlugin = try? c.decodeIfPresent(String.self, forKey: .kanbanPlugin)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        vaultID = try c.decode(UUID.self, forKey: .vaultID)
        path = try c.decode(String.self, forKey: .path)
        body = try c.decode(String.self, forKey: .body)
        kanbanPlugin = (try? c.decodeIfPresent(FrontmatterFlags.self, forKey: .frontmatter))??.kanbanPlugin
    }

    public init(id: String, vaultID: UUID, path: String, body: String, kanbanPlugin: String? = nil) {
        self.id = id
        self.vaultID = vaultID
        self.path = path
        self.body = body
        self.kanbanPlugin = kanbanPlugin
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
    /// Base64 full encoded doc (`EncodeStateAsUpdate`, §10 S9). The base
    /// of a 3-way `/diff {text, base_state}` and what a pull-to-refresh
    /// merges into a live replica. Absent on `/diff` responses and on
    /// servers predating wave 1b.
    public let state: String?
    /// CRDT lineage of the doc this snapshot was read from (`crdt_epoch`).
    /// Nil on servers predating it.
    public let crdtEpoch: String?

    enum CodingKeys: String, CodingKey {
        case id, path, text, state
        case vectorClock = "vector_clock"
        case crdtEpoch = "crdt_epoch"
    }

    public init(id: String, path: String, text: String, vectorClock: String, state: String? = nil,
                crdtEpoch: String? = nil) {
        self.id = id
        self.path = path
        self.text = text
        self.vectorClock = vectorClock
        self.state = state
        self.crdtEpoch = crdtEpoch
    }

    /// Decoded `state`, nil when absent or malformed.
    public var stateData: Data? {
        guard let state, !state.isEmpty else { return nil }
        return Data(base64Encoded: state)
    }
}

/// `POST /api/vaults/:vault/notes/:id/ws-ticket` response: a single-use
/// ticket valid for ~30 s, presented as `?ticket=` on the WS upgrade.
public struct WSTicket: Decodable, Sendable, Equatable {
    public let ticket: String
    public let expiresAt: String?
    /// CRDT lineage the ticket was minted for (`crdt_epoch`). The server
    /// rejects the upgrade (4401 `ticket_stale`) if the lineage changed
    /// before redeem, so the doc joined with this ticket IS this epoch.
    /// Nil on servers predating it.
    public let crdtEpoch: String?

    enum CodingKeys: String, CodingKey {
        case ticket
        case expiresAt = "expires_at"
        case crdtEpoch = "crdt_epoch"
    }

    public init(ticket: String, expiresAt: String? = nil, crdtEpoch: String? = nil) {
        self.ticket = ticket
        self.expiresAt = expiresAt
        self.crdtEpoch = crdtEpoch
    }
}
