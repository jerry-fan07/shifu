import Foundation
import Security

/// The SQLCipher passphrase, kept in the login Keychain (design.md §8:
/// "SQLCipher …; key in Keychain"). `SHIFU_DB_KEY` overrides for tests and
/// the perf harness so they never touch the real Keychain.
public enum DatabaseKey {
    public static let envVar = "SHIFU_DB_KEY"
    static let service = "com.shifu.database-key"
    static let account = "shifu"

    public enum KeyError: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case randomFailed

        public var description: String {
            switch self {
            case .keychain(let status): return "keychain error \(status)"
            case .randomFailed: return "SecRandomCopyBytes failed"
            }
        }
    }

    /// The stored passphrase, or nil when encryption was never enabled.
    public static func existing() throws -> String? {
        if let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty {
            return env
        }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let passphrase = String(data: data, encoding: .utf8) else {
            throw KeyError.keychain(status)
        }
        return passphrase
    }

    /// Fetches the passphrase, generating and storing a fresh 32-byte random
    /// key on first call (used by `shifu encrypt`).
    public static func getOrCreate() throws -> String {
        if let passphrase = try existing() { return passphrase }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeyError.randomFailed
        }
        let passphrase = bytes.map { String(format: "%02x", $0) }.joined()

        var attributes = baseQuery()
        attributes[kSecValueData as String] = Data(passphrase.utf8)
        attributes[kSecAttrLabel as String] = "Shifu database key"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
        return passphrase
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
