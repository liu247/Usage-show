# kiro 逆向笔记

日期：2026-08-02

## 结论摘要

- 端点：**`GET https://management.us-east-1.kiro.dev/getUsageLimits?profileArn=<profileArn>`**（已确认，返回 200；服务 `com.amazon.kiro.controlplane`，Coral JSON 协议，另有 gRPC 变体 `GetUsageLimits`）
- 认证：**`Authorization: Bearer <accessToken>`**（已确认；扩展内 `@smithy/core` bearer 签名器将 token 写入该 header；`app.kiro.dev/api/v1/*` 为 Web 端 cookie 认证，不适合脚本调用）
- token 来源：**`~/.aws/sso/cache/kiro-auth-token.json` 的 `accessToken`**（已确认；同文件含 `refreshToken`/`expiresAt`）；profileArn 在 **`~/Library/Application Support/kiro/User/globalStorage/kiro.kiroagent/profile.json` 的 `arn`**（已确认）
- 响应中信用值字段：**`usageBreakdownList[].freeTrialInfo.{currentUsage, usageLimit, freeTrialStatus, freeTrialExpiry}`**（免费试用额度）与 **`usageBreakdownList[].{currentUsage, usageLimit, currentOverages, overageCap, overageRate}`**（订阅额度），`resourceType: "CREDIT"`、`displayName: "Credit"`；`subscriptionInfo.subscriptionTitle`（如 `"KIRO FREE"`）；`nextDateReset`（epoch 秒）（已确认）
- 状态：**已确认**。三要素（端点 / 认证 / token 提取）全部实证成功；待办：验证 token 刷新流程、多 profile/多 region 分支

## 静态分析发现

对象：`/Applications/Kiro.app/Contents/Resources/app/extensions/kiro.kiro-agent/dist/extension.js`（22 MB 单文件 bundle，version 1.0.369）。

- **Host 清单**（bundle 中字面量）：
  - `https://app.kiro.dev` —— Web 登录门户（`All authentication now goes through app.kiro.dev/signin`），另有 `/settings/account#upgrade`
  - `https://management.{region}.kiro.dev`（us-east-1 / eu-central-1 / us-gov-west-1）—— control plane（gRPC/Coral）
  - `https://runtime.{region}.kiro.dev` —— 运行时（infra-safety）
  - `https://prod.us-east-1.auth.desktop.kiro.dev` —— 认证配置默认端点
  - `https://prod.us-east-1.telemetry.desktop.kiro.dev`、`https://gamma.us-east-1.telemetry.desktop.kiro.dev` —— 遥测
  - `kirocontrolplanebearerservice.{Region}.amazonaws.com` —— AWS SDK SigV4/bearer 签名名（`defaultSigningName: "kirocontrolplanebearerservice"`）
- **控制面操作**（bundle 内 proto / smithy 定义）：
  - `GetProfile`、`GetUsageLimits`、`ListAvailableModels`、`GetFeatureConfiguration` 等
  - HTTP 路由：`GetUsageLimits$ = ["GET", "/getUsageLimits", 200]`（REST gateway）
  - 服务包名：`com.amazon.kiro.controlplane`
- **GetUsageLimitsRequest 字段**：`profileArn`、`origin`、`resourceType`、`isEmailRequired`
- **GetUsageLimitsResponse 字段**（proto 反序列化定义确认）：
  - `limits`、`nextDateReset`、`daysUntilReset`
  - `usageBreakdown` / `usageBreakdownList[]`
  - `subscriptionInfo`（`subscriptionTitle`/`type`/`upgradeCapability`/`overageCapability`/`subscriptionManagementTarget`）
  - `overageConfiguration`（`overageStatus`/`overageLimit`）
  - `userInfo`、`totalUsage`
  - `UsageBreakdown`：`currentUsage`、`usageLimit`、`usageLimitWithPrecision`、`currentOverages`、`overageCharges`、`overageCap`、`overageCapWithPrecision`、`overageRate`、`overageCredits[]`（每项含 `currentUsage`/`usageLimit`/`expiresAt`）、`freeTrialInfo`、`currency`、`unit`、`nextDateReset`
