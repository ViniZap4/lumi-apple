import Foundation

/// One row of the shared book registry (`~/.config/lumi/books.yaml`,
/// SPEC-LIVROS §2.3). "Book" is the UI name for a vault; nothing changes on
/// the server side.
///
/// Identifiers (`id`, `vaultID`) are kept as strings so the file round-trips
/// byte for byte with the TUI even if a hand edit introduces a non-canonical
/// UUID spelling.
public struct Book: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Folder on this device only. No server, no feed.
        case local
        /// Pinned to exactly one (server_url, account, vault_id).
        case bound
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var serverURL: String?
    /// Username of the account on `serverURL`.
    public var account: String?
    public var vaultID: String?
    /// Mirror folder (`~/`-relative when inside home). nil for remote-only.
    public var path: String?
    /// User order; steps of 10.
    public var sort: Int
    public var addedAt: Date
    public var lastOpenedAt: Date?

    public init(
        id: String,
        name: String,
        kind: Kind,
        serverURL: String? = nil,
        account: String? = nil,
        vaultID: String? = nil,
        path: String? = nil,
        sort: Int,
        addedAt: Date,
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.serverURL = serverURL
        self.account = account
        self.vaultID = vaultID
        self.path = path
        self.sort = sort
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }

    /// Account key this book syncs through, when bound.
    public var accountKey: AccountKey? {
        guard kind == .bound, let serverURL, let account else { return nil }
        return AccountKey(serverURL: serverURL, username: account)
    }

    /// Parsed server vault id, when bound and well-formed.
    public var vaultUUID: UUID? {
        vaultID.flatMap(UUID.init(uuidString:))
    }

    /// Canonical registry order: `sort`, then `id` (bytewise).
    public static func registryOrder(_ a: Book, _ b: Book) -> Bool {
        if a.sort != b.sort { return a.sort < b.sort }
        return Array(a.id.utf8).lexicographicallyPrecedes(Array(b.id.utf8))
    }
}

/// Identity of an account on this client: `(server_url, username)`
/// (SPEC-LIVROS §2.2). Several accounts per server are allowed.
public struct AccountKey: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let serverURL: String
    public let username: String

    public init(serverURL: String, username: String) {
        self.serverURL = ServerURL.normalizedOrRaw(serverURL)
        self.username = username
    }

    /// Keychain account attribute: `"<server_url>#<username>"`.
    public var keychainAccount: String { "\(serverURL)#\(username)" }

    public var description: String { "\(username)@\(ServerURL.displayHost(serverURL))" }

    public static func < (lhs: AccountKey, rhs: AccountKey) -> Bool {
        if lhs.serverURL != rhs.serverURL { return lhs.serverURL < rhs.serverURL }
        return lhs.username < rhs.username
    }
}
