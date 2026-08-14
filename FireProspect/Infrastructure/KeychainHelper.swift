import Foundation
import Security

struct KeychainHelper {
    // Use an app-specific service in the data-protection keychain. The previous
    // service ("com.propsector.app") was stored in the legacy file keychain,
    // whose per-item ACL can prompt again whenever a development build's code
    // signature changes. Do not query that item here: even attempting a
    // migration would bring the unwanted password dialog back.
    static let service = "com.knnymck.FireProspect.firecrawl"
    static let firecrawlKeyAccount = "firecrawl_api_key"

    private static var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: firecrawlKeyAccount,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    static func saveKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }

        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var newItem = itemQuery
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(newItem as CFDictionary, nil)
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
