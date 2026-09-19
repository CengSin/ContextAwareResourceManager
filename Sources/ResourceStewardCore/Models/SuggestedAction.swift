import Foundation

public enum SuggestedAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case throttle
    case freeze
    case quit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "保留"
        case .throttle: return "降低优先级"
        case .freeze: return "冻结（已停用）"
        case .quit: return "退出"
        }
    }

    public var confirmationTitle: String {
        switch self {
        case .none: return "保留，不处理"
        case .throttle: return "降低该进程的 CPU 优先级"
        case .freeze: return "冻结已停用"
        case .quit: return "请求退出该应用"
        }
    }

    public var confirmationDetail: String {
        switch self {
        case .none:
            return "保持运行，不做处理。"
        case .throttle:
            return "将提高该进程的 nice 值，降低 CPU 调度优先级。这不会直接回收内存。"
        case .freeze:
            return "冻结已停用，避免卡住屏幕。旧版本留下的冻结进程仍可恢复。"
        case .quit:
            return "将请求应用退出（不是强制结束）。若有未保存内容，应用自己会提示。退出后内存由 macOS 自然回收，本工具不会直接压缩内存。"
        }
    }

    /// Product actions Jev may choose. Freeze is retired.
    public var isActable: Bool {
        self == .throttle || self == .quit
    }

    public static var userSelectable: [SuggestedAction] { [.throttle, .quit] }

    public func withoutFreeze() -> SuggestedAction {
        self == .freeze ? .throttle : self
    }
}

public enum UserFeedbackAction: String, Codable, Sendable {
    case accepted
    case rejected
    case manualOverride = "manual_override"
    case autoSceneSwitch = "auto_scene_switch"
    case autoIdleReclaim = "auto_idle_reclaim"
}

public enum AuthorizationLevel: Int, Codable, Sendable, CaseIterable, Identifiable {
    case suggestOnly = 0
    case sceneSwitch = 1
    case fullyAutomatic = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .suggestOnly: return "仅建议（Level 0）"
        case .sceneSwitch: return "半自动（Level 1）"
        case .fullyAutomatic: return "完全自动（Level 2）"
        }
    }

    public var footnote: String {
        switch self {
        case .suggestOnly:
            return "Jev 根据系统负载和正在运行的灰区 App 给出保留/降级/退出建议，独立小窗由你确认后才执行。"
        case .sceneSwitch:
            return "Jev 根据系统负载和正在运行的灰区 App 自动降级或退出，完成后发系统通知。前台、VPN/会议/IM、常用和系统进程不会进名单。没有冻结。"
        case .fullyAutomatic:
            return "v3 能力：完全自动处理。当前版本不可用，且默认关闭。"
        }
    }

    public var isAvailable: Bool { self != .fullyAutomatic }
}
