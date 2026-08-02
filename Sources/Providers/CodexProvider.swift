import Foundation

struct CodexProvider: UsageProvider {
    var id: String { "codex" }
    var displayName: String { "Codex" }

    enum CodexError: Error {
        case notLoggedIn          // ~/.codex/auth.json 缺失或无法解析
        case invalidResponse
    }

    /// 注入式凭据读取，便于测试；默认读 ~/.codex/auth.json
    /// @Sendable：CodexProvider 将在后台刷新 Task 中跨隔离域使用，闭包须可发送（默认实现与测试闭包均无捕获，安全）
    let authProvider: @Sendable () throws -> (accessToken: String, accountID: String)

    init(authProvider: (@Sendable () throws -> (accessToken: String, accountID: String))? = nil) {
        self.authProvider = authProvider ?? CodexProvider.defaultAuth
    }

    static func defaultAuth() throws -> (accessToken: String, accountID: String) {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let acct = tokens["account_id"] as? String,
              !access.isEmpty, !acct.isEmpty else {
            throw CodexError.notLoggedIn
        }
        return (access, acct)
    }

    func fetch() async throws -> UsageSnapshot {
        let auth = try authProvider()
        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "ChatGPT-Account-ID": auth.accountID,
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126.0",
        ]
        headers["oai-device-id"] = UUID().uuidString
        let url = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
        let data: Data
        do {
            data = try await APIClient.get(url, headers: headers)
        } catch HTTPError.status(401) {
            return UsageSnapshot(providerID: id, shortText: "--", fullText: "需重新登录 codex",
                                 fractionUsed: nil, rawValue: "", error: "需重新登录 codex")
        } catch HTTPError.status(403) {
            return UsageSnapshot(providerID: id, shortText: "--", fullText: "访问被拒绝（403），请检查登录态",
                                 fractionUsed: nil, rawValue: "", error: "403")
        }
        return try parse(data: data)
    }

    // MARK: - 解析（internal 供测试）

    func parse(data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let resp: CodexUsageResponse
        do {
            resp = try decoder.decode(CodexUsageResponse.self, from: data)
        } catch {
            // 调度层拿到类型化错误而非裸 DecodingError
            throw CodexError.invalidResponse
        }

        let primary = resp.rateLimit.primaryWindow
        let remaining = 100 - primary.usedPercent
        let primaryUsed = Double(primary.usedPercent) / 100.0

        // 状态色取两个窗口中更紧张的那个（防 5 小时窗口耗尽时仍显示绿）
        var worstUsed = primaryUsed
        if let secondary = resp.rateLimit.secondaryWindow {
            let sUsed = Double(secondary.usedPercent) / 100.0
            if sUsed > worstUsed { worstUsed = sUsed }
        }

        var fullParts = ["周窗口剩余 \(remaining)%"]
        var short = "\(remaining)%"
        if let secondary = resp.rateLimit.secondaryWindow {
            let sRemain = 100 - secondary.usedPercent
            short = "\(remaining)%|\(sRemain)%"
            fullParts.append("5 小时窗口剩余 \(sRemain)%")
        }
        if resp.credits?.hasCredits == true, let bal = resp.credits?.balance, bal != "0" {
            fullParts.append("credits: \(bal)")
        }
        return UsageSnapshot(
            providerID: id,
            shortText: short,
            fullText: fullParts.joined(separator: "，"),
            fractionUsed: worstUsed,
            rawValue: "plan: \(resp.planType)"
        )
    }
}

// MARK: - 响应模型

struct CodexUsageResponse: Decodable {
    let planType: String
    let rateLimit: RateLimit
    let credits: Credits?

    struct RateLimit: Decodable {
        let allowed: Bool
        let limitReached: Bool
        let primaryWindow: Window
        let secondaryWindow: Window?

        struct Window: Decodable {
            let usedPercent: Int
            let limitWindowSeconds: Int
            let resetAfterSeconds: Int
            let resetAt: Int
        }
    }

    struct Credits: Decodable {
        let hasCredits: Bool
        let balance: String
    }
}
