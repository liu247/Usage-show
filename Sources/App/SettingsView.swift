import SwiftUI

/// 设置窗口（Task 10）：工具显示开关 / DeepSeek API Key / 刷新间隔。
/// 承载于 AppDelegate.openSettings 的 NSWindow + NSHostingController（360x260），
/// frame 需与窗口内容尺寸一致。
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

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
