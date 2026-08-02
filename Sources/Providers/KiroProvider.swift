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

    /// kiro token 刷新的凭据（来自 ~/.aws/sso/cache/）
    struct KiroTokenCreds {
        let refreshToken: String
        let clientId: String
        let clientSecret: String
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

    /// 默认 token 读取：优先 App 内刷新后持久化的新 token（LocalSecretStore.kiroAccessToken），
    /// 兜底读 ~/.aws/sso/cache/kiro-auth-token.json → accessToken（232 字符非 JWT）。
    static func defaultToken() -> String? {
        // 优先：App 内刷新后持久化的新 token
        if let cached = LocalSecretStore.get("kiroAccessToken"), !cached.isEmpty {
            return cached
        }
        // 兜底：.aws 文件
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
            // 401：凭证无效，提示重启 kiro
            return UsageSnapshot(providerID: id, shortText: "--",
                                 fullText: "kiro 登录过期，请重启 kiro 刷新",
                                 fractionUsed: nil, rawValue: "", error: "kiro 登录过期，请重启 kiro 刷新")
        } catch HTTPError.status(403) {
            // 403：accessToken 过期（{"message":"Token expired"}）→ OIDC refresh 后重试一次
            guard let refreshed = await refreshToken() else {
                return UsageSnapshot(providerID: id, shortText: "--",
                                     fullText: "kiro 登录过期，请重启 kiro 刷新",
                                     fractionUsed: nil, rawValue: "", error: "kiro 登录过期，请重启 kiro 刷新")
            }
            do {
                data = try await APIClient.get(url, headers: [
                    "Authorization": "Bearer \(refreshed)",
                    "Content-Type": "application/json",
                ])
            } catch HTTPError.status(401), HTTPError.status(403) {
                // 刷新后仍 401/403：登录已彻底失效
                return UsageSnapshot(providerID: id, shortText: "--",
                                     fullText: "kiro 登录过期，请重启 kiro 刷新",
                                     fractionUsed: nil, rawValue: "", error: "kiro 登录过期，请重启 kiro 刷新")
            }
        }
        return try parse(data: data)
    }

    // MARK: - Token 刷新（403 触发）

    /// 用 refreshToken 换新 accessToken；成功返回新 token 并持久化，失败返回 nil。
    /// 并发注意：fetch 在后台 executor 运行，本方法 nonisolated（struct 方法默认非隔离）。
    private func refreshToken() async -> String? {
        guard let creds = loadTokenCreds() else { return nil }
        guard let url = URL(string: "https://oidc.us-east-1.amazonaws.com/token") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grantType": "refresh_token",
            "refreshToken": creds.refreshToken,
            "clientId": creds.clientId,
            "clientSecret": creds.clientSecret,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let data: Data
        do {
            let (respData, resp) = try await APIClient.session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // 服务端明确拒绝（如 invalid_grant）：清除持久化凭据，回退 .aws 文件重读
                invalidateCachedCreds()
                return nil
            }
            data = respData
        } catch { return nil }  // 网络异常：保留缓存，下轮重试
        guard let parsed = Self.parseTokenResponse(data) else {
            invalidateCachedCreds()
            return nil
        }
        // 持久化新 token（不写 .aws 文件，存加密存储）
        _ = LocalSecretStore.set(parsed.access, key: "kiroAccessToken")
        if let newRefresh = parsed.refresh, !newRefresh.isEmpty {
            _ = LocalSecretStore.set(newRefresh, key: "kiroRefreshToken")
        }
        return parsed.access
    }

    /// 持久化刷新凭据已失效（OIDC 拒绝）：清除缓存，让下一轮 loadTokenCreds 回退 .aws 文件。
    /// 避免"kiro 重登录轮换凭据后，本地缓存旧 refreshToken 永久失败"。
    private func invalidateCachedCreds() {
        _ = LocalSecretStore.delete("kiroRefreshToken")
        _ = LocalSecretStore.delete("kiroAccessToken")
    }

    /// 读取刷新凭据：优先用持久化的 refreshToken，兜底读 .aws 文件
    private func loadTokenCreds() -> KiroTokenCreds? {
        // refreshToken：本地持久化优先 → .aws 文件
        let cachedRefresh = LocalSecretStore.get("kiroRefreshToken")
        if let cached = cachedRefresh, !cached.isEmpty {
            // clientId/clientSecret 仍需从 .aws 文件读（不常变）
            if let creds = readCredsFromFile(refreshToken: cached) { return creds }
        }
        return readCredsFromFile(refreshToken: nil)
    }

    /// 从 ~/.aws/sso/cache 读 clientId/clientSecret 与 refreshToken。
    /// cacheDir 可注入（测试用临时目录），默认行为不变。
    func readCredsFromFile(refreshToken cached: String?,
                           cacheDir: URL = FileManager.default.homeDirectoryForCurrentUser
                               .appendingPathComponent(".aws/sso/cache")) -> KiroTokenCreds? {
        // kiro-auth-token.json
        guard let tokData = try? Data(contentsOf: cacheDir.appendingPathComponent("kiro-auth-token.json")),
              let tok = try? JSONSerialization.jsonObject(with: tokData) as? [String: Any],
              let clientIdHash = tok["clientIdHash"] as? String else { return nil }
        let refresh = cached ?? (tok["refreshToken"] as? String)
        guard let refresh, !refresh.isEmpty else { return nil }
        // <clientIdHash>.json
        guard let clientData = try? Data(contentsOf: cacheDir.appendingPathComponent("\(clientIdHash).json")),
              let client = try? JSONSerialization.jsonObject(with: clientData) as? [String: Any],
              let clientId = client["clientId"] as? String, !clientId.isEmpty,
              let clientSecret = client["clientSecret"] as? String, !clientSecret.isEmpty else { return nil }
        return KiroTokenCreds(refreshToken: refresh, clientId: clientId, clientSecret: clientSecret)
    }

    // MARK: - 解析（internal 供测试）

    /// 解析 OIDC refresh 响应：提取 accessToken（refreshToken 可选）；非法/缺 accessToken 返回 nil。
    static func parseTokenResponse(_ data: Data) -> (access: String, refresh: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["accessToken"] as? String, !access.isEmpty else { return nil }
        return (access, obj["refreshToken"] as? String)
    }

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
