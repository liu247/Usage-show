// 注：本机仅有 Command Line Tools（无 Xcode），无 XCTest.framework，
// 故按计划改用 Swift Testing（import Testing），测试名与断言语义与计划中
// XCTest 版本一一对应，可无损改写回 XCTest。运行命令见 UsageSnapshotTests.swift 文件头。
import Foundation
import Testing
@testable import token_show

struct DeepSeekProviderTests {
    @Test func testParseBalance() throws {
        let json = """
        { "is_available": true,
          "balance_infos": [ { "currency": "CNY", "total_balance": "88.50",
                              "granted_balance": "10.00", "topped_up_balance": "78.50" } ] }
        """
        let provider = DeepSeekProvider(apiKeyProvider: { "sk-test" })
        let snap = try provider.parse(data: Data(json.utf8))
        // 直接按返回值显示：88.50 → "¥88.50"（不四舍五入、不裁剪位数）
        #expect(snap.shortText == "¥88.50")
        #expect(snap.status == .green)       // ≥50
        #expect(snap.fullText.contains("¥88.50"))
        #expect(snap.fullText.contains("¥78.50"))
    }

    @Test func testParseUSD() throws {
        let json = """
        { "is_available": true,
          "balance_infos": [ { "currency": "USD", "total_balance": "20.00",
                              "granted_balance": "0", "topped_up_balance": "20.00" } ] }
        """
        let provider = DeepSeekProvider(apiKeyProvider: { "sk-test" })
        let snap = try provider.parse(data: Data(json.utf8))
        #expect(snap.shortText == "$20.00")
        #expect(snap.status == .yellow)      // 10-50
    }

    /// 不四舍五入、不强制位数：保留 API 返回的原始精度（如 88.534 → "¥88.534"）
    @Test func testParsePreservesRawPrecision() throws {
        let json = """
        { "is_available": true,
          "balance_infos": [ { "currency": "CNY", "total_balance": "88.534",
                              "granted_balance": "0", "topped_up_balance": "88.534" } ] }
        """
        let provider = DeepSeekProvider(apiKeyProvider: { "sk-test" })
        let snap = try provider.parse(data: Data(json.utf8))
        #expect(snap.shortText == "¥88.534")
    }

    @Test func testLowBalanceRed() throws {
        let json = """
        { "is_available": true,
          "balance_infos": [ { "currency": "CNY", "total_balance": "5.00",
                              "granted_balance": "0", "topped_up_balance": "5.00" } ] }
        """
        let provider = DeepSeekProvider(apiKeyProvider: { "sk-test" })
        let snap = try provider.parse(data: Data(json.utf8))
        #expect(snap.status == .red)         // <10
    }

    @Test func testMissingKey() async {
        let provider = DeepSeekProvider(apiKeyProvider: { nil })
        await #expect(throws: DeepSeekProvider.DeepSeekError.self) {
            _ = try await provider.fetch()
        }
    }

    // MARK: - key 规范化（trim 首尾空白，修复粘贴换行导致的 401）

    @Test func testSanitizeKeyTrimsWhitespace() {
        // 用户报告的场景：粘贴 key 带尾随换行
        #expect(AppSettings.sanitizeKey("  sk-test  \n\n") == "sk-test")
        #expect(AppSettings.sanitizeKey("\nsk-test\r\n") == "sk-test")
        #expect(AppSettings.sanitizeKey("\tsk-test \n") == "sk-test")
        #expect(AppSettings.sanitizeKey("sk-test") == "sk-test")
    }

    @Test func testSanitizeKeyNilAndBlank() {
        // 纯空白视为未配置
        #expect(AppSettings.sanitizeKey("   \n\t ") == "")
        #expect(AppSettings.sanitizeKey("\n\n\n") == "")
        #expect(AppSettings.sanitizeKey(nil) == "")
    }

    @Test func testSanitizeKeyKeepsInnerWhitespace() {
        // 仅 trim 首尾，内部空白保留
        #expect(AppSettings.sanitizeKey(" sk-abc 123 ") == "sk-abc 123")
    }
}
