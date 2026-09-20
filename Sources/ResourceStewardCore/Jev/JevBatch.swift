import Foundation


public struct JevGrayApp: Codable, Sendable, Equatable {
    public var index: Int
    public var bundle_id: String
    public var name: String
    public var idle_seconds: Double
    public var memory_mb: Double
    public var cpu_percent: Double
    public var owns_windows: Bool
    public var process_identity: String?

    public init(
        index: Int,
        bundle_id: String,
        name: String,
        idle_seconds: Double,
        memory_mb: Double,
        cpu_percent: Double,
        owns_windows: Bool,
        process_identity: String? = nil
    ) {
        self.index = index
        self.bundle_id = bundle_id
        self.name = name
        self.idle_seconds = idle_seconds
        self.memory_mb = memory_mb
        self.cpu_percent = cpu_percent
        self.owns_windows = owns_windows
        self.process_identity = process_identity
    }
}

public struct JevLoadState: Codable, Sendable, Equatable {
    public var memory_pressure: String
    public var cpu_percent: Double
    public var memory_used_ratio: Double
    public var swap_used_mb: Double
    public var foreground_bundle_id: String
    public var foreground_name: String

    public init(
        memory_pressure: String,
        cpu_percent: Double,
        memory_used_ratio: Double,
        swap_used_mb: Double,
        foreground_bundle_id: String = "",
        foreground_name: String = ""
    ) {
        self.memory_pressure = memory_pressure
        self.cpu_percent = cpu_percent
        self.memory_used_ratio = memory_used_ratio
        self.swap_used_mb = swap_used_mb
        self.foreground_bundle_id = foreground_bundle_id
        self.foreground_name = foreground_name
    }
}

public struct JevBatchRequestState: Codable, Sendable, Equatable {
    public var system: JevLoadState
    public var apps: [JevGrayApp]
    public var policy_hint: String

    public init(
        system: JevLoadState,
        apps: [JevGrayApp],
        policy_hint: String = JevBatchQuestions.policyHint
    ) {
        self.system = system
        self.apps = apps
        self.policy_hint = policy_hint
    }
}

public struct JevBatchSnapshot: Sendable, Equatable {
    public var signature: String
    public var actions: [String: SuggestedAction]
    public var pending: Bool
    public var requestID: String?

    public init(
        signature: String,
        actions: [String: SuggestedAction] = [:],
        pending: Bool = false,
        requestID: String? = nil
    ) {
        self.signature = signature
        self.actions = actions
        self.pending = pending
        self.requestID = requestID
    }

    public static let empty = JevBatchSnapshot(signature: "")
}

public enum JevBatchQuestions: Sendable {
    public static let maxApps = 12
    public static let policyHint =
        "Local code already excluded the foreground app, VPN/VM, meetings, IM, input methods, favorites, and system processes. Pick keep, throttle, or quit per listed app given current system load. Never choose freeze; freeze is disabled."

    public static func capped(_ apps: [JevGrayApp]) -> [JevGrayApp] {
        let sorted = apps.sorted {
            if $0.memory_mb != $1.memory_mb { return $0.memory_mb > $1.memory_mb }
            return $0.bundle_id < $1.bundle_id
        }
        return Array(sorted.prefix(maxApps)).enumerated().map { index, app in
            JevGrayApp(
                index: index,
                bundle_id: app.bundle_id,
                name: app.name,
                idle_seconds: app.idle_seconds,
                memory_mb: app.memory_mb,
                cpu_percent: app.cpu_percent,
                owns_windows: app.owns_windows,
                process_identity: app.process_identity
            )
        }
    }

