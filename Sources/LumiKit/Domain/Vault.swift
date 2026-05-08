import Foundation

/// A vault is the unit of organization in Lumi v2 — Obsidian-style portable
/// directory that is either local-only or server-bound. Sync is opt-in per vault.
public struct Vault: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var binding: VaultBinding
    public var addedAt: Date
    public var lastOpenedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        binding: VaultBinding,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.binding = binding
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

/// How a vault is reached. Local vaults live behind a security-scoped bookmark
/// (iOS/visionOS/macOS sandbox). Server vaults bind to a v2 lumi-server.
public enum VaultBinding: Sendable, Hashable, Codable {
    /// Local folder accessed via a security-scoped bookmark.
    case local(bookmark: Data)

    /// Vault hosted on a lumi-server v2 instance.
    case server(endpoint: URL, vaultSlug: String, accountID: String)
}
