// 注：本机仅有 Command Line Tools（无 Xcode），无 XCTest.framework，
// 故按计划改用 Swift Testing（import Testing），测试名与断言语义与计划中
// XCTest 版本一一对应，可无损改写回 XCTest。运行命令见 UsageSnapshotTests.swift 文件头。
import Foundation
import Testing
@testable import token_show

struct CodexProviderTests {
    /// 用录制的真实响应结构验证解析
    @Test func testParseFullResponse() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 96, "limit_window_seconds": 604800,
                                "reset_after_seconds": 512273, "reset_at": 1786191472 },
            "secondary_window": null
          },
          "credits": { "has_credits": false, "balance": "0",
                       "overage_limit_reached": false },
          "rate_limit_reset_credits": { "available_count": 1 }
        }
        """
        let provider = CodexProvider(authProvider: { ("token", "acct") })
        let snap = try provider.parse(data: Data(json.utf8))
        #expect(snap.shortText == "4%")
        #expect(snap.fractionUsed == 0.96)
        #expect(snap.fullText.contains("周窗口"))
        #expect(snap.status == .red)  // used 96% > 80%
    }

    @Test func testParseWithSecondaryWindow() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 20, "limit_window_seconds": 604800,
                                "reset_after_seconds": 100, "reset_at": 1786191472 },
            "secondary_window": { "used_percent": 70, "limit_window_seconds": 18000,
                                  "reset_after_seconds": 200, "reset_at": 1786191472 }
          }
        }
        """
        let provider = CodexProvider(authProvider: { ("token", "acct") })
        let snap = try provider.parse(data: Data(json.utf8))
        #expect(snap.shortText == "80%|30%")
        #expect(snap.fullText.contains("5 小时"))
    }

    @Test func testStatusUsesTighterSecondaryWindow() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 20, "limit_window_seconds": 604800,
                                "reset_after_seconds": 100, "reset_at": 1786191472 },
            "secondary_window": { "used_percent": 90, "limit_window_seconds": 18000,
                                  "reset_after_seconds": 200, "reset_at": 1786191472 }
          }
        }
        """
        let provider = CodexProvider(authProvider: { ("token", "acct") })
        let snap = try provider.parse(data: Data(json.utf8))
        #expect(snap.shortText == "80%|10%")
        #expect(snap.fractionUsed == 0.9)          // 取更紧张窗口
        #expect(snap.status == .red)               // 0.9 > 0.8，不能因周窗口宽松显示绿
    }

    @Test func testAuthFileMissing() async {
        let provider = CodexProvider(authProvider: { throw CodexProvider.CodexError.notLoggedIn })
        await #expect(throws: CodexProvider.CodexError.self) {
            _ = try await provider.fetch()
        }
    }
}
