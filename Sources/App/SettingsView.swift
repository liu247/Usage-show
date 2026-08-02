import SwiftUI

/// 设置窗口（Task 10）：工具显示开关 / DeepSeek API Key / 刷新间隔。
/// 承载于 AppDelegate.openSettings 的 NSWindow + NSHostingController（360x260），
/// frame 需与窗口内容尺寸一致。
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showKey = false
    @State private var customIntervalText = ""
    /// 当前值是否为预置选项（30/45/60）
    private var isPresetInterval: Bool { [30, 45, 60].contains(settings.refreshInterval) }

    var body: some View {
        Form {
            Section("显示的工具") {
                Toggle("Codex（订阅额度）", isOn: bindingFor("codex"))
                Toggle("DeepSeek（余额）", isOn: bindingFor("deepseek"))
                Toggle("Kiro（信用值）", isOn: bindingFor("kiro"))
            }
            Section("DeepSeek API Key") {
                HStack {
                    if showKey {
                        TextField("留空则读取环境变量 DEEPSEEK_API_KEY", text: $settings.deepseekApiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("留空则读取环境变量 DEEPSEEK_API_KEY", text: $settings.deepseekApiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showKey ? "隐藏 API key" : "显示 API key")
                }
            }
            Section("刷新间隔") {
                Picker("", selection: intervalSelection) {
                    Text("30 秒").tag(IntervalChoice.preset(30))
                    Text("45 秒").tag(IntervalChoice.preset(45))
                    Text("60 秒").tag(IntervalChoice.preset(60))
                    Text("自定义…").tag(IntervalChoice.custom)
                }
                .pickerStyle(.segmented)
                if !isPresetInterval {
                    HStack {
                        TextField("秒数（≥30）", text: $customIntervalText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { applyCustomInterval() }
                        Button("应用") { applyCustomInterval() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 260)
        .padding()
        .onAppear {
            if !isPresetInterval { customIntervalText = "\(settings.refreshInterval)" }
        }
    }

    /// Picker 双向绑定：预置值 ↔ .preset(n)，非预置 → .custom
    private var intervalSelection: Binding<IntervalChoice> {
        Binding(
            get: { isPresetInterval ? .preset(settings.refreshInterval) : .custom },
            set: { choice in
                if case .preset(let n) = choice {
                    settings.refreshInterval = n
                }
                // .custom 时保持当前值不变，让自定义输入框出现
            }
        )
    }

    private func applyCustomInterval() {
        guard let n = Int(customIntervalText.trimmingCharacters(in: .whitespacesAndNewlines)),
              n >= 30 else { return }  // 非法或 <30 忽略（与 AppSettings 下限一致）
        settings.refreshInterval = n
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

/// 刷新间隔选择：预置秒数或自定义
private enum IntervalChoice: Hashable {
    case preset(Int)
    case custom
}
