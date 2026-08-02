import Foundation

@MainActor
final class AppSettings: ObservableObject {
    // 主线程单例：全部 @Published 状态由主线程独占访问。
    // shared 用 nonisolated 允许任意上下文取引用；实例被 @MainActor 隔离（隐式 Sendable），
    // 后台线程读写属性会在编译期报错，强制调用方跳主线程（如 MainActor.run）。
    // 单例首次访问发生在主线程（app 启动/UI/调度器），故初始化用 MainActor.assumeIsolated。
    static nonisolated let shared = MainActor.assumeIsolated { AppSettings() }

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
