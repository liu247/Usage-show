import AppKit
import SwiftUI

/// 维护 NSStatusItem：数字标题 + 彩色圆点 + tooltip + 下拉菜单
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let store: RefreshStore
    private let onRefresh: () async -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private var isRefreshing = false  // 刷新中禁用"立即刷新"菜单项

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
            isRefreshing = true
            await onRefresh()
            isRefreshing = false
            self.showMenu()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        for snap in store.orderedSnapshots {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
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
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.isEnabled = !isRefreshing  // 刷新中禁用（spec：立即刷新禁用态）
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp(_:)), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        // 标准弹出方式：popUpMenu 直接弹出
        statusItem.popUpMenu(menu)
    }

    @objc private func refreshNow(_ sender: Any?) {
        Task { @MainActor in
            isRefreshing = true
            await onRefresh()
            isRefreshing = false
        }
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
        // 圆点图像：最紧张工具的状态色（red > gray > yellow > green）
        let worst = snaps.max { colorRank($0.status) < colorRank($1.status) }
        button.image = dotImage(color: color(for: worst?.status ?? .gray))
        // 失败快照 rawValue 为空 → 回退显示 fullText，避免 "Codex: " 悬空
        button.toolTip = snaps.map { "\($0.displayTitle): \($0.rawValue.isEmpty ? $0.fullText : $0.rawValue)" }
            .joined(separator: "\n")
    }

    // red 是"额度告急"（最紧急）> gray 是"暂时看不到/失败" > yellow > green
    private func colorRank(_ s: StatusLevel) -> Int {
        switch s { case .green: return 0; case .yellow: return 1; case .gray: return 2; case .red: return 3 }
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
