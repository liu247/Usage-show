import Foundation

/// @MainActor 的 RefreshScheduler 会把 provider 发送到 nonisolated async 的
/// fetch()（网络请求脱离 MainActor 执行），Swift 6 严格并发要求协议 Sendable；
/// 三个实现（Codex/DeepSeek/Kiro）均为值类型 + @Sendable 闭包，天然满足。
protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func fetch() async throws -> UsageSnapshot
}
