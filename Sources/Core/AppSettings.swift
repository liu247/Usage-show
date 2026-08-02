import Foundation

@MainActor
final class AppSettings: ObservableObject {
    // 主线程单例：全部 @Published 状态由主线程独占访问。
    // shared 用 nonisolated 允许任意上下文取引用；实例被 @MainActor 隔离（隐式 Sendable），
    // 后台线程读写属性会在编译期报错，强制调用方跳主线程（如 MainActor.run）。
    // 单例首次访问发生在主线程（app 启动/UI/调度器），故初始化用 MainActor.assumeIsolated。
    static nonisolated let shared = MainActor.assumeIsolated { AppSettings() }

    /// API key 规范化：去除首尾空白（含粘贴时带入的换行），nil 视为空串。
    /// nonisolated：供非主线程（DeepSeekProvider.defaultApiKeyProvider 后台回退路径）直接调用。
    nonisolated static func sanitizeKey(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @Published var enabledProviders: [String] {
        didSet { UserDefaults.standard.set(enabledProviders, forKey: "enabledProviders") }
    }
    /// DeepSeek API key 存 Keychain（明文不落 UserDefaults）；存储时 trim 首尾空白，
    /// 修复粘贴时尾随换行导致 "Bearer key\n" 认证 401 的问题。
    @Published var deepseekApiKey: String {
        didSet {
            let cleaned = Self.sanitizeKey(deepseekApiKey)
            // 内存值保持用户输入原样即可，存储与读取路径均已 trim。
            KeychainStore.set(cleaned, key: "deepseekApiKey")
        }
    }
    @Published var refreshInterval: Int {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval") }
    }

    init() {
        let d = UserDefaults.standard
        enabledProviders = d.stringArray(forKey: "enabledProviders") ?? ["codex", "deepseek", "kiro"]
        // DeepSeek API key：Keychain 优先。Keychain 无值时迁移 UserDefaults 旧值
        // （trim 后写入 Keychain 并删除明文残留，一次性清理）。
        // 注：init 中给属性赋值不会触发 didSet，故迁移需显式写 Keychain。
        let stored = Self.sanitizeKey(KeychainStore.get("deepseekApiKey"))
        if !stored.isEmpty {
            deepseekApiKey = stored
        } else if let legacy = d.string(forKey: "deepseekApiKey") {
            let cleaned = Self.sanitizeKey(legacy)
            deepseekApiKey = cleaned
            if !cleaned.isEmpty {
                // 写入 Keychain 成功才删除明文残留；失败则保留旧值，下次启动重试迁移，
                // 避免两处都丢失 key。
                if KeychainStore.set(cleaned, key: "deepseekApiKey") {
                    d.removeObject(forKey: "deepseekApiKey")
                }
            } else {
                d.removeObject(forKey: "deepseekApiKey") // 纯空白旧值无用，直接清理
            }
        } else {
            deepseekApiKey = ""
        }
        let saved = d.integer(forKey: "refreshInterval")
        refreshInterval = saved >= 30 ? saved : 45
    }

    func isEnabled(_ id: String) -> Bool { enabledProviders.contains(id) }
}
