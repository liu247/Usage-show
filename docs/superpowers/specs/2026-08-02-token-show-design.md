# token_show 设计文档

> 日期：2026-08-02 · 状态：已确认 · 技术栈：Swift + SwiftUI（macOS 原生）

## 1. 背景与目标

macOS 菜单栏常驻小工具，实时显示多个 AI 编码工具的 token 额度与剩余量，防止额度耗尽而无感知。界面尽可能简洁。

**首批支持的工具（按各自的计费模式显示）：**

| 工具 | 计费模式 | 显示内容 |
|---|---|---|
| codex（ChatGPT 订阅） | 订阅制 | 周窗口剩余百分比、5小时窗口（若存在）、credits 余额 |
| deepseek | 充值制 | 剩余金额（total_balance，含币种） |
| kiro | 信用制 | 剩余信用值（credit） |

**明确不做**：claude code（用户配置走本地代理，一期不纳入）。

## 2. 需求要点（来自用户确认）

- **平台**：macOS 菜单栏原生 App（Swift + SwiftUI），无 Dock 图标（`LSUIElement`）
- **显示形态**：菜单栏直接显示多个工具的实时数字，每个工具可单独开关（设置中勾选）
- **显示格式**：图标 + 数字 + 颜色三重结合
- **刷新**：30~60 秒定时轮询 + 点击菜单栏即刷新 + 下拉菜单"立即刷新"
- **数据源**：混合策略——官方 API 优先，本地登录态解析兜底
- **简洁**：菜单栏只放必要数字，明细放下拉菜单/tooltip

## 3. 架构

Swift Package 可执行文件（`swift build` 产出单二进制，无外部依赖）。

```
token_show/
├── Package.swift
├── Sources/
│   ├── App/                        # 菜单栏 UI + 生命周期
│   │   ├── AppMain.swift           # @main 入口
│   │   ├── StatusBarController.swift  # NSStatusItem
│   │   ├── MenuBuilder.swift       # 下拉菜单
│   │   └── SettingsView.swift      # 设置窗口（勾选显示哪些工具）
│   ├── Core/                       # 公共协议与模型
│   │   ├── UsageProvider.swift     # protocol: fetch() -> UsageSnapshot
│   │   ├── UsageSnapshot.swift     # 工具名/显示文本/比例/颜色/详情/错误
│   │   └── RefreshScheduler.swift  # 定时轮询调度
│   └── Providers/                  # 各工具独立实现（可插拔）
│       ├── CodexProvider.swift
│       ├── DeepSeekProvider.swift
│       └── KiroProvider.swift
└── Tests/
```

### 核心接口

```swift
protocol UsageProvider {
    var id: String { get }            // "codex" / "deepseek" / "kiro"
    var displayName: String { get }   // "Codex" / "DeepSeek" / "Kiro"
    func fetch() async throws -> UsageSnapshot
}

struct UsageSnapshot {
    let providerID: String
    let shortText: String   // 菜单栏数字，如 "61%"
    let fullText: String    // 下拉明细，如 "周窗口已用 96%，5 小时后重置"
    let fractionUsed: Double? // 0-1，用于颜色；nil 表示无比例概念（如金额/信用）
    let rawValue: String    // tooltip 原文，如 "¥88.5"
    let updatedAt: Date
    let error: String?      // 非 nil 表示本工具获取失败
}
```

**状态色规则**（UI 统一按 `fractionUsed` 或工具自定义阈值）：
- 绿：健康（codex used<50% / deepseek 余额≥50 / kiro 信用充足）
- 黄：警告（codex 50-80% / deepseek 余额 10-50 / kiro 较低）
- 红：危险（codex >80% / deepseek 余额<10 / kiro 很低）
- 灰：未配置 / 获取失败（显示 `--`，tooltip 显示原因）

## 4. 数据获取（各 Provider）

### 4.1 CodexProvider（已验证可行）

1. 读 `~/.codex/auth.json` → `tokens.access_token`、`tokens.account_id`
2. `GET https://chatgpt.com/backend-api/codex/usage`
   - Header：`Authorization: Bearer <access_token>`
   - Header：`ChatGPT-Account-ID: <account_id>`
   - Header：`oai-device-id: <随机 UUID>`（每次请求生成即可）
   - Header：`Content-Type: application/json`、浏览器 UA
3. 解析响应（实测样例）：
   ```json
   {
     "plan_type": "plus",
     "rate_limit": {
       "allowed": true, "limit_reached": false,
       "primary_window": { "used_percent": 96, "limit_window_seconds": 604800,
                           "reset_after_seconds": 512273, "reset_at": 1786191472 },
       "secondary_window": null
     },
     "credits": { "has_credits": false, "balance": "0", ... },
     "rate_limit_reset_credits": { "available_count": 1, ... }
   }
   ```
4. 显示：
   - 菜单栏：`C <100-used_percent>%`（如 `C 4%` = 剩余比例）；若 `secondary_window` 存在，可显示 `C 4%|22%`
   - 明细：周窗口剩余百分比、5小时窗口剩余（若存在）、credits balance（若 has_credits）、reset 时间
   - 颜色：按 primary_window 的 used_percent
