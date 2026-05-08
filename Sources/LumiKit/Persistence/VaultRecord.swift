import Foundation
import SwiftData

/// SwiftData persistence record for a vault. Mirrors the in-memory `Vault`
/// shape but flattens `VaultBinding` so SwiftData can store it.
@Model
public final class VaultRecord {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var bookmarkData: Data?
    public var serverEndpoint: String?
    public var serverVaultSlug: String?
    public var serverAccountID: String?
    public var addedAt: Date
    public var lastOpenedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        bookmarkData: Data? = nil,
        serverEndpoint: String? = nil,
        serverVaultSlug: String? = nil,
        serverAccountID: String? = nil,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.serverEndpoint = serverEndpoint
        self.serverVaultSlug = serverVaultSlug
        self.serverAccountID = serverAccountID
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

public extension VaultRecord {
    var binding: VaultBinding? {
        if let bookmarkData {
            return .local(bookmark: bookmarkData)
        }
        if
            let serverEndpoint,
            let url = URL(string: serverEndpoint),
            let slug = serverVaultSlug,
            let account = serverAccountID
        {
            return .server(endpoint: url, vaultSlug: slug, accountID: account)
        }
        return nil
    }

    var snapshot: Vault? {
        guard let binding else { return nil }
        return Vault(
            id: id,
            name: name,
            binding: binding,
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt
        )
    }
}

/// Default ModelContainer factory. Apps and previews share this so the schema
/// stays in one place.
public enum VaultModelContainer {
    public static let schema = Schema([VaultRecord.self])

    @MainActor
    public static func make(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
