import Foundation
import Security

/// Keychain storage for the Cloudflare API tokens (primary R2 credential and
/// the optional read-only analytics token).
enum Keychain {
    private static let service = "com.temeculadsp.dropper"
    private static let primaryAccount = "cloudflare-api-token"
    private static let analyticsAccount = "cloudflare-analytics-token"

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        save(token, account: primaryAccount)
    }

    static func loadToken() -> String? {
        load(account: primaryAccount)
    }

    static func deleteToken() {
        delete(account: primaryAccount)
    }

    /// Optional read-only token used solely for Cloudflare Analytics.
    /// Keeping it separate lets the existing R2 credential remain unchanged.
    @discardableResult
    static func saveAnalyticsToken(_ token: String) -> Bool {
        save(token, account: analyticsAccount)
    }

    static func loadAnalyticsToken() -> String? {
        load(account: analyticsAccount)
    }

    static func deleteAnalyticsToken() {
        delete(account: analyticsAccount)
    }

    private static func save(_ token: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let value = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: value] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addition = query
        addition[kSecValueData as String] = value
        return SecItemAdd(addition as CFDictionary, nil) == errSecSuccess
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
