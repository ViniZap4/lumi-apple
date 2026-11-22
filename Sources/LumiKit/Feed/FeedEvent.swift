import Foundation

/// Per-vault head as listed in `hello`.
public struct FeedVaultHead: Sendable, Equatable, Decodable {
    public let vaultID: String
    public let seq: Int64
    public let role: String?
    public let canEdit: Bool

    enum CodingKeys: String, CodingKey {
        case seq, role
        case vaultID = "vault_id"
        case canEdit = "can_edit"
    }

    public init(vaultID: String, seq: Int64, role: String?, canEdit: Bool) {
        self.vaultID = vaultID.lowercased()
        self.seq = seq
        self.role = role
        self.canEdit = canEdit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(vaultID: try c.decode(String.self, forKey: .vaultID),
                  seq: try c.decodeIfPresent(Int64.self, forKey: .seq) ?? 0,
                  role: try c.decodeIfPresent(String.self, forKey: .role),
                  canEdit: try c.decodeIfPresent(Bool.self, forKey: .canEdit) ?? false)
    }
}

public struct FeedHello: Sendable, Equatable, Decodable {
    public let protocolVersion: Int
    public let serverTime: String?
    public let userID: String?
    public let vaults: [FeedVaultHead]

    enum CodingKeys: String, CodingKey {
        case vaults
        case protocolVersion = "protocol"
        case serverTime = "server_time"
        case userID = "user_id"
    }

    public init(protocolVersion: Int, serverTime: String?, userID: String?, vaults: [FeedVaultHead]) {
        self.protocolVersion = protocolVersion
        self.serverTime = serverTime
        self.userID = userID
        self.vaults = vaults
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        serverTime = try c.decodeIfPresent(String.self, forKey: .serverTime)
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
        vaults = try c.decodeIfPresent([FeedVaultHead].self, forKey: .vaults) ?? []
    }
}

/// Typed account-feed event (SPEC-LIVROS §3.3). Payloads carry only ids,
/// `seq` and role — never titles or paths.
public enum FeedEvent: Sendable, Equatable {
    case hello(FeedHello)
    case vaultHead(vaultID: String, seq: Int64)
    case vaultAccess(vaultID: String, role: String?, canEdit: Bool)
    case vaultUpdated(vaultID: String, fields: [String])
    case vaultRevoked(vaultID: String, reason: String)
    case sessionEnded(reason: String)
    case reconnect(afterMs: Int)
    /// Unknown event name (forward compatibility): ignored by consumers.
    case unknown(name: String)

    /// Decode an SSE event. Returns nil for a known event with malformed
    /// JSON (the caller counts it as a non-transient failure).
    public static func decode(_ e: SSEEvent) -> FeedEvent? {
        let data = Data(e.data.utf8)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        func vid() -> String? { (obj?["vault_id"] as? String)?.lowercased() }
        func int64(_ k: String) -> Int64? { (obj?[k] as? NSNumber)?.int64Value }
        switch e.event {
        case "hello":
            return (try? JSONDecoder().decode(FeedHello.self, from: data)).map(FeedEvent.hello)
        case "vault.head":
            guard let v = vid(), let seq = int64("seq") else { return nil }
            return .vaultHead(vaultID: v, seq: seq)
        case "vault.access":
            guard let v = vid() else { return nil }
            return .vaultAccess(vaultID: v, role: obj?["role"] as? String, canEdit: obj?["can_edit"] as? Bool ?? false)
        case "vault.updated":
            guard let v = vid() else { return nil }
            return .vaultUpdated(vaultID: v, fields: obj?["fields"] as? [String] ?? [])
        case "vault.revoked":
            guard let v = vid() else { return nil }
            return .vaultRevoked(vaultID: v, reason: obj?["reason"] as? String ?? "removed")
        case "session.ended":
            return .sessionEnded(reason: obj?["reason"] as? String ?? "ended")
        case "reconnect":
            return .reconnect(afterMs: Int(int64("after_ms") ?? 0))
        default:
            return .unknown(name: e.event)
        }
    }
}
