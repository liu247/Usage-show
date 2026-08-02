# token_show Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个 macOS 菜单栏常驻小工具，实时显示 codex / deepseek / kiro 的 token 额度与剩余量（图标+数字+颜色），30-60s 轮询，防止额度耗尽无感知。

**Architecture:** Swift Package 可执行文件（无外部依赖）。三层：`Core/`（`UsageProvider` 协议 + `UsageSnapshot` 模型 + `RefreshScheduler` 调度）、`Providers/`（CodexProvider / DeepSeekProvider / KiroProvider，可插拔）、`App/`（AppKit NSStatusItem 菜单栏 UI + SwiftUI 设置窗口）。单工具失败不影响其他，失败退避轮询。

**Tech Stack:** Swift 6.3（swift-tools-version 6.0，platform .macOS(.v13)）、SwiftUI（Settings 窗口）、AppKit（NSStatusItem/NSMenu）、Foundation URLSession（网络）、UserDefaults（配置）、XCTest（Provider 解析单元测试）。

**规格依据:** `docs/superpowers/specs/2026-08-02-token-show-design.md`

---

## 关键决策（实现前必读）

1. **入口方式**：`@main` SwiftUI App + `NSApplicationDelegateAdaptor`（AppDelegate 管理 status item / 定时器 / 状态）。`App.body` 仅含 `Settings { SettingsView() }`，通过 status menu 的"设置…"用 `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` 打开。
2. **无 Dock 图标**：AppDelegate 里 `NSApp.setActivationPolicy(.accessory)`（运行时等效 LSUIElement，避免 swift run 下 Info.plist 的复杂性）。
3. **并发模型**：`RefreshStore`（`@MainActor final class ObservableObject`）持有 `[String: UsageSnapshot]` 字典；`RefreshScheduler` 在主 actor 上用 `Timer` 每 N 秒触发 `Task { await store.refreshAll() }`。
4. **JSON 解码**：统一 `decoder.keyDecodingStrategy = .convertFromSnakeCase`。
5. **kiro 逆向**：Task 5 是探索任务，产出 `docs/kiro-reverse-notes.md`（端点 + 认证方式 + token 提取三要素），Task 6 依据该笔记实现；笔记缺失时 Task 6 走兜底占位。
6. **金额/信用无比例**：`UsageSnapshot.fractionUsed == nil`，颜色按 Provider 自定义阈值判断（在 Provider 内算好状态枚举传入）。

## 文件结构

| 文件 | 职责 |
|---|---|
| `Package.swift` | SwiftPM 清单：executable + test target |
| `Sources/App/AppMain.swift` | `@main` SwiftUI App + AppDelegateAdaptor |
| `Sources/App/AppDelegate.swift` | NSApplicationDelegate：创建 status item、菜单、scheduler、store |
| `Sources/App/StatusBarController.swift` | 维护 NSStatusItem，渲染快照（标题/圆点颜色/tooltip），构建下拉菜单 |
| `Sources/App/SettingsView.swift` | SwiftUI 设置窗口：三工具开关、deepseek key、刷新间隔 |
| `Sources/Core/UsageProvider.swift` | `UsageProvider` 协议 |
| `Sources/Core/UsageSnapshot.swift` | `UsageSnapshot` 模型 + `StatusLevel` 枚举 |
| `Sources/Core/RefreshScheduler.swift` | 定时轮询 + 失败退避 |
| `Sources/Core/AppSettings.swift` | UserDefaults 封装（enabledProviders / deepseekApiKey / refreshInterval） |
| `Sources/Providers/CodexProvider.swift` | codex usage API |
| `Sources/Providers/DeepSeekProvider.swift` | deepseek balance API |
| `Sources/Providers/KiroProvider.swift` | kiro 信用值（依据逆向笔记） |
| `Sources/Providers/APIClient.swift` | 共享 URLSession 请求封装（GET + headers + 超时 10s） |
| `Tests/CodexProviderTests.swift` | codex 解析测试 |
| `Tests/DeepSeekProviderTests.swift` | deepseek 解析测试 |
| `Tests/KiroProviderTests.swift` | kiro 解析测试 |
| `Tests/UsageSnapshotTests.swift` | 状态色/文本格式化测试 |
| `docs/kiro-reverse-notes.md` | Task 5 产出：kiro 逆向结论 |

---

## Task 1: 项目脚手架（Package.swift + 空 target + 构建验证）

**Files:**
- Create: `Package.swift`
- Create: `Sources/App/AppMain.swift`（占位 main，后续任务填充）
- Create: `Sources/Core/UsageSnapshot.swift`（先建空骨架文件，Task 2 填充）

- [ ] **Step 1: 写 Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "token_show",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "token_show",
            path: "Sources"
        ),
        .testTarget(
            name: "token_showTests",
            dependencies: ["token_show"],
            path: "Tests"
        ),
    ]
)
```

- [ ] **Step 2: 写占位 AppMain.swift**

```swift
import SwiftUI

@main
struct TokenShowApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}
```

- [ ] **Step 3: 建空 UsageSnapshot.swift 骨架**

```swift
import Foundation

