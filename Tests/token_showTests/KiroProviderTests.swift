// 注：本机仅有 Command Line Tools（无 Xcode），无 XCTest.framework，
// 故按计划改用 Swift Testing（import Testing，Swift 6.3 随 CLT 附带）。
// 测试名与断言语义与计划中 XCTest 版本一一对应，可无损改写回 XCTest。
// 运行命令见 UsageSnapshotTests.swift 文件头。
import Foundation
import Testing
@testable import token_show

struct KiroProviderTests {
    /// 免费试用 ACTIVE：显示 freeTrial 桶剩余 394cr（500-106）
    @Test func testParseActiveFreeTrial() throws {
        let json = """
        {
          "usageBreakdownList": [
            { "resourceType": "CREDIT", "displayName": "Credit",
              "currentUsage": 0, "usageLimit": 50,
              "freeTrialInfo": { "currentUsage": 106, "usageLimit": 500,
                                 "freeTrialStatus": "ACTIVE" } }
          ],
          "subscriptionInfo": { "subscriptionTitle": "KIRO FREE" },
          "nextDateReset": 1786191472
        }
        """
        let provider = KiroProvider(tokenProvider: { "tok" }, arnProvider: { "arn" })
        let snap = try provider.parse(data: Data(json.utf8))
        #expect(snap.shortText == "394cr")
        #expect(snap.fullText.contains("394"))
        #expect(snap.fullText.contains("500"))
        #expect(snap.status == .green)  // 394/500 = 78.8% ≥ 50%
    }

    /// 无免费试用（freeTrialInfo 为 null）：显示订阅桶剩余 50cr
    @Test func testParseNoFreeTrial() throws {
        let json = """
        {
          "usageBreakdownList": [
            { "resourceType": "CREDIT", "displayName": "Credit",
              "currentUsage": 0, "usageLimit": 50, "freeTrialInfo": null }
          ],
          "subscriptionInfo": { "subscriptionTitle": "KIRO PAID" }
        }
        """
        let provider = KiroProvider(tokenProvider: { "tok" }, arnProvider: { "arn" })
        let snap = try provider.parse(data: Data(json.utf8))
        #expect(snap.shortText == "50cr")
        #expect(snap.fullText.contains("50"))
        #expect(snap.status == .green)  // 50/50 = 1.0 ≥ 0.5 → green（非注释中的 yellow）
    }

    /// 无 token：notLoggedIn 错误
    @Test func testNoToken() async {
        let provider = KiroProvider(tokenProvider: { nil }, arnProvider: { "arn" })
        await #expect(throws: KiroProvider.KiroError.notLoggedIn) {
            _ = try await provider.fetch()
        }
    }

    /// overage 超用：remaining 为负，shortText 显示负数，status 仍为 .red（安全方向）
    @Test func testOverageShowsNegativeButRed() throws {
        let json = """
        {
          "usageBreakdownList": [
            { "resourceType": "CREDIT", "displayName": "Credit",
              "currentUsage": 120, "usageLimit": 50, "freeTrialInfo": null }
          ]
        }
        """
        let provider = KiroProvider(tokenProvider: { "tok" }, arnProvider: { "arn" })
        let snap = try provider.parse(data: Data(json.utf8))
        #expect(snap.shortText == "-70cr")
        #expect(snap.status == .red)  // -70/50 = -1.4 < 0.1 → red
    }
}
