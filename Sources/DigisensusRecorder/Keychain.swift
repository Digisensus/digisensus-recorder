import Foundation
import Security

/// Secrets (the Digisensus device token, API keys for custom servers) as generic passwords in
/// the login keychain, rather than in plain-text preferences.
enum Keychain {
    /// The bundle ID, so a test build under another ID never touches the real app's secrets.
    private static let service = Bundle.main.bundleIdentifier ?? "com.digisensus.recorder"

    static func string(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores value, or deletes the item when value is nil or empty.
    static func set(_ value: String?, for account: String) {
        guard let value, !value.isEmpty else {
            SecItemDelete(baseQuery(account) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            if added != errSecSuccess { Log.write("keychain add \(account) failed: \(added)") }
        } else if status != errSecSuccess {
            Log.write("keychain update \(account) failed: \(status)")
        }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        // The App Store build keeps its secrets in the data protection keychain, where access
        // follows the app ID rather than the exact code signature. In the login keychain, items
        // left by a direct build would make macOS ask for the keychain password. The direct build
        // has no provisioning profile, so it can't use this keychain.
        #if APP_STORE
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
