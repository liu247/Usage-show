// 注：本机仅有 Command Line Tools（无 Xcode），SDK 不含 XCTest.framework，
// 故按计划改用 Swift Testing（import Testing，Swift 6.3 随 CLT 附带）。
// 测试名与断言语义与计划中 XCTest 版本一一对应，可无损改写回 XCTest。
// 本机运行 swift test 必须附加 CLT framework 搜索路径/链接旗标：
//   swift test --disable-sandbox --scratch-path /tmp/token_show_build \
//     -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//     -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//     -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//     -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
import Foundation
import Testing
@testable import token_show

struct UsageSnapshotTests {
    @Test func testStatusFromFractionUsed() {
        #expect(StatusLevel.fromFractionUsed(0.3) == .green)
        #expect(StatusLevel.fromFractionUsed(0.5) == .green)  // 边界：>0.5 才 yellow
        #expect(StatusLevel.fromFractionUsed(0.6) == .yellow)
        #expect(StatusLevel.fromFractionUsed(0.8) == .yellow)  // 边界：>0.8 才 red
        #expect(StatusLevel.fromFractionUsed(0.9) == .red)
        #expect(StatusLevel.fromFractionUsed(nil) == .gray)
    }

    @Test func testMenuBarTextAssembles() {
        let snap = UsageSnapshot(
            providerID: "codex", shortText: "4%", fullText: "周窗口剩余 4%",
            fractionUsed: 0.96, rawValue: "plan: plus", updatedAt: Date(), error: nil)
        #expect(snap.menuBarText == "C 4%")
    }

    @Test func testErrorSnapshotIsGray() {
        let snap = UsageSnapshot(
            providerID: "kiro", shortText: "--", fullText: "kiro 未登录",
            fractionUsed: nil, rawValue: "", updatedAt: Date(), error: "kiro 未登录")
        #expect(snap.status == .gray)
    }
}
