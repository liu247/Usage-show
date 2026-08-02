// 注：本机仅有 Command Line Tools（无 Xcode），SDK 不含 XCTest.framework，
// 故按计划改用 Swift Testing（import Testing，Swift 6.3 随 CLT 附带）。
// 测试名与断言语义与计划中 XCTest 版本一一对应，可无损改写回 XCTest。
// 只测退避状态机 BackoffTracker 与 scheduler 级恢复流程，不测 Timer
// （Timer 依赖 RunLoop 与真实时间，属集成行为；时间语义经注入 now 闭包验证）。
// 本机运行 swift test 必须附加 CLT framework 搜索路径/链接旗标（见 UsageSnapshotTests 头注）。
import Foundation
import Testing
@testable import token_show

struct RefreshSchedulerTests {

    // MARK: - BackoffTracker 时间语义

    @Test func testBackoffStateMachine() {
        var s = BackoffTracker(threshold: 3, backoffInterval: 300)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(s.isBackingOff(now: t0) == false)
        s.recordFailure(now: t0); #expect(s.isBackingOff(now: t0) == false)  // 1 次失败不退避
        s.recordFailure(now: t0); #expect(s.isBackingOff(now: t0) == false)  // 2 次
        s.recordFailure(now: t0); #expect(s.isBackingOff(now: t0) == true)   // 3 次 → 退避
        #expect(s.isBackingOff(now: t0.addingTimeInterval(301)) == false)    // 时间过了自动恢复
        s.recordSuccess()
        #expect(s.isBackingOff(now: t0) == false)                            // 成功清零恢复
    }

    @Test func testBackoffReEntryAfterFailure() {
        // 退避期间再失败会推迟 nextRetryAt（不缩短等待）
        var s = BackoffTracker(threshold: 1, backoffInterval: 300)
        let t0 = Date(timeIntervalSince1970: 0)
        s.recordFailure(now: t0)
        #expect(s.isBackingOff(now: t0.addingTimeInterval(100)) == true)
        s.recordFailure(now: t0.addingTimeInterval(100))   // 退避中再失败
        #expect(s.isBackingOff(now: t0.addingTimeInterval(350)) == true)   // 仍退避（100+300=400 才恢复）
        #expect(s.isBackingOff(now: t0.addingTimeInterval(450)) == false)  // 过了新的 nextRetryAt 恢复
    }

    // MARK: - Scheduler 级恢复流程（mock provider + 可控时钟）

    @Test @MainActor func testSchedulerBackoffRecoversAfterInterval() async {
        let settings = AppSettings.shared
        let savedEnabled = settings.enabledProviders
        settings.enabledProviders = ["mock"]   // 启用 mock；默认列表是 codex/deepseek/kiro
        defer { settings.enabledProviders = savedEnabled }

        let store = RefreshStore()
        let mock = MockProvider(id: "mock", shouldFail: true)
        var currentTime = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = RefreshScheduler(store: store, providers: [mock], now: { currentTime })

        // 连续 3 次失败 → store 有错误快照，进入退避
        await scheduler.refreshNow()
        await scheduler.refreshNow()
        await scheduler.refreshNow()
        #expect(mock.fetchCount == 3)
        #expect(store.snapshot(for: "mock")?.error != nil)

        // 第 4 次：mock 已能成功，但仍在退避期 → 跳过不 fetch
        mock.shouldFail = false
        await scheduler.refreshNow()
        #expect(mock.fetchCount == 3)                       // 未触发 fetch
        #expect(store.snapshot(for: "mock")?.error != nil)  // 错误快照保留

        // 时间推进 301s，退避解除 → 重新 fetch 成功，store 更新为成功快照
        currentTime = currentTime.addingTimeInterval(301)
        await scheduler.refreshNow()
        #expect(mock.fetchCount == 4)
        #expect(store.snapshot(for: "mock")?.error == nil)
        #expect(store.snapshot(for: "mock")?.shortText == "10%")

        // 恢复后再失败 1 次（threshold=3 未到）→ 不立即退避，下次仍会 fetch
        mock.shouldFail = true
        await scheduler.refreshNow()
        #expect(mock.fetchCount == 5)
        await scheduler.refreshNow()
        #expect(mock.fetchCount == 6)
    }
}

/// 可控失败/成功与调用计数的 mock Provider。
/// 跨 @MainActor 测试方法访问 + nonisolated fetch 调用，用锁保护可变状态（@unchecked Sendable）。
private final class MockProvider: UsageProvider, @unchecked Sendable {
    enum MockError: Error { case fail }

    private let lock = NSLock()
    private var _shouldFail: Bool
    private var _fetchCount = 0
    let id: String
    var displayName: String { id }

    init(id: String, shouldFail: Bool) {
        self.id = id
        self._shouldFail = shouldFail
    }

    var shouldFail: Bool {
        get { lock.withLock { _shouldFail } }
        set { lock.withLock { _shouldFail = newValue } }
    }
    var fetchCount: Int { lock.withLock { _fetchCount } }

    func fetch() async throws -> UsageSnapshot {
        lock.withLock { _fetchCount += 1 }
        if lock.withLock({ _shouldFail }) {
            throw MockError.fail
        }
        return UsageSnapshot(
            providerID: id, shortText: "10%", fullText: "ok",
            fractionUsed: 0.1, rawValue: "", updatedAt: Date())
    }
}
