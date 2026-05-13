import Foundation

/// One row from `GET /api/vaults/:vault/audit`. Mirrors the server's
/// `auditDTO`. `payload` is a passthrough JSON object — the server doesn't
/// schematise per-action payloads, so the client renders whichever keys
/// happen to be present.
public struct AuditEntry: Sendable, Equatable, Identifiable, Hashable {
    public let id: Int64
    public let userID: UUID?
    public let vaultID: UUID?
    public let action: String
    public let payload: [String: AuditJSONValue]
    public let ip: String?
    public let userAgent: String?
    public let createdAt: Date?

    public init(id: Int64, userID: UUID?, vaultID: UUID?, action: String,
                payload: [String: AuditJSONValue], ip: String?, userAgent: String?,
                createdAt: Date?) {
        self.id = id; self.userID = userID; self.vaultID = vaultID
        self.action = action; self.payload = payload; self.ip = ip
        self.userAgent = userAgent; self.createdAt = createdAt
    }
}

extension AuditEntry: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, action, payload, ip
        case userID = "user_id"
        case vaultID = "vault_id"
        case userAgent = "user_agent"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int64.self, forKey: .id)
        self.action = try c.decode(String.self, forKey: .action)
        self.userID = try c.decodeIfPresent(UUID.self, forKey: .userID)
        self.vaultID = try c.decodeIfPresent(UUID.self, forKey: .vaultID)
        self.ip = try c.decodeIfPresent(String.self, forKey: .ip)
        self.userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        if let raw = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            self.createdAt = SessionResponse.parseISO8601(raw)
        } else {
            self.createdAt = nil
        }
        // Payload is an opaque JSON object. Decoded once into our
        // tagged-union value type so SwiftUI can render keys/values without
        // every callsite re-parsing raw Data.
        if c.contains(.payload),
           let dict = try? c.decode([String: AuditJSONValue].self, forKey: .payload) {
            self.payload = dict
        } else {
            self.payload = [:]
        }
    }
}

/// Minimal JSON value tree for audit payloads. Handles the shapes the server
/// actually emits today (strings, numbers, bools, null, nested objects /
/// arrays) without pulling in a third-party JSON library.
public enum AuditJSONValue: Sendable, Equatable, Hashable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([AuditJSONValue])
    case object([String: AuditJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .number(Double(i))
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AuditJSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: AuditJSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unrecognised JSON value in audit payload"
            )
        }
    }

    /// Compact one-line preview suitable for table-row rendering.
    public var preview: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n.rounded() == n && abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .string(let s): return s
        case .array(let a): return "[\(a.count) items]"
        case .object(let o): return "{\(o.count) keys}"
        }
    }
}

/// Response envelope. The server also emits `limit` + `offset`; we capture
/// them so paginated UIs can decide whether to load more.
public struct AuditListResponse: Decodable, Sendable {
    public let entries: [AuditEntry]
    public let limit: Int
    public let offset: Int
}
