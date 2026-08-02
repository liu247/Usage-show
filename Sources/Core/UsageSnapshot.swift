import Foundation

enum StatusLevel {
    case green, yellow, red, gray

    /// 按已用比例映射状态色；nil（金额/信用类）由 Provider 自行指定
    static func fromFractionUsed(_ f: Double?) -> StatusLevel {
        guard let f else { return .gray }
        if f > 0.8 { return .red }
        if f > 0.5 { return .yellow }
        return .green
    }
}

struct UsageSnapshot {
    let providerID: String
    let shortText: String       // 菜单栏数字段，如 "4%"
    let fullText: String        // 下拉明细，如 "周窗口剩余 4%，5 小时后重置"
    let fractionUsed: Double?   // 0-1；nil = 无比例概念（金额/信用）
    let rawValue: String        // tooltip 原文，如 "¥88.5"
    let updatedAt: Date
    let error: String?          // 非 nil 表示获取失败
    let status: StatusLevel     // 颜色（Provider 内已算好；失败必为 .gray）

    init(providerID: String, shortText: String, fullText: String,
         fractionUsed: Double?, rawValue: String, updatedAt: Date = Date(),
         error: String? = nil, status: StatusLevel? = nil) {
        self.providerID = providerID
        self.shortText = shortText
        self.fullText = fullText
        self.fractionUsed = fractionUsed
        self.rawValue = rawValue
        self.updatedAt = updatedAt
        self.error = error
        if let status {
            self.status = status
        } else if error != nil {
            self.status = .gray
        } else {
            self.status = .fromFractionUsed(fractionUsed)
        }
    }

    /// 菜单栏前缀：codex → C、deepseek → D、kiro → K
    var prefix: String {
        switch providerID {
        case "codex": return "C"
        case "deepseek": return "D"
        case "kiro": return "K"
        default: return String(providerID.prefix(1)).uppercased()
        }
    }

    var menuBarText: String { "\(prefix) \(shortText)" }
}