enum StatusLevel {
    case green, yellow, red, gray
}
```

- [ ] **Step 4: 构建验证**

Run: `cd <仓库路径> && swift build`
Expected: 构建成功，无错误（可能因 executable target 无 main 报错 → 若报 "main" 缺失，确认 AppMain.swift 已含 `@main` 后重跑；SwiftUI App 的 `@main` 即为入口）

- [ ] **Step 5: 提交**

```bash
cd <仓库路径> && git add Package.swift Sources/ && git commit -m "chore: 项目脚手架（SwiftPM executable + SwiftUI 入口占位）"
```

---

## Task 2: Core 模型（UsageSnapshot + UsageProvider 协议 + AppSettings）

**Files:**
- Modify: `Sources/Core/UsageSnapshot.swift`
- Create: `Sources/Core/UsageProvider.swift`
- Create: `Sources/Core/AppSettings.swift`
- Create: `Tests/UsageSnapshotTests.swift`

- [ ] **Step 1: 写失败测试（Tests/UsageSnapshotTests.swift）**

```swift
import XCTest
@testable import token_show

final class UsageSnapshotTests: XCTestCase {
    func testStatusFromFractionUsed() {
        XCTAssertEqual(StatusLevel.fromFractionUsed(0.3), .green)
        XCTAssertEqual(StatusLevel.fromFractionUsed(0.6), .yellow)
        XCTAssertEqual(StatusLevel.fromFractionUsed(0.9), .red)
        XCTAssertEqual(StatusLevel.fromFractionUsed(nil), .gray)
    }

    func testMenuBarTextAssembles() {
        let snap = UsageSnapshot(
            providerID: "codex", shortText: "4%", fullText: "周窗口剩余 4%",
            fractionUsed: 0.96, rawValue: "plan: plus", updatedAt: Date(), error: nil)
        XCTAssertEqual(snap.menuBarText, "C 4%")
    }

    func testErrorSnapshotShowsDash() {
        let snap = UsageSnapshot(
            providerID: "kiro", shortText: "--", fullText: "kiro 未登录",
            fractionUsed: nil, rawValue: "", updatedAt: Date(), error: "kiro 未登录")
        XCTAssertEqual(snap.status, .gray)
    }
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd <仓库路径> && swift test`
Expected: 编译失败（UsageSnapshot/StatusLevel 未定义）——这是预期失败

- [ ] **Step 3: 实现模型（替换 UsageSnapshot.swift 全文）**

```swift
import Foundation

enum StatusLevel {
    case green, yellow, red, gray

    /// 按已用比例映射状态色；nil（金额/信用类）由 Provider 自行指定
    static func fromFractionUsed(_ f: Double?) -> StatusLevel {
        guard let f else { return .gray }
        if f > 0.8 { return .red }
        if f > 0.5 { return .yellow }
        return .green
    }
}

struct UsageSnapshot {
    let providerID: String
    let shortText: String       // 菜单栏数字段，如 "4%"
    let fullText: String        // 下拉明细，如 "周窗口剩余 4%，5 小时后重置"
    let fractionUsed: Double?   // 0-1；nil = 无比例概念（金额/信用）
    let rawValue: String        // tooltip 原文，如 "¥88.5"
    let updatedAt: Date
    let error: String?          // 非 nil 表示获取失败
    let status: StatusLevel     // 颜色（Provider 内已算好；失败必为 .gray）

    init(providerID: String, shortText: String, fullText: String,
         fractionUsed: Double?, rawValue: String, updatedAt: Date = Date(),
         error: String? = nil, status: StatusLevel? = nil) {
        self.providerID = providerID
        self.shortText = shortText
        self.fullText = fullText
        self.fractionUsed = fractionUsed
        self.rawValue = rawValue
        self.updatedAt = updatedAt
        self.error = error
        if let status {
            self.status = status
        } else if let error {
            self.status = .gray
        } else {
            self.status = .fromFractionUsed(fractionUsed)
        }
    }

    /// 菜单栏前缀：codex → C、deepseek → D、kiro → K
    var prefix: String {
        switch providerID {
        case "codex": return "C"
        case "deepseek": return "D"
        case "kiro": return "K"
        default: return String(providerID.prefix(1)).uppercased()
        }
    }

    var menuBarText: String { "\(prefix) \(shortText)" }
}
```

- [ ] **Step 4: 实现协议（Sources/Core/UsageProvider.swift）**

```swift
import Foundation

protocol UsageProvider {
    var id: String { get }
    var displayName: String { get }
    func fetch() async throws -> UsageSnapshot
}
```

- [ ] **Step 5: 实现配置（Sources/Core/AppSettings.swift）**

```swift
import Foundation

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var enabledProviders: [String] {
        didSet { UserDefaults.standard.set(enabledProviders, forKey: "enabledProviders") }
    }
    @Published var deepseekApiKey: String {
        didSet { UserDefaults.standard.set(deepseekApiKey, forKey: "deepseekApiKey") }
    }
    @Published var refreshInterval: Int {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval") }
    }

    init() {
        let d = UserDefaults.standard
        enabledProviders = d.stringArray(forKey: "enabledProviders") ?? ["codex", "deepseek", "kiro"]
        deepseekApiKey = d.string(forKey: "deepseekApiKey") ?? ""
        let saved = d.integer(forKey: "refreshInterval")
        refreshInterval = saved >= 30 ? saved : 45
    }

    func isEnabled(_ id: String) -> Bool { enabledProviders.contains(id) }
}
```

- [ ] **Step 6: 运行测试验证通过**

Run: `cd <仓库路径> && swift test`
Expected: UsageSnapshotTests 3 个测试全部 PASS

- [ ] **Step 7: 提交**

```bash
cd <仓库路径> && git add Sources/Core/ Tests/ && git commit -m "feat: Core 模型（UsageSnapshot/StatusLevel/UsageProvider/AppSettings）"
```

---

## Task 3: CodexProvider（TDD：解析 + 网络）

**Files:**
- Create: `Sources/Providers/APIClient.swift`
- Create: `Sources/Providers/CodexProvider.swift`
- Create: `Tests/CodexProviderTests.swift`

- [ ] **Step 1: 写失败测试（Tests/CodexProviderTests.swift）**

```swift
import XCTest
@testable import token_show

