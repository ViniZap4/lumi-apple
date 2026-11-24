import Foundation
import CryptoKit
import Security
#if canImport(Darwin)
import Darwin
#endif

/// Wire formats of the local device-link drop box (SPEC-LIVROS §8.4),
/// shared with the TUI through `~/.config/lumi/link/`. Fixtures:
/// `Tests/Fixtures/accounts/link-*.json`.
public enum DeviceLink {
    public static let version = 1
    public static let appClient = "apple"
    public static let tuiClient = "tui"
    /// A request older than this is stale unless its requester is alive.
    public static let requestTTL: TimeInterval = 5 * 60

    public struct Request: Codable, Sendable, Equatable {
        public var v: Int
        public var id: String
        public var from: String
        public var to: String
        public var server: String
        public var username: String
        public var challenge: String
        public var label: String
        public var pid: Int32
        public var createdAt: String

        enum CodingKeys: String, CodingKey {
            case v, id, from, to, server, username, challenge, label, pid
            case createdAt = "created_at"
        }

        public init(id: String = UUID().uuidString.lowercased(), from: String, to: String, account: AccountKey,
                    challenge: String, label: String, pid: Int32, createdAt: Date) {
            self.v = DeviceLink.version
            self.id = id
            self.from = from
            self.to = to
            self.server = account.serverURL
            self.username = account.username
            self.challenge = challenge
            self.label = label
            self.pid = pid
            self.createdAt = BooksFile.timestamp(createdAt)
        }

        public var account: AccountKey {
            AccountKey(serverURL: server, username: Account.normalizeUsername(username))
        }

        public var created: Date? { BooksFile.parseTimestamp(createdAt) }
    }

    public struct Response: Codable, Sendable, Equatable {
        public var v: Int
        public var id: String
        public var code: String?
        public var expiresAt: String?
        public var error: String?

        enum CodingKeys: String, CodingKey {
            case v, id, code, error
            case expiresAt = "expires_at"
        }

        public init(id: String, code: String, expiresAt: Date) {
            self.v = DeviceLink.version
            self.id = id
            self.code = code
            self.expiresAt = BooksFile.timestamp(expiresAt)
        }

        public init(id: String, error: String) {
            self.v = DeviceLink.version
            self.id = id
            self.error = error
        }

        public var expires: Date? { expiresAt.flatMap(BooksFile.parseTimestamp) }
    }

    public struct Presence: Codable, Sendable, Equatable {
        public var v: Int
        public var pid: Int32
        public var startedAt: String

        enum CodingKeys: String, CodingKey {
            case v, pid
            case startedAt = "started_at"
        }

        public init(pid: Int32, startedAt: Date) {
            self.v = DeviceLink.version
            self.pid = pid
            self.startedAt = BooksFile.timestamp(startedAt)
        }
    }

    public enum ErrorCode {
        public static let denied = "denied"
        public static let noSession = "no_session"
        public static let failed = "failed"
    }

    // MARK: PKCE (S256)

    /// 32 random bytes, base64url without padding (43 chars). Lives only
    /// in the requester's memory.
    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64URL(Data(bytes))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A challenge is exactly 43 base64url characters (SHA-256, no padding).
    public static func isValidChallenge(_ s: String) -> Bool {
        guard s.utf8.count == 43 else { return false }
        return s.utf8.allSatisfy { c in
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
        }
    }

    /// `kill(pid, 0)`: the process exists (EPERM also means it exists).
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// The drop-box directory: 0700, files 0600, atomic writes.
public struct DeviceLinkDirectory: Sendable {
    public let url: URL

    public init(url: URL = ConfigPaths.link) {
        self.url = url
    }

    public func ensure() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        chmod(url.path, 0o700)
    }

    public func requestURL(_ id: String) -> URL { url.appendingPathComponent("req-\(id).json") }
    public func responseURL(_ id: String) -> URL { url.appendingPathComponent("resp-\(id).json") }
    public func presenceURL(_ client: String) -> URL { url.appendingPathComponent("\(client).alive") }

    public func write<T: Encodable>(_ value: T, to file: URL) throws {
        try ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(value)
        let tmp = url.appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, file.path) != 0 {
            unlink(tmp.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func read<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func remove(_ file: URL) {
        unlink(file.path)
    }

    /// Request ids found in the directory (from `req-<id>.json`).
    public func requestIDs() -> [String] {
        ids(prefix: "req-")
    }

    public func responseIDs() -> [String] {
        ids(prefix: "resp-")
    }

    private func ids(prefix: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.compactMap { name in
            guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
            return String(name.dropFirst(prefix.count).dropLast(5))
        }.sorted()
    }

    /// Modification time, used for the age of files whose JSON is unreadable.
    func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}
