import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: RefreshStore!
    private var scheduler: RefreshScheduler!
    private var statusBar: StatusBarController!
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

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

        // 刷新间隔设置变化（设置窗口 30/45/60s）→ 重建定时器，实时生效。
        // dropFirst() 跳过订阅时的初始值（start() 已建好 timer，无需重复重建）。
        AppSettings.shared.$refreshInterval
            .dropFirst()
            .sink { [weak self] _ in self?.scheduler.reschedule() }
            .store(in: &cancellables)
    }

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
