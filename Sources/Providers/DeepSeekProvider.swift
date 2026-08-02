import Foundation

struct DeepSeekProvider: UsageProvider {
    var id: String { "deepseek" }
    var displayName: String { "DeepSeek" }

    enum DeepSeekError: Error, LocalizedError {
        case missingKey
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingKey: return "未配置 API key（设置或环境变量 DEEPSEEK_API_KEY）"
            case .invalidResponse: return "deepseek 响应解析失败"
            }
        }
    }

    /// 注入式 key 读取：设置 > 环境变量；便于测试。
    /// @Sendable：Provider 将在后台刷新 Task（Task 8 RefreshScheduler）中跨隔离域使用，
    /// 闭包须可发送（默认实现与测试闭包均无捕获，安全）。
    let apiKeyProvider: @Sendable () -> String?

    init(apiKeyProvider: (@Sendable () -> String?)? = nil) {
        self.apiKeyProvider = apiKeyProvider ?? DeepSeekProvider.defaultApiKeyProvider
    }

    /// 默认 key 解析：AppSettings（设置）优先，DEEPSEEK_API_KEY 环境变量兜底。
    ///
    /// AppSettings 是 @MainActor 单例，其属性只能在主线程读取。fetch() 是 nonisolated async，
    /// 首个 await（网络请求）之前的代码运行在调用方 executor 上——app 内调用（启动/UI/调度器）
    /// 都在主线程，Task 2 注释已确认单例首次访问发生在主线程，故主线程路径用
    /// MainActor.assumeIsolated 同步读设置。为防未来后台刷新路径（Task 8）在非主线程调用本闭包
    /// 导致 assumeIsolated trap，非主线程时回退直读本地加密持久层（AppSettings.didSet 即时写入、
    /// 值一致，且 LocalSecretStore 纯函数读写线程安全、无授权交互）。
    /// key 存本地 AES-GCM 加密（LocalSecretStore，密文落 UserDefaults）；两处读取结果
    /// 均 trim 首尾空白（粘贴换行会导致 401）。
    static func defaultApiKeyProvider() -> String? {
        let fromSettings: String
        if Thread.isMainThread {
            fromSettings = MainActor.assumeIsolated { AppSettings.shared.deepseekApiKey }
        } else {
            fromSettings = LocalSecretStore.get("deepseekApiKey") ?? ""
        }
        let trimmed = AppSettings.sanitizeKey(fromSettings)
        if !trimmed.isEmpty { return trimmed }
        return AppSettings.sanitizeKey(ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"])
    }

    func fetch() async throws -> UsageSnapshot {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw DeepSeekError.missingKey
        }
        let url = URL(string: "https://api.deepseek.com/user/balance")!
        let data: Data
        do {
            data = try await APIClient.get(url, headers: [
                "Authorization": "Bearer \(key)",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ])
        } catch HTTPError.status(401) {
            return UsageSnapshot(providerID: id, shortText: "--", fullText: "API key 无效",
                                 fractionUsed: nil, rawValue: "", error: "API key 无效")
        }
        return try parse(data: data)
    }

    // MARK: - 解析（internal 供测试）

    func parse(data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let resp = try decoder.decode(BalanceResponse.self, from: data)
        guard let info = resp.balanceInfos.first,
              let total = Double(info.totalBalance) else {
            throw DeepSeekError.invalidResponse
        }
        let symbol = info.currency == "USD" ? "$" : "¥"
        let short = Self.format(symbol: symbol, value: total)
        let full = "\(short)（充值 \(Self.format(symbol: symbol, value: Double(info.toppedUpBalance) ?? 0)) / 赠送 \(Self.format(symbol: symbol, value: Double(info.grantedBalance) ?? 0))）"
        let status: StatusLevel = total >= 50 ? .green : (total >= 10 ? .yellow : .red)
        return UsageSnapshot(
            providerID: id,
            shortText: short,
            fullText: full,
            fractionUsed: nil,
            rawValue: "\(info.currency) \(info.totalBalance)",
            status: status
        )
    }

    /// 金额格式化：整数金额不带小数位（20.00 → "$20"），其余保留 1 位（88.50 → "¥88.5"）
    private static func format(symbol: String, value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%@%.0f", symbol, value)
        }
        return String(format: "%@%.1f", symbol, value)
    }
}

// MARK: - 响应模型

struct BalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    struct BalanceInfo: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String
    }
}
