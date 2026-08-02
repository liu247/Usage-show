import Foundation

/// 持有各工具最新快照，驱动菜单栏 UI 更新
@MainActor
final class RefreshStore: ObservableObject {
    @Published private(set) var snapshots: [String: UsageSnapshot] = [:]

    func update(_ snap: UsageSnapshot) {
        snapshots[snap.providerID] = snap
    }

    func updateError(id: String, error: String) {
        snapshots[id] = UsageSnapshot(
            providerID: id, shortText: "--", fullText: error,
            fractionUsed: nil, rawValue: "", updatedAt: Date(), error: error)
    }

    /// 按启用顺序返回快照（codex → deepseek → kiro）
    var orderedSnapshots: [UsageSnapshot] {
        let order = ["codex", "deepseek", "kiro"]
        return order.compactMap { snapshots[$0] }
    }

    func snapshot(for id: String) -> UsageSnapshot? { snapshots[id] }
}
