import CryptoKit
import Foundation
import IOKit

/// 本地加密存储：API key 等敏感值用 AES-GCM 加密后存 UserDefaults。
/// - 密钥从机器硬件 UUID + 用户名派生（SHA256），不落盘、本机绑定；
/// - 不用 Keychain（ad-hoc 签名 app 访问 Keychain 会触发授权弹窗/不稳定）；
/// - 打开即用，无授权交互。
enum LocalSecretStore {
    private static let prefix = "encrypted."

    /// 派生 AES-256 密钥：SHA256("\(IOPlatformUUID)-\(NSUserName())")
    static func deriveKey() -> SymmetricKey {
        let platformUUID = Self.platformUUID() ?? "unknown-platform"
        let material = "\(platformUUID)-\(NSUserName())"
        let hash = SHA256.hash(data: Data(material.utf8))
        return SymmetricKey(data: hash)
    }

    /// 存储字符串；加密后 base64 写入 UserDefaults（key 加前缀避免与明文键混淆）。
    /// 空字符串视为删除（set 空 = 清除旧值），避免"清空"后后台路径仍读到旧密文。
    @discardableResult
    static func set(_ value: String, key: String) -> Bool {
        if value.isEmpty { return delete(key) }
        guard let encrypted = try? encrypt(Data(value.utf8), key: deriveKey()) else { return false }
        UserDefaults.standard.set(encrypted.base64EncodedString(), forKey: prefix + key)
        return true
    }

    /// 读取并解密；不存在/解密失败返回 nil
    static func get(_ key: String) -> String? {
        guard let b64 = UserDefaults.standard.string(forKey: prefix + key),
              let data = Data(base64Encoded: b64),
              let plain = try? decrypt(data, key: deriveKey()) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// 删除；返回是否成功（不存在也算成功）
    @discardableResult
    static func delete(_ key: String) -> Bool {
        UserDefaults.standard.removeObject(forKey: prefix + key)
        return true
    }

    // MARK: - 加解密（internal 供测试：传入固定密钥验证往返与密文特性）

    static func encrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(data, using: key)
        return box.combined ?? Data()
    }

    static func decrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    // MARK: - 机器标识

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) else { return nil }
        return cf as? String
    }
}
