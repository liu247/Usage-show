// LocalSecretStore 测试：AES-GCM 加解密往返、密文特性、错误密钥失败、UserDefaults 集成。
// 运行命令见 UsageSnapshotTests.swift 文件头（CLT 框架搜索路径旗标一致）。
// UserDefaults.standard 在 swift test 进程里解析为测试 bundle 的偏好域（非真实 app 配置，
// 且本机无该 plist 时为空），但为稳妥仍用随机 key 名 + 测完 delete 清理，不触碰真实配置键。
import CryptoKit
import Foundation
import Testing
@testable import token_show

struct LocalSecretStoreTests {
    // MARK: - 加解密（固定密钥，不碰 UserDefaults）

    @Test func testEncryptDecryptRoundTrip() throws {
        let key = LocalSecretStore.deriveKey()
        let plain = "sk-secret-key-123"
        let cipher = try LocalSecretStore.encrypt(Data(plain.utf8), key: key)
        let decrypted = try LocalSecretStore.decrypt(cipher, key: key)
        #expect(String(data: decrypted, encoding: .utf8) == plain)
    }

    @Test func testUnicodeRoundTrip() throws {
        let key = LocalSecretStore.deriveKey()
        let plain = "中文值 🎉 sk-abc"
        let cipher = try LocalSecretStore.encrypt(Data(plain.utf8), key: key)
        let decrypted = try LocalSecretStore.decrypt(cipher, key: key)
        #expect(String(data: decrypted, encoding: .utf8) == plain)
    }

    @Test func testCiphertextDoesNotContainPlaintext() throws {
        let key = LocalSecretStore.deriveKey()
        let plain = "sk-secret-key"
        let cipher1 = try LocalSecretStore.encrypt(Data(plain.utf8), key: key)
        let cipher2 = try LocalSecretStore.encrypt(Data(plain.utf8), key: key)
        let b64 = cipher1.base64EncodedString()
        // 密文（base64）不泄露明文
        #expect(!b64.contains(plain))
        // AES-GCM 随机 nonce：同明文两次加密密文不同
        #expect(cipher1 != cipher2)
    }

    @Test func testDecryptWithWrongKeyFails() throws {
        let plain = Data("sk-secret-key".utf8)
        let cipher = try LocalSecretStore.encrypt(plain, key: LocalSecretStore.deriveKey())
        let wrongKey = SymmetricKey(size: .bits256) // 随机密钥
        #expect(throws: (any Error).self) {
            _ = try LocalSecretStore.decrypt(cipher, key: wrongKey)
        }
    }

    @Test func testTamperedCiphertextFails() throws {
        let key = LocalSecretStore.deriveKey()
        var cipher = try LocalSecretStore.encrypt(Data("sk-secret-key".utf8), key: key)
        // 篡改一个字节（GCM 认证标签校验应失败）
        cipher[cipher.startIndex] ^= 0x01
        #expect(throws: (any Error).self) {
            _ = try LocalSecretStore.decrypt(cipher, key: key)
        }
    }

    // MARK: - deriveKey

    @Test func testDeriveKeyIs256Bit() {
        let key = LocalSecretStore.deriveKey()
        let data = key.withUnsafeBytes { Data($0) }
        #expect(data.count == 32) // SHA256 → 32 字节 = AES-256
        #expect(!data.isEmpty)
    }

    // MARK: - UserDefaults 集成（随机 key 名 + 测完 delete）

    @Test func testSetGetDeleteRoundTrip() {
        let key = "test-key-\(UUID().uuidString)"
        defer { LocalSecretStore.delete(key) }

        #expect(LocalSecretStore.get(key) == nil)
        #expect(LocalSecretStore.set("sk-test-value", key: key))
        #expect(LocalSecretStore.get(key) == "sk-test-value")

        // 覆盖旧值
        #expect(LocalSecretStore.set("sk-test-2", key: key))
        #expect(LocalSecretStore.get(key) == "sk-test-2")

        #expect(LocalSecretStore.delete(key))
        #expect(LocalSecretStore.get(key) == nil)
    }

    @Test func testSetEmptyReturnsFalse() {
        let key = "test-empty-\(UUID().uuidString)"
        defer { LocalSecretStore.delete(key) }

        // 空串拒绝存储；也不应有密文残留
        #expect(!LocalSecretStore.set("", key: key))
        #expect(LocalSecretStore.get(key) == nil)
    }

    @Test func testStoredCiphertextIsNotPlaintext() {
        let key = "test-cipher-\(UUID().uuidString)"
        defer { LocalSecretStore.delete(key) }

        let plain = "sk-secret-key"
        #expect(LocalSecretStore.set(plain, key: key))
        // UserDefaults 里存的是加密后 base64，不应含明文
        let raw = UserDefaults.standard.string(forKey: "encrypted.\(key)")
        #expect(raw != nil)
        #expect(!(raw ?? "").contains(plain))
        // 读取能还原
        #expect(LocalSecretStore.get(key) == plain)
    }
}
