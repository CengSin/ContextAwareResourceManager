import Foundation

/// User-facing categories that must not be auto-managed. Users should not need
/// to know which bundle IDs are "safe to freeze".
///
/// VPN / tunnel and VM / container runtimes stay in `KeepAlivePolicy` and are
/// composed here so those lists are not duplicated.
public enum ResourceCategory: String, Sendable, Equatable, CaseIterable {
    case audioMeetingScreen
    case instantMessaging
    case accessibilityInputShell
    case appleWindowedUI
    case localMonitorSelf
    case keepAlive

    public var chineseName: String {
        switch self {
        case .audioMeetingScreen: return "音视频会议/录屏"
        case .instantMessaging: return "即时通讯"
        case .accessibilityInputShell: return "输入法与辅助工具"
        case .appleWindowedUI: return "系统自带应用"
        case .localMonitorSelf: return "本机监控"
        case .keepAlive: return "常驻网络或虚拟机"
        }
    }
}

public struct CategoryBanRules: Sendable, Equatable {
    public let banThrottle: Bool
    public let banFreeze: Bool
    public let allowSuggestQuit: Bool

    public init(banThrottle: Bool, banFreeze: Bool, allowSuggestQuit: Bool) {
        self.banThrottle = banThrottle
        self.banFreeze = banFreeze
        self.allowSuggestQuit = allowSuggestQuit
    }
}

public enum CategoryBanPolicy: Sendable {
    public static func rules(for category: ResourceCategory) -> CategoryBanRules {
        switch category {
        case .audioMeetingScreen:
            return CategoryBanRules(banThrottle: true, banFreeze: true, allowSuggestQuit: false)
        case .instantMessaging:
            return CategoryBanRules(banThrottle: true, banFreeze: true, allowSuggestQuit: true)
        case .accessibilityInputShell:
            return CategoryBanRules(banThrottle: true, banFreeze: true, allowSuggestQuit: false)
        case .appleWindowedUI:
            return CategoryBanRules(banThrottle: false, banFreeze: true, allowSuggestQuit: true)
        case .localMonitorSelf:
            return CategoryBanRules(banThrottle: true, banFreeze: true, allowSuggestQuit: false)
        case .keepAlive:
            return CategoryBanRules(banThrottle: true, banFreeze: true, allowSuggestQuit: false)
        }
    }

    public static func match(bundleID: String?, processName: String, path: String = "") -> ResourceCategory? {
        if KeepAlivePolicy.isKeepAlive(bundleID: bundleID, processName: processName, path: path) {
            return .keepAlive
        }
        let ids = uniqueIDs(bundleID)
        let blob = ((bundleID ?? "") + " " + processName + " " + path).lowercased()
        if ids.contains(where: { localMonitorBundleIDs.contains($0) })
            || localMonitorFragments.contains(where: { blob.contains($0) }) {
            return .localMonitorSelf
        }
        if ids.contains(where: { accessibilityBundleIDs.contains($0) })
            || accessibilityFragments.contains(where: { blob.contains($0) }) {
            return .accessibilityInputShell
        }
        if ids.contains(where: { meetingBundleIDs.contains($0) })
            || meetingFragments.contains(where: { blob.contains($0) }) {
            return .audioMeetingScreen
        }
        if ids.contains(where: { messagingBundleIDs.contains($0) })
            || messagingFragments.contains(where: { blob.contains($0) }) {
            return .instantMessaging
        }
        if ids.contains(where: { UserFacingAppPolicy.isAllowedAppleApp($0) }) {
            return .appleWindowedUI
        }
        return nil
    }

    public static func allows(
        _ action: SuggestedAction,
        in category: ResourceCategory
    ) -> Bool {
        let rules = rules(for: category)
        switch action {
        case .none: return true
        case .throttle: return !rules.banThrottle
        case .freeze: return !rules.banFreeze
        case .quit: return rules.allowSuggestQuit
        }
    }

