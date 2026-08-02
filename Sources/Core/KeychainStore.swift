import Foundation
import Security

/// 轻量 Keychain 封装：用于存储敏感配置（如 DeepSeek API key）。
/// 明文不可见，随系统备份/迁移（Keychain 自身机制）。
enum KeychainStore {
    private static let service = "com.local.usage-show"

    /// 存储字符串；成功返回 true（先删后插，天然 upsert）。
    /// `keychain` 仅供测试注入临时 keychain；生产调用不传，走系统默认（login）keychain。
    @discardableResult
    static func set(_ value: String, key: String, keychain: SecKeychain? = nil) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // 先删除旧值再插入（简化 upsert）。删除与插入须定向同一 keychain，
        // 避免测试注入时误删默认 keychain 的同名项。
        if let keychain {
            var delQ = query
            delQ[kSecMatchSearchList as String] = [keychain]
            SecItemDelete(delQ as CFDictionary)
        } else {
            SecItemDelete(query as CFDictionary)
        }
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let keychain {
            // 实测：kSecUseKeychain 仅对 SecItemAdd 有效
            attrs[kSecUseKeychain as String] = keychain
        }
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 读取字符串；不存在或失败返回 nil。
    static func get(_ key: String, keychain: SecKeychain? = nil) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var attrs = query
        if let keychain {
            // 实测：kSecUseKeychain 对 SecItemCopyMatching 无效（-25300），须用 kSecMatchSearchList
            attrs[kSecMatchSearchList as String] = [keychain]
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(attrs as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除；返回是否成功（不存在也算成功）。
    @discardableResult
    static func delete(_ key: String, keychain: SecKeychain? = nil) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        var attrs = query
        if let keychain {
            attrs[kSecMatchSearchList as String] = [keychain]
        }
        let status = SecItemDelete(attrs as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
