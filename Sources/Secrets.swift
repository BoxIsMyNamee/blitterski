import Foundation
import Security

/// Small Keychain helper. Falls back to UserDefaults because sideload containers
/// (LiveContainer etc.) can make the Keychain flaky.
enum Secrets {
    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "blitterski",
         kSecAttrAccount as String: key]
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        SecItemDelete(base(key) as CFDictionary)
        var add = base(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(data, forKey: "secret.\(key)")
        }
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let v = try? JSONDecoder().decode(T.self, from: d) {
            return v
        }
        if let d = UserDefaults.standard.data(forKey: "secret.\(key)") {
            return try? JSONDecoder().decode(T.self, from: d)
        }
        return nil
    }

    static func clear(key: String) {
        SecItemDelete(base(key) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "secret.\(key)")
    }
}