final class CodexProviderTests: XCTestCase {
    /// 用录制的真实响应结构验证解析
    func testParseFullResponse() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 96, "limit_window_seconds": 604800,
                                "reset_after_seconds": 512273, "reset_at": 1786191472 },
            "secondary_window": null
          },
          "credits": { "has_credits": false, "balance": "0",
                       "overage_limit_reached": false },
          "rate_limit_reset_credits": { "available_count": 1 }
        }
        """
        let provider = CodexProvider(authProvider: { ("token", "acct") })
        let snap = try provider.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.shortText, "4%")
        XCTAssertEqual(snap.fractionUsed, 0.96)
        XCTAssertTrue(snap.fullText.contains("周窗口"))
        XCTAssertEqual(snap.status, .red)  // used 96% > 80%
    }

    func testParseWithSecondaryWindow() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 20, "limit_window_seconds": 604800,
                                "reset_after_seconds": 100, "reset_at": 1786191472 },
            "secondary_window": { "used_percent": 70, "limit_window_seconds": 18000,
                                  "reset_after_seconds": 200, "reset_at": 1786191472 }
          }
        }
        """
        let provider = CodexProvider(authProvider: { ("token", "acct") })
        let snap = try provider.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.shortText, "80%|30%")
        XCTAssertTrue(snap.fullText.contains("5 小时"))
    }

    func testAuthFileMissing() async {
        let provider = CodexProvider(authProvider: { throw CodexProvider.CodexError.notLoggedIn })
        do {
            _ = try await provider.fetch()
            XCTFail("应抛出 notLoggedIn")
        } catch CodexProvider.CodexError.notLoggedIn {
            // 预期
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd <仓库路径> && swift test --filter CodexProviderTests`
Expected: 编译失败（CodexProvider 不存在）

- [ ] **Step 3: 实现共享网络层（Sources/Providers/APIClient.swift）**

```swift
import Foundation

enum APIClient {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    /// GET 请求，返回原始 Data；非 2xx 抛 HTTPError
    static func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw HTTPError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode)
        }
        return data
    }
}

enum HTTPError: Error {
    case badResponse
    case status(Int)
}
```

- [ ] **Step 4: 实现 CodexProvider（Sources/Providers/CodexProvider.swift）**

```swift
import Foundation

struct CodexProvider: UsageProvider {
    var id: String { "codex" }
    var displayName: String { "Codex" }

    enum CodexError: Error {
        case notLoggedIn          // ~/.codex/auth.json 缺失或无法解析
        case invalidResponse
    }

    /// 注入式凭据读取，便于测试；默认读 ~/.codex/auth.json
    let authProvider: () throws -> (accessToken: String, accountID: String)

    init(authProvider: (() throws -> (accessToken: String, accountID: String))? = nil) {
        self.authProvider = authProvider ?? CodexProvider.defaultAuth
    }

    static func defaultAuth() throws -> (accessToken: String, accountID: String) {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let acct = tokens["account_id"] as? String,
              !access.isEmpty else {
            throw CodexError.notLoggedIn
        }
        return (access, acct)
    }

    func fetch() async throws -> UsageSnapshot {
        let auth = try authProvider()
        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "ChatGPT-Account-ID": auth.accountID,
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126.0",
        ]
        headers["oai-device-id"] = UUID().uuidString
        let url = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
        let data: Data
        do {
            data = try await APIClient.get(url, headers: headers)
        } catch HTTPError.status(401) {
            return UsageSnapshot(providerID: id, shortText: "--", fullText: "需重新登录 codex",
                                 fractionUsed: nil, rawValue: "", error: "需重新登录 codex")
        } catch HTTPError.status(403) {
            return UsageSnapshot(providerID: id, shortText: "--", fullText: "访问被拒绝（403），请检查登录态",
                                 fractionUsed: nil, rawValue: "", error: "403")
        }
        return try parse(data: data)
    }

    // MARK: - 解析（internal 供测试）

    func parse(data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let resp = try decoder.decode(CodexUsageResponse.self, from: data)

        let primary = resp.rateLimit.primaryWindow
        let used = Double(primary.usedPercent) / 100.0
        let remaining = 100 - primary.usedPercent

        var fullParts = ["周窗口剩余 \(remaining)%"]
        var short = "\(remaining)%"
        if let secondary = resp.rateLimit.secondaryWindow {
            let sRemain = 100 - secondary.usedPercent
            short = "\(100 - primary.usedPercent)%|\(sRemain)%"
            fullParts.append("5 小时窗口剩余 \(sRemain)%")
        }
        if resp.credits?.hasCredits == true, let bal = resp.credits?.balance, bal != "0" {
            fullParts.append("credits: \(bal)")
        }
        return UsageSnapshot(
            providerID: id,
            shortText: short,
            fullText: fullParts.joined(separator: "，"),
            fractionUsed: used,
            rawValue: "plan: \(resp.planType)"
        )
    }
}

// MARK: - 响应模型

struct CodexUsageResponse: Decodable {
    let planType: String
    let rateLimit: RateLimit
    let credits: Credits?

