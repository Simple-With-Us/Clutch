import Foundation
import Security

/// The app's own credentials, kept in the keychain rather than in the
/// preferences file.
///
/// The preferences file is plain text and rides the device backup, so a token
/// that can drive a coding session has no business being in it.  The keychain
/// holds it, and only this app can read it.
enum KeychainStore {
    /// The service every Clutch credential sits under.
    static let service = "codes.clutch.credentials"

    /// The credential for one account, or nil when there is none.
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    /// Stores a credential, replacing what was there.
    ///
    /// It answers whether the keychain took it, so a caller that cannot lose
    /// the credential knows to keep a copy.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Forgets a credential.
    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