- **认证 / token 链路**：
  - 客户端构造：`new Di2({ region, endpoint: "https://management.<region>.kiro.dev", token: await authProvider.getToken(), ... })`
  - bearer 签名：`clonedRequest.headers["Authorization"] = \`Bearer ${identity.token}\``（`@smithy/core`）
  - `authProvider.getToken()` → `TokenStorage` → `path.join(os.homedir(), ".aws", "sso", "cache")` + `kiro-auth-token.json`
  - token 文件字段：`accessToken`、`refreshToken`、`expiresAt`、`clientIdHash`、`authMethod`（如 `"IdC"`）、`provider`（如 `"BuilderId"`）、`region`
  - 刷新：SSO OIDC 风格 `grant_type=refresh_token`（client 注册在 `~/.aws/sso/cache/<clientIdHash>.json`，含 `clientId`/`clientSecret`/`scopes`）
  - `getProfileArn()` → `ProfileStorage` → VS Code `globalStorageUri/profile.json` → `arn`
  - 登录 providers：`SOCIAL_PROVIDERS = ["Google","Github"]`、`IDC_PROVIDERS = ["Enterprise","BuilderId","Internal"]`
  - 命令分类前缀：`kiro.auth`、`kiro.billing`、`kiro.usageLimits`（`kiro.usageLimits.getUsageLimits` 命令存在）
- **扩展 bundle 中未发现**：`safeStorage`、`Kiro Safe Storage`、`KiroKey`（keychain 词条 0 命中）—— 这些属于 Electron 主进程 / Web 登录会话，不在 VS Code 扩展 host 内；`credit`/`balance` 英文词 0 命中（字段名实际是 `usageLimit`/`currentUsage`/`freeTrialInfo`/`overage*`）

## 动态分析发现

未执行抓包：kiro 未运行，且本机无 mitmproxy/charles（`which mitmproxy mitmdump charles` 为空），sudo tcpdump 不可用。
采用替代方案：直接用从 token 文件读取的凭证对候选端点做 curl 探测（见下），效果等同动态验证。

## 候选端点探测记录

token 来源：`~/.aws/sso/cache/kiro-auth-token.json`（accessToken，232 字符，非 JWT）；profileArn 来源：`globalStorage/kiro.kiroagent/profile.json`（`arn: arn:aws:codewhisperer:*`）。

| 端点 | 认证 | 结果 |
|---|---|---|
| `https://management.us-east-1.kiro.dev/getUsageLimits`（无参数） | Bearer | **400** `{"message":"Invalid profileArn."}` — 端点有效、认证通过（`x-amzn-errortype: ValidationException`），缺参数 |
| `https://management.us-east-1.kiro.dev/GetUsageLimits` | Bearer | **400** 同上（大小写均可） |
| `https://management.us-east-1.kiro.dev/getProfile` | Bearer | 404 UnknownOperationException（非公开 REST 方法） |
| `https://management.us-east-1.kiro.dev/getUsageLimits?profileArn=<arn>` | Bearer | **200** 完整额度 JSON |

实测 200 响应关键字段（值已打码）：

