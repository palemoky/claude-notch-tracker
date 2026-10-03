import Foundation
import Security

/// The DeepSeek API key: `DEEPSEEK_API_KEY` from the environment when the app was launched with
/// one, else a generic-password item this app writes to the login Keychain from the right-click
/// menu. It is only ever sent to api.deepseek.com.
enum DeepSeekCredentials {
    static let service = "Claude Notch – DeepSeek API key"
    static let account = "api-key"
    /// Lets availability be answered without touching the Keychain, which `ProviderAvailability`
    /// promises never to do.
    private static let storedFlag = "deepseekKeyStored"

    static var environmentKey: String? {
        let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    static var isConfigured: Bool {
        environmentKey != nil || UserDefaults.standard.bool(forKey: storedFlag)
    }

    static func read() -> String? {
        if let key = environmentKey { return key }
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
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        remove()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8),
        ]
        let ok = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        UserDefaults.standard.set(ok, forKey: storedFlag)
        return ok
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(false, forKey: storedFlag)
    }
}