    struct RateLimit: Decodable {
        let allowed: Bool
        let limitReached: Bool
        let primaryWindow: Window
        let secondaryWindow: Window?

        struct Window: Decodable {
            let usedPercent: Int
            let limitWindowSeconds: Int
            let resetAfterSeconds: Int
            let resetAt: Int
        }
    }

    struct Credits: Decodable {
        let hasCredits: Bool
        let balance: String
    }
}
```

- [ ] **Step 5: 运行测试验证通过**

Run: `cd <仓库路径> && swift test --filter CodexProviderTests`
Expected: 3 个测试 PASS（注意 `testAuthFileMissing` 中 `fetch` 在 authProvider throw 后立即抛出，不触网）

- [ ] **Step 6: 构建验证（编译确认，不触网）**

Run: `cd <仓库路径> && swift build`
Expected: 编译成功（真实网络验证推迟到 Task 11 手动验证清单，避免 swift run 启动 GUI）

- [ ] **Step 7: 提交**

```bash
cd <仓库路径> && git add Sources/Providers/ Tests/ && git commit -m "feat: CodexProvider（chatgpt usage API 解析）"
```

---

## Task 4: DeepSeekProvider（TDD）

**Files:**
- Create: `Sources/Providers/DeepSeekProvider.swift`
- Create: `Tests/DeepSeekProviderTests.swift`

- [ ] **Step 1: 写失败测试（Tests/DeepSeekProviderTests.swift）**

```swift
import XCTest
@testable import token_show

