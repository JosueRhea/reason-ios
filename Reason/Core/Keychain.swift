import Foundation
import Security

enum Keychain {
    private static let service = "me.josuerhea.ReasonClient"
    private static let account = "api-key"
    /// Shared with the share extension (app groups double as keychain access groups).
    static let appGroup = "group.me.josuerhea.ReasonClient"

    private static func base(_ group: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if group { q[kSecAttrAccessGroup as String] = appGroup }
        return q
    }

    static func load() -> String? {
        if let k = read(group: true) { return k }
        // Migrate a key saved before the app group existed.
        if let legacy = read(group: false) { save(legacy); return legacy }
        return nil
    }

    private static func read(group: Bool) -> String? {
        var q = base(group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        var q = base(true)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(q as CFDictionary, nil) != errSecSuccess {
            // No app-group entitlement (e.g. unsigned build): fall back to the app's own keychain.
            var plain = base(false)
            plain[kSecValueData as String] = Data(key.utf8)
            plain[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(plain as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(base(true) as CFDictionary)
        SecItemDelete(base(false) as CFDictionary)
    }
}
