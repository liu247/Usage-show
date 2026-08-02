import Foundation

/// 单工具失败退避状态机（时间驱动）
/// 连续失败达到 threshold 次后进入退避：nextRetryAt = 失败时刻 + backoffInterval。
/// 退避期内 isBackingOff(now:) 为 true（调度层跳过该 provider）；时间过了 nextRetryAt
/// 自然恢复重试——即使没有成功，也会在下一轮重新 fetch，避免"永久跳过"。
/// 退避中再次失败会把 nextRetryAt 往后推（不缩短等待）；任一次成功清零计数与退避。
/// 纯值类型：时间作为参数传入（recordFailure(now:)/isBackingOff(now:)），便于测试。
struct BackoffTracker {
    let threshold: Int
    let backoffInterval: Int
    private var consecutiveFailures = 0
    private var nextRetryAt: Date?

    init(threshold: Int = 3, backoffInterval: Int = 300) {
        self.threshold = threshold
        self.backoffInterval = backoffInterval
    }

    mutating func recordFailure(now: Date) {
        consecutiveFailures += 1
        if consecutiveFailures >= threshold {
            // 达到阈值即设定退避终点；退避中再失败会顺延（基于最新失败时刻）
            nextRetryAt = now.addingTimeInterval(TimeInterval(backoffInterval))
        }
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        nextRetryAt = nil
    }

    func isBackingOff(now: Date) -> Bool {
        guard let nextRetryAt else { return false }
        return now < nextRetryAt
    }
}

/// 主 actor 定时调度：按 AppSettings.refreshInterval 轮询启用的 Provider。
/// 每轮逐 Provider 独立 fetch：成功更新快照、失败记录错误并累计退避计数；
/// 处于退避中的 Provider 在本轮跳过（保持上次快照与错误信息），时间到后自动恢复。
/// `now` 可注入（默认 Date.init），测试用可控时钟验证退避时间语义。
@MainActor
final class RefreshScheduler {
    private let store: RefreshStore
    private let providers: [String: any UsageProvider]
    private let now: () -> Date
    private var backoffs: [String: BackoffTracker] = [:]
    private var timer: Timer?
    private var isRefreshing = false  // 重叠保护：慢请求下防止 Timer 双触发并发 fetch

    init(store: RefreshStore, providers: [any UsageProvider],
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        // uniquingKeysWith 防未来重复 id 崩溃（codex/deepseek/kiro 当前唯一）
        self.providers = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })
    }

    func start() {
        timer?.invalidate()
        timer = makeTimer()
        Task { @MainActor in await refreshAll() }  // 启动即刷新一轮
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// 刷新间隔设置变化后重建定时器：invalidate 旧 timer，按当前 AppSettings.refreshInterval 重建。
    /// 由 AppDelegate 监听 AppSettings.$refreshInterval 时调用，使设置窗口的 30/45/60s 实时生效。
    func reschedule() {
        timer?.invalidate()
        timer = makeTimer()
    }

    /// 按 AppSettings.shared.refreshInterval 创建 repeating timer（start/reschedule 共用）。
    private func makeTimer() -> Timer {
        let interval = Double(AppSettings.shared.refreshInterval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    func refreshNow() async {
        await refreshAll()
    }

    private func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let enabled = AppSettings.shared.enabledProviders
        for (id, provider) in providers where enabled.contains(id) {
            var b = backoffs[id] ?? BackoffTracker()
            if b.isBackingOff(now: now()) {
                // 处于退避中，跳过本轮；时间到后自然恢复重试
                continue
            }
            do {
                let snap = try await provider.fetch()
                b.recordSuccess()
                store.update(snap)
            } catch {
                b.recordFailure(now: now())
                store.updateError(id: id, error: Self.errorText(error))
            }
            backoffs[id] = b
        }
    }

    /// 错误 → 展示文本：LocalizedError 优先取其中文 errorDescription，其余保留原始描述（如 status(500)）。
    static func errorText(_ error: Error) -> String {
        if let localized = error as? any LocalizedError, let desc = localized.errorDescription {
            return desc
        }
        return String(describing: error)
    }
}