final class DeepSeekProviderTests: XCTestCase {
    func testParseBalance() throws {
        let json = """
        { "is_available": true,
          "balance_infos": [ { "currency": "CNY", "total_balance": "88.50",
                              "granted_balance": "10.00", "topped_up_balance": "78.50" } ] }
        """
        let provider = DeepSeekProvider(apiKeyProvider: { "sk-test" })
        let snap = try provider.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.shortText, "¥88.5")
        XCTAssertEqual(snap.status, .green)       // ≥50
        XCTAssertTrue(snap.fullText.contains("88.5"))
        XCTAssertTrue(snap.fullText.contains("78.5"))
    }

    func testParseUSD() throws {
        let json = """
        { "is_available": true,
          "balance_infos": [ { "currency": "USD", "total_balance": "20.00",
                              "granted_balance": "0", "topped_up_balance": "20.00" } ] }
        """
        let provider = DeepSeekProvider(apiKeyProvider: { "sk-test" })
        let snap = try provider.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.shortText, "$20")
        XCTAssertEqual(snap.status, .yellow)      // 10-50
    }

    func testLowBalanceRed() throws {
        let json = """
        { "is_available": true,
          "balance_infos": [ { "currency": "CNY", "total_balance": "5.00",
                              "granted_balance": "0", "topped_up_balance": "5.00" } ] }
        """
        let provider = DeepSeekProvider(apiKeyProvider: { "sk-test" })
        let snap = try provider.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.status, .red)         // <10
    }

    func testMissingKey() async {
        let provider = DeepSeekProvider(apiKeyProvider: { nil })
        do {
            _ = try await provider.fetch()
            XCTFail("应抛出 missingKey")
        } catch DeepSeekProvider.DeepSeekError.missingKey {
            // 预期
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd <仓库路径> && swift test --filter DeepSeekProviderTests`
Expected: 编译失败（DeepSeekProvider 不存在）

- [ ] **Step 3: 实现 DeepSeekProvider（Sources/Providers/DeepSeekProvider.swift）**

```swift
import Foundation

struct DeepSeekProvider: UsageProvider {
    var id: String { "deepseek" }
    var displayName: String { "DeepSeek" }

    enum DeepSeekError: Error {
        case missingKey
        case invalidResponse
    }

    /// 注入式 key 读取：设置 > 环境变量；便于测试
    let apiKeyProvider: () -> String?

    init(apiKeyProvider: (() -> String?)? = nil) {
        self.apiKeyProvider = apiKeyProvider ?? {
            let fromSettings = AppSettings.shared.deepseekApiKey
            if !fromSettings.isEmpty { return fromSettings }
            return ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
        }
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
        let short = String(format: "%@%.1f", symbol, total)
        let full = String(format: "%@%.1f（充值 %@%.1f / 赠送 %@%.1f）",
                          symbol, total, symbol,
                          Double(info.toppedUpBalance) ?? 0,
                          symbol, Double(info.grantedBalance) ?? 0)
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
}

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
```

- [ ] **Step 4: 运行测试验证通过**

Run: `cd <仓库路径> && swift test --filter DeepSeekProviderTests`
Expected: 4 个测试 PASS

- [ ] **Step 5: 提交**

```bash
cd <仓库路径> && git add Sources/Providers/ Tests/ && git commit -m "feat: DeepSeekProvider（balance API 解析）"
```

---

## Task 5: kiro 逆向调查（探索任务，产出笔记）

**目标产出:** `docs/kiro-reverse-notes.md`，明确三要素：①查询信用额度的确切端点 ②认证方式（cookie？自定义 header？graphql？）③token 提取方法（leveldb JWT / keychain）。

**已知事实（设计阶段已确认）：**
- token 位于 `~/Library/Application Support/kiro/Local Storage/leveldb/*.ldb`（JWT，`strings` 可提取）
- keychain 有 `Kiro Safe Storage` / `Kiro Key`（Electron safeStorage）
- API host：`https://app.kiro.dev/api/v1`（REST）、`https://management.us-east-1.kiro.dev`（gRPC）
- `app.kiro.dev/api/v1/me` 对 Bearer token 返回 "Bearer token authentication is not supported for this operation"（认证方式不同）

- [ ] **Step 1: 静态分析 kiro 扩展代码**

```bash
EXT=/Applications/Kiro.app/Contents/Resources/app/extensions/kiro.kiro-agent
# 1) 列出扩展内所有 JS 产物
ls -la "$EXT/dist/"
# 2) 在所有 JS 中搜 API 路径与 host（含 app.kiro.dev、management、api/v1、graphql）
grep -rhoE '"/(api|v1|graphql|v2)[a-zA-Z0-9/_{}.-]*"' "$EXT/dist/" | sort -u | head -60
# 3) 搜 credit/balance/usage/quota/entitlement 关键词所在行（带上下文）
grep -rhoE '.{80}(credit|balance|entitlement|quota).{80}' "$EXT/dist/" | head -20
# 4) 搜认证 header 名（cookie、x-api-key、authorization、Bearer）
grep -rhoE '(cookie|Cookie|x-api-key|X-Api-Key|authorization|Authorization)[^,;]{0,60}' "$EXT/dist/" | sort -u | head -20
```

记录发现到 `docs/kiro-reverse-notes.md` 的"静态分析"小节。

- [ ] **Step 2: 动态抓包（运行 kiro 观察网络请求）**

```bash
# 启动 kiro（若未运行），然后在另一个终端用 mitmproxy/Charles 或系统代理抓包；
# 无代理工具时的替代方案：用 tcpdump 观察 TLS SNI + 在 kiro 打开"额度/账户"页面触发请求
open -a Kiro
# 观察 kiro 进程是否带 --remote-debugging-port；若有则可 attach DevTools 看 Network
ps aux | grep -i kiro | grep -v grep
```

在 kiro 界面中打开账户/额度页面（设置 → 账户/Billing/Usage），抓取查询信用值的请求，记录：
- 完整 URL（含 path）
- 认证 header（Cookie？自定义 header？值格式）
- 响应 JSON 结构（含信用值字段名）

记录到笔记的"动态分析"小节。若无法抓包（无代理工具），跳过本步并在笔记中注明，改用 Step 3 的探测法。

- [ ] **Step 3: 候选端点探测（用 leveldb 提取的 token）**

```bash
# 从 leveldb 提取 JWT
TOK=$(strings ~/Library/Application\ Support/kiro/Local\ Storage/leveldb/*.ldb | grep -oE 'eyJ[A-Za-z0-9_-]{60,}' | sort -u | head -1)
# 用不同认证方式探测候选端点（按 Step 1/2 的发现调整 header 与路径）
for p in "/api/v1/me" "/api/v1/credits" "/api/v1/account" "/api/v1/billing" "/api/v1/entitlements" "/api/v1/usage"; do
  echo "== $p =="
  curl -s --max-time 8 "https://app.kiro.dev$p" -H "Authorization: Bearer $TOK" -H "Cookie: $TOK" | head -c 200
  echo
done
```

- [ ] **Step 4: 整理笔记并提交**

写 `docs/kiro-reverse-notes.md`（结构固定）：

```markdown
# kiro 逆向笔记

日期：2026-08-02

## 结论摘要
- 端点：<确认的 URL>
- 认证：<Bearer/cookie/自定义 header，含取值方法>
- token 来源：<leveldb JWT / keychain，含提取命令>
- 响应中信用值字段：<字段路径，如 data.credits.balance>
- 状态：<已确认 / 未确认，未确认则列出待办>

## 静态分析发现
（Step 1 输出摘录）

## 动态分析发现
（Step 2 输出摘录，或"未执行抓包"）

## 候选端点探测记录
（Step 3 结果）
```

```bash
cd <仓库路径> && git add docs/kiro-reverse-notes.md && git commit -m "docs: kiro 逆向笔记"
```

**完成标准**：`docs/kiro-reverse-notes.md` 已提交，且"结论摘要"中端点与认证至少有一项已确认；若全部探测失败，笔记中注明"未确认"，Task 6 走兜底占位。

---

## Task 6: KiroProvider（依据逆向笔记实现；失败则占位）

**Files:**
- Create: `Sources/Providers/KiroProvider.swift`
- Create: `Tests/KiroProviderTests.swift`

- [ ] **Step 1: 读逆向笔记**

Run: `cat docs/kiro-reverse-notes.md`
按笔记"结论摘要"决定实现方式。以下给出两种路径的完整代码；**若笔记确认了端点与认证 → 路径 A；否则 → 路径 B（占位）**。

- [ ] **Step 2A: 路径 A（逆向成功）—— 写失败测试**

```swift
import XCTest
@testable import token_show

final class KiroProviderTests: XCTestCase {
    /// 依据笔记中的响应结构编写；字段名以下面示例为准，若笔记不同则同步修改
    func testParseCredits() throws {
        let json = """
        { "data": { "credits": { "balance": 3200, "currency": "USD" } } }
        """
        let provider = KiroProvider(tokenProvider: { "jwt-token" })
        let snap = try provider.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.shortText, "3200cr")
        XCTAssertEqual(snap.status, .green)
    }

    func testNoToken() async {
        let provider = KiroProvider(tokenProvider: { nil })
        do {
            _ = try await provider.fetch()
            XCTFail("应抛出 notLoggedIn")
        } catch KiroProvider.KiroError.notLoggedIn {
            // 预期
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }
}
```

（若笔记确认的响应结构字段名不同，按笔记修改上面 JSON 与断言。）

- [ ] **Step 3A: 实现 KiroProvider（路径 A）**

```swift
import Foundation

struct KiroProvider: UsageProvider {
    var id: String { "kiro" }
    var displayName: String { "Kiro" }

    enum KiroError: Error {
        case notLoggedIn
        case invalidResponse
    }

    /// 注入式 token 读取；默认从 leveldb 提取 JWT
    let tokenProvider: () -> String?

    init(tokenProvider: (() -> String?)? = nil) {
        self.tokenProvider = tokenProvider ?? KiroProvider.defaultToken
    }

    static func defaultToken() -> String? {
        // 从 kiro Local Storage leveldb 提取第一个 JWT
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kiro/Local Storage/leveldb")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        for f in files where f.pathExtension == "ldb" || f.pathExtension == "log" {
            if let s = try? String(contentsOf: f, encoding: .utf8) {
                if let m = s.range(of: #"eyJ[A-Za-z0-9_-]{60,}"#, options: .regularExpression) {
                    return String(s[m])
                }
            }
        }
        return nil
    }

    func fetch() async throws -> UsageSnapshot {
        guard let token = tokenProvider() else {
            throw KiroError.notLoggedIn
        }
        // ⚠️ 以下端点与 header 依据 docs/kiro-reverse-notes.md 的结论填写
        let endpoint = URL(string: "https://app.kiro.dev/api/v1/credits")!
        let data: Data
        do {
            data = try await APIClient.get(endpoint, headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
            ])
        } catch HTTPError.status(401) {
            return UsageSnapshot(providerID: id, shortText: "--", fullText: "kiro 未登录",
                                 fractionUsed: nil, rawValue: "", error: "kiro 未登录")
        }
        return try parse(data: data)
    }

    // MARK: - 解析（internal 供测试；结构按笔记调整）

    func parse(data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let resp = try decoder.decode(KiroCreditsResponse.self, from: data)
        let balance = resp.data.credits.balance
        let short = "\(balance)cr"
        let status: StatusLevel = balance >= 1000 ? .green : (balance >= 300 ? .yellow : .red)
        return UsageSnapshot(
            providerID: id, shortText: short,
            fullText: "剩余信用值 \(balance)",
            fractionUsed: nil, rawValue: short, status: status)
    }
}

struct KiroCreditsResponse: Decodable {
    let data: Data

    struct Data: Decodable {
        let credits: Credits
    }
    struct Credits: Decodable {
        let balance: Int
        let currency: String?
    }
}
```

（若笔记字段名不同，同步调整 `KiroCreditsResponse` 与 `parse`。）

- [ ] **Step 2B: 路径 B（逆向失败）—— 占位实现（不写测试，手动验证）**

```swift
import Foundation

struct KiroProvider: UsageProvider {
    var id: String { "kiro" }
    var displayName: String { "Kiro" }

    enum KiroError: Error { case notLoggedIn, invalidResponse }

    let tokenProvider: () -> String?

    init(tokenProvider: (() -> String?)? = nil) {
        self.tokenProvider = tokenProvider ?? { nil }
    }

    func fetch() async throws -> UsageSnapshot {
        return UsageSnapshot(
            providerID: id, shortText: "--", fullText: "kiro 数据源未接通（逆向未完成）",
            fractionUsed: nil, rawValue: "", error: "kiro 数据源未接通")
    }

    func parse(data: Data) throws -> UsageSnapshot {
        throw KiroError.invalidResponse
    }
}
```

- [ ] **Step 4: 运行测试验证通过**

Run（路径 A）: `cd <仓库路径> && swift test --filter KiroProviderTests`
Expected: 2 个测试 PASS
Run（路径 B）: `swift build` 通过即可（无测试）

- [ ] **Step 5: 提交**

```bash
cd <仓库路径> && git add Sources/Providers/ Tests/ && git commit -m "feat: KiroProvider（依据逆向笔记实现）"
```
（路径 B 时 commit message 改为 "feat: KiroProvider 占位实现（逆向未完成）"）

---

## Task 7: 状态仓库 RefreshStore（@MainActor ObservableObject）

**Files:**
- Create: `Sources/Core/RefreshStore.swift`

- [ ] **Step 1: 实现 RefreshStore**

```swift
import Foundation

/// 持有各工具最新快照，驱动菜单栏 UI 更新
@MainActor
final class RefreshStore: ObservableObject {
    @Published private(set) var snapshots: [String: UsageSnapshot] = [:]

    func update(_ snap: UsageSnapshot) {
        snapshots[snap.providerID] = snap
    }

    func updateError(id: String, error: String) {
        snapshots[id] = UsageSnapshot(
            providerID: id, shortText: "--", fullText: error,
            fractionUsed: nil, rawValue: "", updatedAt: Date(), error: error)
    }

    /// 按启用顺序返回快照（codex → deepseek → kiro）
    var orderedSnapshots: [UsageSnapshot] {
        let order = ["codex", "deepseek", "kiro"]
        return order.compactMap { snapshots[$0] }
    }

    func snapshot(for id: String) -> UsageSnapshot? { snapshots[id] }
}
```

- [ ] **Step 2: 构建验证**

Run: `cd <仓库路径> && swift build`
Expected: 成功

- [ ] **Step 3: 提交**

```bash
cd <仓库路径> && git add Sources/Core/RefreshStore.swift && git commit -m "feat: RefreshStore（快照仓库）"
```

---

## Task 8: RefreshScheduler（轮询 + 失败退避）

**Files:**
- Create: `Sources/Core/RefreshScheduler.swift`
- Create: `Tests/RefreshSchedulerTests.swift`（仅测试退避状态机，不测 Timer）

- [ ] **Step 1: 写失败测试（Tests/RefreshSchedulerTests.swift）**

```swift
import XCTest
@testable import token_show

final class RefreshSchedulerTests: XCTestCase {
    func testBackoffStateMachine() {
        var s = BackoffTracker(threshold: 3, backoffInterval: 300)
        XCTAssertEqual(s.currentInterval(base: 45), 45)
        s.recordFailure(); XCTAssertEqual(s.currentInterval(base: 45), 45) // 1 次失败不退避
        s.recordFailure(); XCTAssertEqual(s.currentInterval(base: 45), 45) // 2 次
        s.recordFailure(); XCTAssertEqual(s.currentInterval(base: 45), 300) // 3 次 → 退避
        s.recordSuccess()
        XCTAssertEqual(s.currentInterval(base: 45), 45) // 恢复
    }
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd <仓库路径> && swift test --filter RefreshSchedulerTests`
Expected: 编译失败（BackoffTracker 不存在）

- [ ] **Step 3: 实现 RefreshScheduler（Sources/Core/RefreshScheduler.swift）**

```swift
import Foundation

/// 单工具失败退避状态机
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

/// 主 actor 定时调度：按 AppSettings.refreshInterval 轮询启用的 Provider
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
            Task { @MainActor in self?.refreshAll() }
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
```

- [ ] **Step 4: 运行测试验证通过**

Run: `cd <仓库路径> && swift test --filter RefreshSchedulerTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
cd <仓库路径> && git add Sources/Core/ Tests/ && git commit -m "feat: RefreshScheduler（定时轮询 + 失败退避）"
```

---

## Task 9: 菜单栏 UI（StatusBarController + AppDelegate）

**Files:**
- Create: `Sources/App/StatusBarController.swift`
- Create: `Sources/App/AppDelegate.swift`
- Modify: `Sources/App/AppMain.swift`（接入 AppDelegate）

- [ ] **Step 1: 实现 StatusBarController（Sources/App/StatusBarController.swift）**

```swift
import AppKit
import SwiftUI

/// 维护 NSStatusItem：数字标题 + 彩色圆点 + tooltip + 下拉菜单
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let store: RefreshStore
    private let onRefresh: () async -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

    init(store: RefreshStore,
         onRefresh: @escaping () async -> Void,
         onOpenSettings: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.store = store
        self.onRefresh = onRefresh
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        update()
    }

    @objc private func statusClicked(_ sender: Any?) {
        // 点击：先刷新再弹菜单
        Task { @MainActor in
            await onRefresh()
            self.showMenu()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        for snap in store.orderedSnapshots {
            let item = NSMenuItem(title: "\(snap.fullText)", action: nil, keyEquivalent: "")
            if let err = snap.error {
                item.attributedTitle = NSAttributedString(
                    string: "⚠️ \(snap.displayTitle) — \(err)",
                    attributes: [.foregroundColor: NSColor.systemRed])
            } else {
                item.attributedTitle = NSAttributedString(
                    string: "\(snap.displayTitle) — \(snap.fullText)",
                    attributes: [.foregroundColor: color(for: snap.status)])
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refreshNow(_:)), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp(_:)), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        // 标准弹出方式：popUpMenu 直接弹出，无需挂到 statusItem.menu
        statusItem.popUpMenu(menu)
    }

    @objc private func refreshNow(_ sender: Any?) {
        Task { @MainActor in await onRefresh() }
    }

    @objc private func openSettings(_ sender: Any?) { onOpenSettings() }
    @objc private func quitApp(_ sender: Any?) { onQuit() }

    /// 将最新快照渲染到 status item
    func update() {
        guard let button = statusItem.button else { return }
        let snaps = store.orderedSnapshots
        let title = snaps.map(\.menuBarText).joined(separator: "  ")
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
        // 圆点图像：最紧张工具的状态色
        let worst = snaps.min { colorRank($0.status) < colorRank($1.status) }
        button.image = dotImage(color: color(for: worst?.status ?? .gray))
        button.toolTip = snaps.map { "\($0.displayTitle): \($0.rawValue)" }
            .joined(separator: "\n")
    }

    private func colorRank(_ s: StatusLevel) -> Int {
        switch s { case .green: return 0; case .yellow: return 1; case .red: return 2; case .gray: return 3 }
    }

    private func color(for s: StatusLevel) -> NSColor {
        switch s {
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .red: return .systemRed
        case .gray: return .systemGray
        }
    }

    private func dotImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        img.unlockFocus()
        return img
    }
}

extension UsageSnapshot {
    var displayTitle: String {
        switch providerID {
        case "codex": return "Codex"
        case "deepseek": return "DeepSeek"
        case "kiro": return "Kiro"
        default: return providerID
        }
    }
}
```

- [ ] **Step 2: 实现 AppDelegate（Sources/App/AppDelegate.swift）**

```swift
import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: RefreshStore!
    private var scheduler: RefreshScheduler!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // 无 Dock 图标

        let store = RefreshStore()
        self.store = store

        let providers: [any UsageProvider] = [CodexProvider(), DeepSeekProvider(), KiroProvider()]
        let scheduler = RefreshScheduler(store: store, providers: providers)
        self.scheduler = scheduler

        let statusBar = StatusBarController(
            store: store,
            onRefresh: { [weak self] in await self?.scheduler.refreshNow() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) })
        self.statusBar = statusBar

        // 快照变化 → 重绘 status item
        store.$snapshots
            .sink { [weak self] _ in self?.statusBar.update() }
            .store(in: &cancellables)

        scheduler.start()
    }

    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
            let hosting = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: hosting)
            win.title = "token_show 设置"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 360, height: 260))
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 3: 接入 AppMain.swift（替换全文）**

```swift
import SwiftUI

@main
struct TokenShowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
```

- [ ] **Step 4: 构建验证**

Run: `cd <仓库路径> && swift build`
Expected: 成功。若有 Combine 缺失 → AppDelegate.swift 顶部补 `import Combine`。

- [ ] **Step 5: 提交**

```bash
cd <仓库路径> && git add Sources/App/ && git commit -m "feat: 菜单栏 UI（StatusBarController + AppDelegate）"
```

---

## Task 10: 设置窗口 SettingsView

**Files:**
- Create: `Sources/App/SettingsView.swift`

- [ ] **Step 1: 实现 SettingsView**

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var refreshOnChange = false

    var body: some View {
        Form {
            Section("显示的工具") {
                Toggle("Codex（订阅额度）", isOn: bindingFor("codex"))
                Toggle("DeepSeek（余额）", isOn: bindingFor("deepseek"))
                Toggle("Kiro（信用值）", isOn: bindingFor("kiro"))
            }
            Section("DeepSeek API Key") {
                TextField("留空则读取环境变量 DEEPSEEK_API_KEY", text: $settings.deepseekApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            Section("刷新间隔") {
                Picker("", selection: $settings.refreshInterval) {
                    Text("30 秒").tag(30)
                    Text("45 秒").tag(45)
                    Text("60 秒").tag(60)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 260)
        .padding()
    }

    private func bindingFor(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.enabledProviders.contains(id) },
            set: { on in
                var list = settings.enabledProviders
                if on { if !list.contains(id) { list.append(id) } }
                else { list.removeAll { $0 == id } }
                settings.enabledProviders = list
            }
        )
    }
}
```

- [ ] **Step 2: 构建验证**

Run: `cd <仓库路径> && swift build`
Expected: 成功

- [ ] **Step 3: 提交**

```bash
cd <仓库路径> && git add Sources/App/SettingsView.swift && git commit -m "feat: 设置窗口（工具开关 / API key / 刷新间隔）"
```

---

## Task 11: 集成手动验证 + README

**Files:**
- Create: `README.md`
- Modify: 可能的小修（按验证结果）

- [ ] **Step 1: 写 README**

```markdown
# token_show

macOS 菜单栏工具：实时显示 codex / deepseek / kiro 的 token 额度与剩余量。

## 构建与运行

```bash
swift build
swift run token_show
```

运行后菜单栏出现彩色圆点 + 数字（如 `● C 4% ¥88.5 3200cr`），点击刷新，右键/左键弹出菜单：明细、立即刷新、设置、退出。

## 数据源

| 工具 | 数据源 | 说明 |
|---|---|---|
| codex | `~/.codex/auth.json` → chatgpt.com/backend-api/codex/usage | 订阅制：周窗口/5小时窗口剩余 |
| deepseek | `DEEPSEEK_API_KEY`（或设置中填写）→ api.deepseek.com/user/balance | 充值制：剩余金额 |
| kiro | 见 `docs/kiro-reverse-notes.md` | 信用制：剩余信用值 |

## 配置

设置窗口可开关各工具、填写 deepseek API key、选择刷新间隔（30/45/60s）。配置存 UserDefaults。

## 已知限制

- codex usage 端点为非公开接口，若失效请更新 `CodexProvider.swift` 中的 URL。
- kiro 数据源依赖逆向笔记中的端点（若未接通，菜单栏显示 `K --`）。
```

- [ ] **Step 2: 手动验证清单（逐项执行）**

```bash
# 1) 构建 + 启动
swift build && swift run token_show &
# 2) 观察菜单栏：应显示彩色圆点 + "C xx% ¥xx K xxcr"（kiro 可能为 --）
# 3) 点击菜单栏图标：应刷新并弹出下拉菜单，含三工具明细与"立即刷新/设置/退出"
# 4) 打开设置：勾选/取消 DeepSeek，菜单栏数字应随之消失/出现
# 5) 设置里填错误 deepseek key：菜单栏 DeepSeek 显示灰色 --，下拉显示 "API key 无效"
# 6) 断网：所有工具显示灰色 --，tooltip 显示网络错误；恢复网络后点击刷新恢复
# 7) 修改刷新间隔为 30s，观察轮询频率变化
# 8) 退出菜单"退出"：进程结束
```

若验证发现问题，就地修复并重新构建。

- [ ] **Step 3: 最终提交**

```bash
cd <仓库路径> && git add README.md && git commit -m "docs: README（构建/运行/数据源/配置说明）"
```

---

## 完成标准

- [ ] `swift build` 与 `swift test` 全部通过
- [ ] 菜单栏显示三工具实时数字（kiro 逆向成功时；否则占位 `--` 且 README 说明）
- [ ] 设置窗口可开关工具、配置 key、改刷新间隔
- [ ] 单工具失败不影响其他显示；连续失败自动退避
- [ ] 全部任务已提交，git log 清晰
