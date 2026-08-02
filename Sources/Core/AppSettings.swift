import Foundation

final class AppSettings: ObservableObject {
    // Swift 6 严格并发：单例由主线程独占访问（菜单栏应用逻辑均跑主线程），
    // 用 nonisolated(unsafe) 标记 static 存储属性；类保持非 Sendable，
    // 若未来把 AppSettings 实例跨 actor 传递，编译器仍会拦截。
    static nonisolated(unsafe) let shared = AppSettings()

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
