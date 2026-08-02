import Foundation

struct KiroProvider: UsageProvider {
    var id: String { "kiro" }
    var displayName: String { "Kiro" }

    enum KiroError: Error, LocalizedError {
        case notLoggedIn      // token 或 profileArn 缺失
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "kiro 未登录（token 或 profile 缺失）"
            case .invalidResponse: return "kiro 响应解析失败"
            }
        }
    }

    /// 注入式凭据读取，便于测试；默认读 kiro 本地配置文件。
    /// @Sendable：KiroProvider 将在后台刷新 Task（Task 8 RefreshScheduler）中跨隔离域使用，
    /// 闭包须可发送（默认实现与测试闭包均无捕获，安全）。
    let tokenProvider: @Sendable () -> String?
    let arnProvider: @Sendable () -> String?

    init(tokenProvider: (@Sendable () -> String?)? = nil,
         arnProvider: (@Sendable () -> String?)? = nil) {
        self.tokenProvider = tokenProvider ?? KiroProvider.defaultToken
        self.arnProvider = arnProvider ?? KiroProvider.defaultArn
    }

    /// ~/.aws/sso/cache/kiro-auth-token.json → accessToken（232 字符非 JWT）
    static func defaultToken() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/sso/cache/kiro-auth-token.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = obj["accessToken"] as? String, !tok.isEmpty else { return nil }
        return tok
    }

    /// ~/Library/Application Support/kiro/User/globalStorage/kiro.kiroagent/profile.json → arn
    static func defaultArn() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kiro/User/globalStorage/kiro.kiroagent/profile.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arn = obj["arn"] as? String, !arn.isEmpty else { return nil }
        return arn
    }

    func fetch() async throws -> UsageSnapshot {
        guard let token = tokenProvider(), !token.isEmpty,
              let arn = arnProvider(), !arn.isEmpty else {
            throw KiroError.notLoggedIn
        }
        // profileArn 含 ':' 与 '*'，用 URLComponents 做 percent-encoding
        var comps = URLComponents(string: "https://management.us-east-1.kiro.dev/getUsageLimits")!
        comps.queryItems = [URLQueryItem(name: "profileArn", value: arn)]
        let url = comps.url!
        let data: Data
        do {
            data = try await APIClient.get(url, headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
            ])
        } catch HTTPError.status(401) {
            // 一期策略：不自动刷新 token，提示重启 kiro
            return UsageSnapshot(providerID: id, shortText: "--",
                                 fullText: "kiro 登录过期，请重启 kiro 刷新",
                                 fractionUsed: nil, rawValue: "", error: "kiro 登录过期，请重启 kiro 刷新")
        }
        return try parse(data: data)
    }

    // MARK: - 解析（internal 供测试）

    func parse(data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let resp: GetUsageLimitsResponse
        do {
            resp = try decoder.decode(GetUsageLimitsResponse.self, from: data)
        } catch {
            // 调度层拿到类型化错误而非裸 DecodingError
            throw KiroError.invalidResponse
        }
        guard let entry = resp.usageBreakdownList.first(where: { $0.resourceType == "CREDIT" }) else {
            throw KiroError.invalidResponse
        }

        let remaining: Int
        let limit: Int
        var fullParts: [String] = []
        if entry.freeTrialInfo?.freeTrialStatus == "ACTIVE", let ft = entry.freeTrialInfo {
            // 免费试用桶（实测 500-106=394）
            remaining = ft.usageLimit - ft.currentUsage
            limit = ft.usageLimit
            fullParts.append("免费试用剩余 \(remaining)（额度 \(ft.usageLimit)）")
            fullParts.append("订阅已用 \(entry.currentUsage)/\(entry.usageLimit)")
        } else {
            // 订阅桶（实测 50-0=50）
            remaining = entry.usageLimit - entry.currentUsage
            limit = entry.usageLimit
            fullParts.append("订阅剩余 \(remaining)（额度 \(entry.usageLimit)）")
        }

        let short = "\(remaining)cr"
        let status: StatusLevel
        if limit > 0 {
            let ratio = Double(remaining) / Double(limit)
            status = ratio >= 0.5 ? .green : (ratio >= 0.1 ? .yellow : .red)
        } else {
            // 额度为 0 时按剩余绝对值兜底
            status = remaining >= 1000 ? .green : (remaining >= 300 ? .yellow : .red)
        }
        return UsageSnapshot(
            providerID: id, shortText: short,
            fullText: fullParts.joined(separator: "，"),
            fractionUsed: nil, rawValue: short, status: status)
    }
}

// MARK: - 响应模型（snake_case 字段名经 convertFromSnakeCase 自动映射）

struct GetUsageLimitsResponse: Decodable {
    let usageBreakdownList: [UsageBreakdownEntry]
    let subscriptionInfo: SubscriptionInfo?
    let nextDateReset: Int?

    struct UsageBreakdownEntry: Decodable {
        let resourceType: String
        let displayName: String?
        let currentUsage: Int
        let usageLimit: Int
        let freeTrialInfo: FreeTrialInfo?
    }
    struct FreeTrialInfo: Decodable {
        let currentUsage: Int
        let usageLimit: Int
        let freeTrialStatus: String?
    }
    struct SubscriptionInfo: Decodable {
        let subscriptionTitle: String?
    }
}
