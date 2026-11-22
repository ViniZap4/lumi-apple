import Foundation

/// Non-secret account metadata (SPEC-LIVROS §2.2), persisted as JSON in
/// `UserDefaults['lumi.accounts.v1']`. The session token lives only in the
/// Keychain under `"<server_url>#<username>"`; the password is never stored.
public struct Account: Codable, Sendable, Hashable, Identifiable {
    public let serverURL: String
    public let username: String
    public var userID: String
    public var displayName: String
    public let addedAt: Date
    public var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case username
        case userID = "user_id"
        case displayName = "display_name"
        case addedAt = "added_at"
        case expiresAt = "expires_at"
    }

    public init(serverURL: String, username: String, userID: String, displayName: String,
                addedAt: Date, expiresAt: Date? = nil) {
        self.serverURL = ServerURL.normalizedOrRaw(serverURL)
        self.username = username
        self.userID = userID
        self.displayName = displayName
        self.addedAt = addedAt
        self.expiresAt = expiresAt
    }

    public var key: AccountKey { AccountKey(serverURL: serverURL, username: username) }
    public var id: AccountKey { key }
}

/// Whether this client can currently talk to the server as this account.
public enum AccountAuthState: Sendable, Equatable {
    case signedIn
    /// Token missing, 401, `session.ended`, or failed migration. UI shows
    /// "Precisa entrar" / Sign in.
    case needsSignIn(reason: String)

    public var isSignedIn: Bool { self == .signedIn }
}

/// Last REST outcome per account (SPEC-LIVROS §4.2 `restHealth`).
public enum RestHealth: Sendable, Equatable {
    case ok
    /// Transport failure (offline, DNS, TLS). Drives Offline immediately.
    case network(String)
    case unauthorized
    /// Consecutive non-transient failures (5xx, bad JSON).
    case failing(count: Int, reason: String)
}

/// Secret storage for session tokens. Production uses the Keychain;
/// tests inject `InMemoryTokenStore`.
public protocol TokenStore: Sendable {
    func token(account: String) -> String?
    func setToken(_ token: String, account: String) throws
    func deleteToken(account: String) throws
}

public struct KeychainTokenStore: TokenStore {
    public let service: String

    public init(service: String = Keychain.defaultService) {
        self.service = service
    }

    public func token(account: String) -> String? {
        try? Keychain.get(service: service, account: account)
    }

    public func setToken(_ token: String, account: String) throws {
        try Keychain.set(token, service: service, account: account)
    }

    public func deleteToken(account: String) throws {
        try Keychain.delete(service: service, account: account)
    }
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]
    /// When true, `setToken` throws (simulates a Keychain failure).
    public var failWrites = false

    public init(_ initial: [String: String] = [:]) {
        self.storage = initial
    }

    public func token(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func setToken(_ token: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw Keychain.Error.status(-1) }
        storage[account] = token
    }

    public func deleteToken(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil
    }

    public var allAccounts: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.keys.sorted()
    }
}
