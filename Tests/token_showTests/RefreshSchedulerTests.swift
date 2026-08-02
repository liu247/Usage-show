// 注：本机仅有 Command Line Tools（无 Xcode），SDK 不含 XCTest.framework，
// 故按计划改用 Swift Testing（import Testing，Swift 6.3 随 CLT 附带）。
// 测试名与断言语义与计划中 XCTest 版本一一对应，可无损改写回 XCTest。
// 只测退避状态机 BackoffTracker，不测 Timer（Timer 依赖 RunLoop 与时间，属集成行为）。
// 本机运行 swift test 必须附加 CLT framework 搜索路径/链接旗标（见 UsageSnapshotTests 头注）。
import Foundation
import Testing
@testable import token_show

struct RefreshSchedulerTests {
    @Test func testBackoffStateMachine() {
        var s = BackoffTracker(threshold: 3, backoffInterval: 300)
        #expect(s.currentInterval(base: 45) == 45)
        s.recordFailure(); #expect(s.currentInterval(base: 45) == 45)  // 1 次失败不退避
        s.recordFailure(); #expect(s.currentInterval(base: 45) == 45)  // 2 次
        s.recordFailure(); #expect(s.currentInterval(base: 45) == 300) // 3 次 → 退避
        s.recordSuccess()
        #expect(s.currentInterval(base: 45) == 45) // 恢复
    }
}
