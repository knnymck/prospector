import Foundation
import Security

struct KeychainHelper {
    // Keep the credential in the default macOS keychain without a keychain
    // access group. Access groups require a development certificate, which
    // prevents unsigned local Debug builds from launching.
    static let service = "com.knnymck.FireProspect.firecrawl"
    static let firecrawlKeyAccount = "firecrawl_api_key"

    private static var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: firecrawlKeyAccount
        ]
    }

    /// Saves the credential and reports whether Keychain accepted the write.
    /// Callers must not claim the app is configured when this returns `false`.
    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var newItem = itemQuery
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }

    static func getKey() -> String {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess, let data = dataTypeRef as? Data, let key = String(data: data, encoding: .utf8) {
            return key
        }
        return ""
    }

    @discardableResult
    static func deleteKey() -> Bool {
        let status = SecItemDelete(itemQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
