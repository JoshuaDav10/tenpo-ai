import Foundation
#if canImport(Security)
import Security

/// Keychain-backed session persistence (generic-password item, JSON payload).
/// Tokens never touch UserDefaults or files; the item is device-only and survives
/// app reinstalls only per normal Keychain semantics.
public struct KeychainSessionStore: AuthSessionStore {
    private let service: String
    private let account: String

    public init(service: String = "app.kizuna.auth", account: String = "session") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> AuthSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    public func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
#endif
