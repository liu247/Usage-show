# token_show

macOS 菜单栏工具：实时显示 codex / deepseek / kiro 的 token 额度与剩余量。

## 构建与运行

```bash
# 注意：本仓库位于 exFAT 卷（如 <本地卷路径>），SwiftPM 构建目录必须指到本地卷
swift build --disable-sandbox --scratch-path /tmp/token_show_build
swift run --scratch-path /tmp/token_show_build token_show
```

运行后菜单栏出现彩色圆点 + 数字（如 `● C 4% ¥88.5 394cr`），点击刷新并弹出菜单：明细、立即刷新、设置、退出。

## 数据源

| 工具 | 数据源 | 说明 |
|---|---|---|
| codex | `~/.codex/auth.json` → chatgpt.com/backend-api/codex/usage | 订阅制：周窗口/5小时窗口剩余 |
| deepseek | `DEEPSEEK_API_KEY`（或设置中填写）→ api.deepseek.com/user/balance | 充值制：剩余金额 |
| kiro | `~/.aws/sso/cache/kiro-auth-token.json` + kiro profile.json → management.us-east-1.kiro.dev/getUsageLimits | 信用制：剩余信用值（逆向确认，见 docs/kiro-reverse-notes.md） |

## 配置

设置窗口（菜单栏 → 设置…）可开关各工具、填写 deepseek API key（留空读环境变量）、选择刷新间隔（30/45/60s）。配置存 UserDefaults。

## 测试

本机开发环境无 Xcode.app（仅 Command Line Tools），无 XCTest.framework，测试用 Swift Testing 并需附加框架搜索路径：

```bash
cd <仓库路径> && \
FF=/Library/Developer/CommandLineTools/Library/Developer/Frameworks && \
UL=/Library/Developer/CommandLineTools/Library/Developer/usr/lib && \
swift test --disable-sandbox --scratch-path /tmp/token_show_build \
  -Xswiftc -F -Xswiftc "$FF" -Xlinker -F -Xlinker "$FF" \
  -Xlinker -rpath -Xlinker "$FF" -Xlinker -rpath -Xlinker "$UL"
```

## 已知限制

- codex usage 端点为非公开接口，若失效请更新 `Sources/Providers/CodexProvider.swift` 中的 URL。
- kiro token 过期后需重启 kiro 刷新（一期不做自动刷新）。
- 本机无 Xcode 时 `swift run` 启动的菜单栏 App 无打包签名，仅限本机使用。
