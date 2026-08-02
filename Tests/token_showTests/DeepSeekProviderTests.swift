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
        #expect(snap.shortText == "¥88.5")
        #expect(snap.status == .green)       // ≥50
        #expect(snap.fullText.contains("88.5"))
        #expect(snap.fullText.contains("78.5"))
    }

    @Test func testParseUSD() throws {
        let json = """
        { "is_available": true,
          "balance_infos": [ { "currency": "USD", "total_balance": "20.00",
                              "granted_balance": "0", "topped_up_balance": "20.00" } ] }
        """
        let provider = DeepSeekProvider(apiKeyProvider: { "sk-test" })
        let snap = try provider.parse(data: Data(json.utf8))
        #expect(snap.shortText == "$20")
        #expect(snap.status == .yellow)      // 10-50
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
}