    public static func signature(load: JevLoadState, apps: [JevGrayApp]) -> String {
        let cpuBucket = Int(load.cpu_percent / 15) * 15
        let memBucket = Int(load.memory_used_ratio * 10)
        let appPart = apps.map { app in
            let idleBucket = Int(app.idle_seconds / 60)
            let mbBucket = Int(app.memory_mb / 200)
            return "\(app.bundle_id):\(idleBucket):\(mbBucket):\(Int(app.cpu_percent / 15)):\(app.owns_windows):\(app.process_identity ?? "")"
        }.joined(separator: ",")
        return "\(load.foreground_bundle_id)|s\(Int(load.swap_used_mb / 200))|\(load.memory_pressure)|c\(cpuBucket)|m\(memBucket)|\(appPart)"
    }

    public static func payload(appCount: Int) -> [String: Any] {
        var questions: [String: Any] = [:]
        for index in 0..<appCount {
            questions["app_\(index)"] = [
                "type": "choice",
                "instructions": """
                For state.apps[\(index)] only, pick one action given system load and the full apps list. \
                Prefer keep when memory pressure is normal or the user is likely to need the app soon. \
                Use throttle to lower CPU priority without quitting. Use quit only when load is high \
                and relaunch is cheap. Never pick freeze. If uncertain, pick keep.
                """,
                "criteria": [
                    "keep": "Leave the app running unchanged.",
                    "throttle": "Lower CPU scheduling priority; keep the process alive.",
                    "quit": "Ask the app to quit so the system can reclaim its memory."
                ]
            ]
        }
        return questions
    }

    public static func parse(
        answers: [String: Any],
        apps: [JevGrayApp]
    ) -> [String: SuggestedAction] {
        var mapped: [String: SuggestedAction] = [:]
        for app in apps {
            let key = "app_\(app.index)"
            guard let obj = answers[key] as? [String: Any] else {
                mapped[app.bundle_id] = SuggestedAction.none
                continue
            }
            let choice = (obj["choice"] as? String) ?? "keep"
            let confidence = clamp01(doubleValue(obj["confidence"]) ?? 0)
            mapped[app.bundle_id] = JevBatchComposer.compose(choice: choice, confidence: confidence)
        }
        return mapped
    }

    public static func parseJSON(
        _ data: Data,
        apps: [JevGrayApp]
    ) throws -> [String: SuggestedAction] {
        guard let answers = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JevClientError.parse("batch answers not object")
        }
        return parse(answers: answers, apps: apps)
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let v as Double: return v
        case let v as Float: return Double(v)
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }
}

public enum JevGrayZone: Sendable {
    public static func apps(
        groups: [ProcessGroupViewModel],
        favorites: Set<String>,
        windowOwnerPIDs: Set<Int32>?
    ) -> [JevGrayApp] {
        var apps: [JevGrayApp] = []
        for group in groups {
            let candidate = JevHardGate.Candidate(
                group: group,
                favorites: favorites,
                windowOwnerPIDs: windowOwnerPIDs
            )
            guard JevHardGate.isGrayZone(candidate) else { continue }
            let bundle = candidate.bundleID
            guard !bundle.isEmpty, !bundle.hasPrefix("pid:") else { continue }
            apps.append(
                JevGrayApp(
                    index: apps.count,
                    bundle_id: bundle,
                    name: group.displayName,
                    idle_seconds: group.idleSeconds,
                    memory_mb: group.totalMemoryMB,
                    cpu_percent: group.cpuPercent,
                    owns_windows: group.ownsWindows,
                    process_identity: group.members.map { "\($0.snapshot.pid):\($0.snapshot.startUnix)" }.sorted().joined(separator: ",")
                )
            )
        }
        return apps
    }
}

public enum JevBatchComposer: Sendable {
    public static let confidenceThreshold = 0.7
    public static let quitConfidenceThreshold = 0.85

    public static func compose(choice: String, confidence: Double) -> SuggestedAction {
        let raw = choice.lowercased()
        var action: SuggestedAction
        switch raw {
        case "throttle":
            action = .throttle
        case "quit":
            action = .quit
        case "freeze":
            action = .throttle
        default:
            action = .none
        }
        if action == .none { return .none }
        if confidence < confidenceThreshold { return .none }
        if action == .quit, confidence < quitConfidenceThreshold { return .throttle }
        return action
    }
}
