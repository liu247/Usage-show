import Foundation

/// 单工具失败退避状态机
/// 连续失败达到 threshold 次后，轮询间隔切换为 backoffInterval（而非 base），
/// 让失败的工具退避，避免高频空转请求；任一次成功即清零计数恢复。
struct BackoffTracker {
    let threshold: Int
    let backoffInterval: Int
    private var consecutiveFailures = 0

    init(threshold: Int = 3, backoffInterval: Int = 300) {
        self.threshold = threshold
        self.backoffInterval = backoffInterval
    }

    mutating func recordFailure() { consecutiveFailures += 1 }
    mutating func recordSuccess() { consecutiveFailures = 0 }

    func currentInterval(base: Int) -> Int {
        consecutiveFailures >= threshold ? backoffInterval : base
    }
}

/// 主 actor 定时调度：按 AppSettings.refreshInterval 轮询启用的 Provider。
/// 每轮逐 Provider 独立 fetch：成功更新快照、失败记录错误并累计退避计数；
/// 处于退避中的 Provider 在本轮跳过（保持上次快照与错误信息）。
@MainActor
final class RefreshScheduler {
    private let store: RefreshStore
    private let providers: [String: any UsageProvider]
    private var backoffs: [String: BackoffTracker] = [:]
    private var timer: Timer?

    init(store: RefreshStore, providers: [any UsageProvider]) {
        self.store = store
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
    }

    func start() {
        timer?.invalidate()
        let interval = Double(AppSettings.shared.refreshInterval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { @MainActor in await refreshAll() }  // 启动即刷新一轮
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refreshNow() async {
        await refreshAll()
    }

    private func refreshAll() async {
        let enabled = AppSettings.shared.enabledProviders
        for (id, provider) in providers where enabled.contains(id) {
            let base = AppSettings.shared.refreshInterval
            var b = backoffs[id] ?? BackoffTracker()
            if b.currentInterval(base: base) != base {
                // 处于退避中，跳过本轮
                continue
            }
            do {
                let snap = try await provider.fetch()
                b.recordSuccess()
                store.update(snap)
            } catch {
                b.recordFailure()
                store.updateError(id: id, error: "\(error)")
            }
            backoffs[id] = b
        }
    }
}