5. 错误：401 → "需重新登录 codex"；网络错误 → "网络不可用"

### 4.2 DeepSeekProvider（已验证可行）

1. API key 来源：设置中手动填入（优先）→ 环境变量 `DEEPSEEK_API_KEY`（兜底）
2. `GET https://api.deepseek.com/user/balance`，Header：`Authorization: Bearer <key>`
3. 解析：
   ```json
   { "is_available": true,
     "balance_infos": [ { "currency": "CNY", "total_balance": "110.00",
                          "granted_balance": "10.00", "topped_up_balance": "100.00" } ] }
   ```
4. 显示：菜单栏 `¥88.5`（币种符号按 currency 映射，CNY→¥、USD→$）；明细显示 total/granted/topped_up 拆分
5. 颜色：total_balance ≥50 绿 / 10-50 黄 / <10 红
6. 错误：无 key → "未配置 API key"；401 → "API key 无效"

### 4.3 KiroProvider（一期完成，逆向先行）

**已定位的事实**（调研阶段确认）：
- 登录态：`~/Library/Application Support/kiro/Local Storage/leveldb/*.ldb` 含 JWT tokens；keychain 有 `Kiro Safe Storage` / `Kiro Key`（Electron safeStorage）
- API host：`https://app.kiro.dev/api/v1`（REST）+ `https://management.us-east-1.kiro.dev`（gRPC control plane，host 含 `kirocontrolplanebearerservice`）
- 用户账号：email <email>、account_id `<account_id>`、auth_method chatgpt（来自 statsig 事件）
- `app.kiro.dev/api/v1/me` 对 Bearer token 返回 "Bearer token authentication is not supported for this operation" → 需要 cookie 或自定义 header，认证方式待逆向

**实现步骤（实现阶段第一个任务）**：
1. 运行 kiro，用代理/抓包（或注入观察其扩展的 fetch/XHR）确定查询信用额度的实际端点和认证方式（cookie？自定义 header？graphql？）
2. 逆向 `kiro.kiro-agent` 扩展（`/Applications/Kiro.app/Contents/Resources/app/extensions/kiro.kiro-agent/dist`）与主 bundle（`workbench.desktop.main.js`）确认端点
3. 实现 KiroProvider：读 Local Storage leveldb（解析 JWT token）→ 调确认的端点 → 解析信用值
4. 显示：菜单栏 `3200cr`；明细显示信用值与到期信息（若有）

**失败兜底**：若逆向确实不可行（端点强校验签名等），退回"接口预留 + 占位显示 `--`"，并在交付说明中明确告知。此兜底仅在尽力逆向后使用。

## 5. 菜单栏 UI

```
🧪 C 4%  ¥88.5  3200cr
```

- `NSStatusItem`（`.variableLength`），`button.title` 为数字段，`button.image` 为彩色圆点（绿/黄/红/灰），`button.toolTip` 为各工具明细
- 点击图标：立即刷新一轮再展示
- 下拉菜单（NSMenu）：
  - 每工具一项：`Codex — 周剩余 4%（5小时后重置）`，失败项红色 `⚠️ 原因`
  - `立即刷新`（禁用态：刷新中）
  - `设置…` → SwiftUI Settings 窗口：三工具勾选开关、deepseek API key 输入（留空读环境变量）、刷新间隔（30/45/60s）
  - `退出`
- 常驻状态栏，无 Dock 图标：Info.plist `LSUIElement = YES`

## 6. 配置

UserDefaults：

| 键 | 类型 | 默认 |
|---|---|---|
| `enabledProviders` | [String] | ["codex","deepseek","kiro"] |
| `deepseekApiKey` | String | ""（读环境变量兜底） |
| `refreshInterval` | Int | 45 |

## 7. 错误处理

- 每个 Provider 独立 try/catch，失败不影响其他工具显示
- 失败显示灰色 `--` + tooltip 原因 + 下拉菜单红色警告
- 连续失败 3 次 → 该工具退避到 5 分钟轮询；恢复成功后回到正常间隔
- 所有网络请求带超时（10s）

## 8. 测试

- 单元测试（`swift test`）：三 Provider 的响应解析，用录制样例 JSON（正常/缺失字段/异常），不依赖网络
- 手动验证清单：首次启动、开关各工具、断网、token 过期、kiro 未登录、refresh 间隔切换

## 9. 交付物

- Swift Package 源码（`swift build` / `swift run` 可构建运行）
- README：构建/运行说明、各工具数据源说明、kiro 逆向记录
- kiro 逆向作为实现第一阶段（见 4.3）

## 10. 风险与对策

| 风险 | 对策 |
|---|---|
| kiro API 逆向失败 | 兜底：接口预留 + 占位显示，交付说明中告知 |
| codex usage API 端点变动 | 抓包日志 + README 说明如何更新端点 |
| 频繁轮询触发风控 | 30-60s 默认间隔 + 失败退避 + 点击刷新为主 |
| 菜单栏文字过长 | 每工具固定前缀短文本（C/D/K），明细放 tooltip/下拉 |