    public static func allows(
        _ action: SuggestedAction,
        bundleID: String?,
        processName: String,
        path: String = ""
    ) -> Bool {
        guard let category = match(bundleID: bundleID, processName: processName, path: path) else {
            return true
        }
        return allows(action, in: category)
    }

    /// Level 1 never auto-acts on a banned category, including Apple user apps.
    public static func bansAutoAction(bundleID: String?, processName: String, path: String = "") -> Bool {
        match(bundleID: bundleID, processName: processName, path: path) != nil
    }

    public static func adjustedAction(
        _ action: SuggestedAction,
        bundleID: String?,
        processName: String,
        path: String = ""
    ) -> SuggestedAction {
        guard let category = match(bundleID: bundleID, processName: processName, path: path) else {
            return action
        }
        return adjustedAction(action, in: category)
    }

    public static func adjustedAction(
        _ action: SuggestedAction,
        in category: ResourceCategory
    ) -> SuggestedAction {
        switch action {
        case .none:
            return .none
        case .throttle:
            return allows(.throttle, in: category) ? .throttle : .none
        case .freeze:
            return allows(.freeze, in: category) ? .freeze : .none
        case .quit:
            if allows(.quit, in: category) { return .quit }
            if allows(.freeze, in: category) { return .freeze }
            if allows(.throttle, in: category) { return .throttle }
            return .none
        }
    }

    public static func refusalMessage(
        processName: String,
        category: ResourceCategory,
        action: SuggestedAction
    ) -> String {
        switch action {
        case .freeze:
            return "\(processName) 属于「\(category.chineseName)」，不会冻结。"
        case .throttle:
            return "\(processName) 属于「\(category.chineseName)」，不会降低优先级。"
        case .quit:
            return "\(processName) 属于「\(category.chineseName)」，不会退出。"
        case .none:
            return "\(processName) 属于「\(category.chineseName)」，无需处理。"
        }
    }

    private static func uniqueIDs(_ bundleID: String?) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for raw in [bundleID, ProcessFamily.rootBundleID(from: bundleID)] {
            guard let raw, !raw.isEmpty else { continue }
            let id = raw.lowercased()
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    private static let meetingBundleIDs: Set<String> = [
        "com.tencent.meeting",
        "com.timpler.screenstudio",
        "app.macked.screenstudio",
        "com.lemon.lvpro",
        "com.apple.music",
        "com.apple.quicktimeplayerx",
        "com.apple.facetime"
    ]

    private static let meetingFragments = [
        "tencentmeeting",
        "screen studio",
        "videofusion",
        "lvpro"
    ]

    private static let messagingBundleIDs: Set<String> = [
        "com.tencent.xinwechat",
        "com.tencent.weworkmac",
        "ru.keepcoder.telegram",
        "com.electron.lark",
        "com.apple.mobilesms"
    ]

    private static let messagingFragments = [
        "wechat",
        "wework",
        "telegram",
        "lark",
        "feishu"
    ]

    private static let accessibilityBundleIDs: Set<String> = [
        "com.raycast.macos",
        "com.dwarvesv.minimalbar",
        "com.crystalidea.macsfancontrol",
        "com.toubarreplace.app",
        "com.trycua.driver",
        "im.rime.inputmethod.squirrel"
    ]

    private static let accessibilityFragments = [
        "squirrel",
        "rime",
        "inputmethod",
        "sogou",
        "baiduime"
    ]

    private static let localMonitorBundleIDs: Set<String> = {
        var ids: Set<String> = [
            "com.robinebers.openusage",
            "cc.resourcesteward.app"
        ]
        if let live = Bundle.main.bundleIdentifier?.lowercased(), !live.isEmpty {
            ids.insert(live)
        }
        return ids
    }()

    private static let localMonitorFragments = [
        "openusage",
        "resourcesteward",
        "resource steward"
    ]
}
