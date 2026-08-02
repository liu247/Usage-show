// KeychainStore 往返测试。运行命令见 UsageSnapshotTests.swift 文件头。
// 本测试环境的 shell 无法访问 login keychain（实测 SecItemAdd 返回 EPERM/100001），
// 故每个测试用 SecKeychainCreate 建独立临时 keychain 并定向写入（KeychainStore 的
// `keychain` 参数是专为此加的测试注入点，生产调用不受影响），测完删除清理。
// 用随机 key 名避免任何残留；不触碰真实配置键（deepseekApiKey）。
import Foundation
import Security
import Testing
@testable import token_show

struct KeychainStoreTests {
    private enum TestError: Error, CustomStringConvertible {
        case createKeychainFailed(OSStatus)
        var description: String {
            switch self {
            case .createKeychainFailed(let status): return "创建临时 keychain 失败: \(status)"
            }
        }
    }

    /// 创建独立临时 keychain；测试结束后删除。
    private static func makeTempKeychain() throws -> SecKeychain {
        let path = NSTemporaryDirectory() + "keychain-test-\(UUID().uuidString).keychain"
        var keychain: SecKeychain?
        let password = "testpass"
        let status = SecKeychainCreate(
            path, UInt32(password.utf8.count), password, false, nil, &keychain)
        guard status == errSecSuccess, let kc = keychain else {
            throw TestError.createKeychainFailed(status)
        }
        return kc
    }

    @Test func testSetGetDeleteRoundTrip() throws {
        let kc = try Self.makeTempKeychain()
        defer { SecKeychainDelete(kc) }

        let key = "test-key-\(UUID().uuidString)"

        // 初始不存在
        #expect(KeychainStore.get(key, keychain: kc) == nil)

        // set → get 往返
        #expect(KeychainStore.set("sk-test-value", key: key, keychain: kc))
        #expect(KeychainStore.get(key, keychain: kc) == "sk-test-value")

        // upsert（先删后插）：覆盖旧值
        #expect(KeychainStore.set("sk-test-updated", key: key, keychain: kc))
        #expect(KeychainStore.get(key, keychain: kc) == "sk-test-updated")

        // delete → 不可再读
        #expect(KeychainStore.delete(key, keychain: kc))
        #expect(KeychainStore.get(key, keychain: kc) == nil)
    }

    @Test func testSetGetEmptyAndUnicode() throws {
        let kc = try Self.makeTempKeychain()
        defer { SecKeychainDelete(kc) }

        let key = "test-key-\(UUID().uuidString)"

        #expect(KeychainStore.set("", key: key, keychain: kc))
        #expect(KeychainStore.get(key, keychain: kc) == "")
        #expect(KeychainStore.set("中文值 🎉", key: key, keychain: kc))
        #expect(KeychainStore.get(key, keychain: kc) == "中文值 🎉")
    }

    @Test func testDeleteNonExistentIsSuccess() throws {
        let kc = try Self.makeTempKeychain()
        defer { SecKeychainDelete(kc) }

        // 不存在也算成功（errSecItemNotFound 视为成功）
        #expect(KeychainStore.delete("test-missing-\(UUID().uuidString)", keychain: kc))
    }

    @Test func testGetMissingReturnsNil() throws {
        let kc = try Self.makeTempKeychain()
        defer { SecKeychainDelete(kc) }

        #expect(KeychainStore.get("test-missing-\(UUID().uuidString)", keychain: kc) == nil)
    }

    @Test func testSetWithSameKeyTwiceLeavesOneItem() throws {
        let kc = try Self.makeTempKeychain()
        defer { SecKeychainDelete(kc) }

        let key = "test-key-\(UUID().uuidString)"
        #expect(KeychainStore.set("v1", key: key, keychain: kc))
        #expect(KeychainStore.set("v2", key: key, keychain: kc))
        // 覆盖而非新增：读到的应是最新值
        #expect(KeychainStore.get(key, keychain: kc) == "v2")
    }
}
