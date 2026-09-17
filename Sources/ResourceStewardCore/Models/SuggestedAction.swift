import Foundation

public enum SuggestedAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case throttle
    case freeze
    case quit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "无需处理"
        case .throttle: return "降低优先级"
        case .freeze: return "冻结"
        case .quit: return "退出"
        }
    }

    public var confirmationTitle: String {
        switch self {
        case .none: return "无需处理"
        case .throttle: return "降低该进程的 CPU 优先级"
        case .freeze: return "冻结该进程"
        case .quit: return "请求退出该应用"
        }
    }

    public var confirmationDetail: String {
        switch self {
        case .none:
            return "当前分数未达到建议处理的阈值。"
        case .throttle:
            return "将提高该进程的 nice 值，降低 CPU 调度优先级。这不会直接回收内存。"
        case .freeze:
            return "将暂停该进程（SIGSTOP）。有窗口的应用会被拒绝，因为冻结它们会卡住屏幕。无窗口的进程冻结后内存通常仍被占用，直到系统稍后自然回收。你可以随时恢复。"
        case .quit:
            return "将请求应用退出（不是强制结束）。若有未保存内容，应用自己会提示。退出后内存由 macOS 自然回收，本工具不会直接压缩内存。"
        }
    }
}

public enum UserFeedbackAction: String, Codable, Sendable {
    case accepted
    case rejected
    case manualOverride = "manual_override"
    case autoSceneSwitch = "auto_scene_switch"
}

public enum AuthorizationLevel: Int, Codable, Sendable, CaseIterable, Identifiable {
    case suggestOnly = 0
    case sceneSwitch = 1
    case fullyAutomatic = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .suggestOnly: return "仅建议（Level 0）"
        case .sceneSwitch: return "切场景时半自动（Level 1）"
        case .fullyAutomatic: return "完全自动（Level 2）"
        }
    }

    public var footnote: String {
        switch self {
        case .suggestOnly:
            return "默认。所有冻结/退出/降优先级都需要你点击确认。"
        case .sceneSwitch:
            return "识别到工作场景后，自动冻结空闲约 2 分钟以上、且分数达到冻结阈值的离场景应用。停留在同一场景时也会处理，不必等再切一次。有窗口的应用不会自动冻结，避免卡住屏幕。降低优先级不再自动执行。系统守护进程、小组件、VPN/容器、常用应用和场景核心 App 不会冻结。未分类不触发。"
        case .fullyAutomatic:
            return "v3 能力：完全自动处理。当前版本不可用，且默认关闭。"
        }
    }

    public var isAvailable: Bool { self != .fullyAutomatic }
}
