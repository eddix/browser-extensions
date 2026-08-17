import Foundation
import Security

/// LLM API keys, in the macOS Keychain.
///
/// Unlike the pairing token (which guards a loopback port and lives in
/// UserDefaults), these are real credentials for remote services — they don't
/// belong in a plist, and they must never reach the repository.
public enum SecretStore {
    private static let service = "com.eddix.nodia"

    public static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard !value.isEmpty else { return }
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            Log.write("keychain: failed to store \(account) (status \(status))")
        }
    }

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func has(_ account: String) -> Bool {
        !(get(account) ?? "").isEmpty
    }
}
