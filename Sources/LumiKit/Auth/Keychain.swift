import Foundation
import Security

/// Minimal Keychain wrapper for storing the lumi session token. We never
/// persist anything sensitive in `UserDefaults` or plain files; the token sits
/// in the user's keychain, scoped by service + account.
///
/// Operations are synchronous and threadsafe (Keychain APIs are). Errors
/// surface as `Keychain.Error` so callers can distinguish "not found" from
/// "I/O failure" — important when restoring a session at app launch.
public enum Keychain {
    public enum Error: Swift.Error, Equatable, Sendable {
        case notFound
        case unexpectedData
        case status(OSStatus)
    }

    /// Default service identifier used for the auth token entries. Account is
    /// the server's base URL string so multiple servers can be kept distinct.
    public static let defaultService = "com.vinizap.lumi.auth"

    public static func set(_ value: String, service: String = defaultService, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw Error.unexpectedData
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            for (k, v) in attributes { addQuery[k] = v }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Error.status(addStatus) }
        default:
            throw Error.status(updateStatus)
        }
    }

    public static func get(service: String = defaultService, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw Error.unexpectedData
            }
            return value
        case errSecItemNotFound:
            throw Error.notFound
        default:
            throw Error.status(status)
        }
    }

    public static func delete(service: String = defaultService, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.status(status)
        }
    }
}