```json
{
  "nextDateReset": <epoch_sec>,
  "overageConfiguration": { "overageStatus": "DISABLED" },
  "subscriptionInfo": {
    "subscriptionTitle": "KIRO FREE",
    "type": "Q_DEVELO...FREE",
    "overageCapability": "OVERAGE_CAPABLE",
    "upgradeCapability": "UPGRADE_CAPABLE",
    "subscriptionManagementTarget": "MANAGE"
  },
  "usageBreakdownList": [{
    "displayName": "Credit", "displayNamePlural": "Credits",
    "resourceType": "CREDIT", "unit": "INVOCATIONS", "currency": "USD",
    "currentUsage": 0, "usageLimit": 50,
    "currentOverages": 0, "overageCap": 10000, "overageRate": 0.04, "overageCharges": 0,
    "freeTrialInfo": { "freeTrialStatus": "ACTIVE", "currentUsage": 106, "usageLimit": 500, "freeTrialExpiry": <epoch_ms> },
    "overageCredits": [], "bonuses": [], "nextDateReset": <epoch_sec>
  }],
  "userInfo": { "userId": "d-...", "email": null }
}
```

## 备注与待办

- **kiro-web vs kiro-desktop 认证差异**：`app.kiro.dev/api/v1/me` 对 Bearer 返回 "Bearer token authentication is not supported for this operation" —— Web 端 REST 用会话 cookie，脚本场景应使用 management API 的 Bearer 认证。
- **leveldb JWT**：`~/Library/Application Support/kiro/Local Storage/leveldb/*.ldb` 当前无 JWT 命中（kiro 未运行、webview 未初始化）。设计阶段记录的 JWT 应为运行时 webview 写入的副本；持久、稳定的来源是 `~/.aws/sso/cache/kiro-auth-token.json`。
- **keychain**：`Kiro Safe Storage` / `Kiro Key`（Electron safeStorage）属主进程 Web 登录会话，扩展 bundle 无引用；Task 6 无需依赖。
- **token 刷新（已实现）**：见下方 Task 6 实现决策——403 触发 OIDC `refresh_token` 刷新（端点实测通过），非 401。
- **region**：默认 `us-east-1`，host 即 region（`management.us-east-1.kiro.dev`）。

## Task 6 实现决策（权威，勿偏离）

- **显示的信用值公式**：在 `usageBreakdownList[]` 中按 `resourceType == "CREDIT"` 过滤出信用条目（数组首个匹配项；若数组只有一个条目即为该条目）。**显示 `usageLimit - currentUsage`（剩余额度）**，即：
  - 若 `freeTrialInfo.freeTrialStatus == "ACTIVE"`：剩余 = `freeTrialInfo.usageLimit - freeTrialInfo.currentUsage`（免费试用桶，实测 500-106=394）
  - 否则：剩余 = 条目级 `usageLimit - currentUsage`（订阅桶，实测 50-0=50）
  - `fullText` 同时展示免费试用桶与订阅桶的数字；`shortText` 显示"剩余信用值"，格式如 `394cr`。
- **token 过期刷新（已实现）**：`GET getUsageLimits` 返回 **403**（`{"message":"Token expired"}`，accessToken 约 8h 有效）时，自动走 SSO OIDC 刷新：`POST https://oidc.us-east-1.amazonaws.com/token`，body `{"grantType":"refresh_token","refreshToken":…,"clientId":…,"clientSecret":…}`（clientIdHash 对应 `<clientIdHash>.json` 文件）。成功后新 accessToken 存入 `LocalSecretStore`（`kiroAccessToken`，不写 .aws 文件——provenance 权限不允许），下一轮 `defaultToken` 优先读缓存、兜底 .aws 文件；刷新失败（服务端拒绝）清除持久化凭据回退 .aws 文件；网络异常保留缓存下轮重试。401 与刷新后仍 401/403 时返回错误快照"kiro 登录过期，请重启 kiro 刷新"。
- **profileArn 缺失**：`profile.json` 不存在或 `arn` 为空 → `notLoggedIn` 错误快照"kiro 未登录"。
- **数值类型**：`currentUsage`/`usageLimit` 按 `Int` 解码（实测为整数）；`overageRate` 按 `Double`。若真网出现 `50.0` 形式则需容错（一期不处理，记录）。
- **URL 编码**：`profileArn` 含 `:` 与 `*`，实测裸传 200；仍建议 `URLComponents` 做 percent-encoding（正确实践）。
