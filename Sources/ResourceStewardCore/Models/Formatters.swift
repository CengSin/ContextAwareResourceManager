import Foundation

public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        string(Double(bytes))
    }

    public static func string(_ bytes: Double) -> String {
        let kb = bytes / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        if mb >= 10 {
            return String(format: "%.0f MB", mb)
        }
        if mb >= 1 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.0f KB", max(kb, 0))
    }

    public static func mb(_ megabytes: Double) -> String {
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        if megabytes >= 10 {
            return String(format: "%.0f MB", megabytes)
        }
        return String(format: "%.1f MB", megabytes)
    }
}

public enum DurationFormat {
    public static func idle(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "刚刚在前台" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "空闲 \(minutes) 分钟" }
        let hours = minutes / 60
        let rem = minutes % 60
        if hours < 24 { return rem == 0 ? "空闲 \(hours) 小时" : "空闲 \(hours) 小时 \(rem) 分" }
        return "空闲 \(hours / 24) 天"
    }
}

public struct ProcessViewModel: Identifiable, Sendable, Equatable {
    public var id: Int32 { snapshot.pid }
    public let snapshot: ProcessSnapshot
    public let score: ReclaimScoreRecord
    public let appPath: String?
    public let appliedAction: SuggestedAction?

    public init(
        snapshot: ProcessSnapshot,
        score: ReclaimScoreRecord,
        appPath: String?,
        appliedAction: SuggestedAction? = nil
    ) {
        self.snapshot = snapshot
        self.score = score
        self.appPath = appPath
        self.appliedAction = appliedAction
    }
}

public struct ProcessGroupViewModel: Identifiable, Sendable, Equatable {
    public var id: String { key }
    public let key: String
    public let members: [ProcessViewModel]

    public init(key: String, members: [ProcessViewModel]) {
        self.key = key
        self.members = members.sorted { $0.snapshot.memoryFootprintMB > $1.snapshot.memoryFootprintMB }
    }

    public var primary: ProcessViewModel { members[0] }

    public var displayName: String {
        if let main = members.first(where: { name in
            let n = name.snapshot.processName.lowercased()
            return !n.contains("helper") && !n.contains("renderer") && !n.contains("plugin")
        }) {
            return main.snapshot.processName
        }
        return primary.snapshot.processName
    }

    public var appPath: String? {
        members.compactMap(\.appPath).first(where: { $0.hasSuffix(".app") }) ?? primary.appPath
    }

    public var totalMemoryMB: Double {
        members.reduce(0) { $0 + $1.snapshot.memoryFootprintMB }
    }

    public var cpuPercent: Double {
        members.reduce(0) { $0 + $1.snapshot.cpuPercent }
    }

    public var idleSeconds: TimeInterval {
        members.map(\.snapshot.idleSeconds).min() ?? primary.snapshot.idleSeconds
    }

    public var isForeground: Bool {
        members.contains(where: { $0.snapshot.isForeground })
    }

    public var isAccessory: Bool {
        members.contains(where: { $0.snapshot.isAccessory })
    }

    public var isRegularApp: Bool {
        members.contains(where: { $0.snapshot.isRegularApp })
    }

    public var ownsWindows: Bool {
        members.contains(where: { $0.snapshot.ownsWindows })
    }

    public var isKeepAlive: Bool {
        members.contains {
            KeepAlivePolicy.isKeepAlive(
                bundleID: $0.snapshot.bundleID,
                processName: $0.snapshot.processName,
                path: $0.snapshot.path
            )
        }
    }

    public func matchesFavorites(_ ids: Set<String>) -> Bool {
        members.contains { KeepAlivePolicy.isUserListed(bundleID: $0.snapshot.bundleID, extras: ids) }
    }

    public var score: ReclaimScoreRecord {
        members.max(by: { $0.score.score < $1.score.score })?.score ?? primary.score
    }

    public var isProtected: Bool {
        members.allSatisfy(\.score.isProtected)
    }

    public var appliedAction: SuggestedAction? {
        if members.contains(where: { $0.appliedAction == .throttle }) { return .throttle }
        if members.contains(where: { $0.appliedAction == .freeze }) { return .freeze }
        return nil
    }

    public var companionCount: Int {
        members.filter {
            ProcessFamily.isCompanion(bundleID: $0.snapshot.bundleID, processName: $0.snapshot.processName)
        }.count
    }

    public var effectiveSuggestion: SuggestedAction {
        if isForeground { return .none }
        let suggested = score.suggestedAction.withoutFreeze()
        if appliedAction == .throttle && suggested == .throttle { return .none }
        return suggested
    }
}

public struct RunningAppInfo: Identifiable, Hashable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let path: String
    public let isBackground: Bool

    public init(bundleID: String, name: String, path: String, isBackground: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.isBackground = isBackground
    }
}
