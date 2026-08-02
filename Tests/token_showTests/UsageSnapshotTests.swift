// 注：本机仅有 Command Line Tools（无 Xcode），SDK 不含 XCTest.framework，
// 故按计划改用 Swift Testing（import Testing，Swift 6.3 随 CLT 附带）。
// 测试名与断言语义与计划中 XCTest 版本一一对应，可无损改写回 XCTest。
// 运行 swift test 需附加 CLT framework 搜索路径/链接旗标（见项目记忆）。
import Foundation
import Testing
@testable import token_show

struct UsageSnapshotTests {
    @Test func testStatusFromFractionUsed() {
        #expect(StatusLevel.fromFractionUsed(0.3) == .green)
        #expect(StatusLevel.fromFractionUsed(0.6) == .yellow)
        #expect(StatusLevel.fromFractionUsed(0.9) == .red)
        #expect(StatusLevel.fromFractionUsed(nil) == .gray)
    }

    @Test func testMenuBarTextAssembles() {
        let snap = UsageSnapshot(
            providerID: "codex", shortText: "4%", fullText: "周窗口剩余 4%",
            fractionUsed: 0.96, rawValue: "plan: plus", updatedAt: Date(), error: nil)
        #expect(snap.menuBarText == "C 4%")
    }

    @Test func testErrorSnapshotShowsDash() {
        let snap = UsageSnapshot(
            providerID: "kiro", shortText: "--", fullText: "kiro 未登录",
            fractionUsed: nil, rawValue: "", updatedAt: Date(), error: "kiro 未登录")
        #expect(snap.status == .gray)
    }
}
