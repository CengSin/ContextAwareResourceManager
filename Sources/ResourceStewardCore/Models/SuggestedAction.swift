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
            return "将暂停该进程（SIGSTOP）。冻结后内存通常仍被占用，直到系统稍后自然回收。你可以随时恢复。"
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
            return "切换到已识别的工作场景并稳定约 15 秒后，自动降低优先级或冻结离场景应用。退出建议会改成冻结。VPN/代理（如 Shadowrocket）和菜单栏常驻工具不会自动处理。未分类不触发。"
        case .fullyAutomatic:
            return "v3 能力：完全自动处理。当前版本不可用，且默认关闭。"
        }
    }

    public var isAvailable: Bool { self != .fullyAutomatic }
}
