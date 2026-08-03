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

    // MARK: - Token 刷新（注入式：临时目录 + 纯解析，不测网络）

    /// readCredsFromFile：从临时 cache 目录读 refreshToken + clientId + clientSecret
    @Test func testLoadTokenCredsFromFile() throws {
        try withTempCacheDir { tmp in
            let result = KiroProvider().readCredsFromFile(refreshToken: nil, cacheDir: tmp)
            guard case .success(let creds) = result else {
                Issue.record("应为 .success，实际 \(result)")
                return
            }
            #expect(creds.refreshToken == "refresh-token-abc")
            #expect(creds.clientId == "client-id-123")
            #expect(creds.clientSecret.count == 5053)
        }
    }

    /// readCredsFromFile：传入 cached refreshToken 时优先使用它（本地持久化优先）
    @Test func testLoadTokenCredsPrefersCachedRefresh() throws {
        try withTempCacheDir { tmp in
            let result = KiroProvider().readCredsFromFile(refreshToken: "cached-refresh-token", cacheDir: tmp)
            guard case .success(let creds) = result else {
                Issue.record("应为 .success，实际 \(result)")
                return
            }
            #expect(creds.refreshToken == "cached-refresh-token")
            #expect(creds.clientId == "client-id-123")
            #expect(creds.clientSecret.count == 5053)
        }
    }

    /// readCredsFromFile：缺 clientIdHash / 缺 client 文件 → .missing
    @Test func testLoadTokenCredsMissingFiles() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("kiro-cache-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let result = KiroProvider().readCredsFromFile(refreshToken: nil, cacheDir: tmp)
        guard case .missing = result else {
            Issue.record("应为 .missing，实际 \(result)")
            return
        }
    }

    /// readCredsFromFile：Google/social 登录（无 clientIdHash）→ .unsupportedProvider
    @Test func testGoogleProviderUnsupported() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("kiro-cache-google-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        // 构造 Google 登录的 token 文件（无 clientIdHash，含 profileArn）
        let tok: [String: Any] = [
            "accessToken": "aoaAAA-test-token",
            "refreshToken": "aorAAA-test-refresh",
            "profileArn": "arn:aws:codewhisperer:us-east-1:123456789012:profile/test",
            "expiresAt": "2026-08-03T10:00:00.000Z",
            "authMethod": "social",
            "provider": "Google",
        ]
        try JSONSerialization.data(withJSONObject: tok).write(to: tmp.appendingPathComponent("kiro-auth-token.json"))
        let result = KiroProvider().readCredsFromFile(refreshToken: nil, cacheDir: tmp)
        guard case .unsupportedProvider = result else {
            Issue.record("应为 .unsupportedProvider，实际 \(result)")
            return
        }
    }

    /// parseTokenResponse：OIDC 200 响应 → accessToken + refreshToken
    @Test func testParseTokenResponse() throws {
        let json = """
        {"accessToken": "new-access-token", "refreshToken": "new-refresh-token",
         "expiresIn": 28800, "tokenType": "Bearer"}
        """
        let parsed = KiroProvider.parseTokenResponse(Data(json.utf8))
        #expect(parsed?.access == "new-access-token")
        #expect(parsed?.refresh == "new-refresh-token")
    }

    /// parseTokenResponse：响应无 refreshToken 字段 → refresh 为 nil，accessToken 仍返回
    @Test func testParseTokenResponseNoRefresh() throws {
        let json = #"{"accessToken": "new-access-token", "expiresIn": 28800}"#
        let parsed = KiroProvider.parseTokenResponse(Data(json.utf8))
        #expect(parsed?.access == "new-access-token")
        #expect(parsed?.refresh == nil)
    }

    /// parseTokenResponse：非法 JSON / 缺 accessToken / 空 accessToken → nil
    @Test func testParseTokenResponseInvalid() throws {
        #expect(KiroProvider.parseTokenResponse(Data(#"{"refreshToken":"x"}"#.utf8)) == nil)
        #expect(KiroProvider.parseTokenResponse(Data("not-json".utf8)) == nil)
        #expect(KiroProvider.parseTokenResponse(Data()) == nil)
    }

    /// defaultToken：优先读 LocalSecretStore 持久化的新 token（测试 key 与 App 相同，
    /// 但 Swift Testing 进程的 UserDefaults.standard 是测试 bundle 域；set 后清理不污染）
    @Test func testDefaultTokenPrefersCached() throws {
        let key = "kiroAccessToken"
        LocalSecretStore.set("cached-access-token", key: key)
        defer { LocalSecretStore.delete(key) }
        #expect(KiroProvider.defaultToken() == "cached-access-token")
    }

    // MARK: - 辅助

    /// 构造临时 .aws/sso/cache 目录（全部占位值，不接触真实凭据）；body 执行后自动清理
    private func withTempCacheDir(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("kiro-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // kiro-auth-token.json：refreshToken + clientIdHash
        let authToken: [String: Any] = [
            "accessToken": "expired-access-token",
            "refreshToken": "refresh-token-abc",
            "clientIdHash": "deadbeef",
            "expiresAt": "2030-01-01T00:00:00Z",
            "region": "us-east-1",
        ]
        try JSONSerialization.data(withJSONObject: authToken)
            .write(to: tmp.appendingPathComponent("kiro-auth-token.json"))

        // <clientIdHash>.json：clientId + clientSecret（5053 字符占位）
        let client: [String: Any] = [
            "clientId": "client-id-123",
            "clientSecret": String(repeating: "s", count: 5053),
            "expiresAt": "2030-01-01T00:00:00Z",
        ]
        try JSONSerialization.data(withJSONObject: client)
            .write(to: tmp.appendingPathComponent("deadbeef.json"))

        try body(tmp)
    }
}
