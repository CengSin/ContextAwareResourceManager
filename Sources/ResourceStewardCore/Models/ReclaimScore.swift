import Foundation

public struct ScoreComponents: Codable, Sendable, Equatable {
    public let idleContribution: Double
    public let memorySizeContribution: Double
    public let restartabilityContribution: Double
    public let workspacePenalty: Double
    public let foregroundPenalty: Double

    public init(
        idleContribution: Double,
        memorySizeContribution: Double,
        restartabilityContribution: Double,
        workspacePenalty: Double,
        foregroundPenalty: Double
    ) {
        self.idleContribution = idleContribution
        self.memorySizeContribution = memorySizeContribution
        self.restartabilityContribution = restartabilityContribution
        self.workspacePenalty = workspacePenalty
        self.foregroundPenalty = foregroundPenalty
    }

    public var items: [(label: String, value: Double, isPenalty: Bool)] {
        [
            ("空闲", idleContribution, false),
            ("内存", memorySizeContribution, false),
            ("可重启", restartabilityContribution, false),
            ("当前场景", -workspacePenalty, true),
            ("前台", -foregroundPenalty, true)
        ]
    }
}

public struct ReclaimScoreRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { bundleID + "-\(pid)" }

    public let pid: Int32
    public let bundleID: String
    public let processName: String
    public let score: Double
    public let components: ScoreComponents
    public let suggestedAction: SuggestedAction
    public let computedAt: Date
    public let estimatedReleaseMB: Double
    public let isProtected: Bool
    public let isInCurrentWorkspace: Bool

    public init(
        pid: Int32,
        bundleID: String,
        processName: String,
        score: Double,
        components: ScoreComponents,
        suggestedAction: SuggestedAction,
        computedAt: Date = Date(),
        estimatedReleaseMB: Double,
        isProtected: Bool,
        isInCurrentWorkspace: Bool
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.processName = processName
        self.score = score
        self.components = components
        self.suggestedAction = suggestedAction
        self.computedAt = computedAt
        self.estimatedReleaseMB = estimatedReleaseMB
        self.isProtected = isProtected
        self.isInCurrentWorkspace = isInCurrentWorkspace
    }
}

public struct ScoreWeights: Codable, Sendable, Equatable {
    public var idle: Double
    public var memory: Double
    public var restartability: Double
    public var workspace: Double
    public var foreground: Double
    public var idleCapMinutes: Double
    public var memoryCapMB: Double
    public var noneBelow: Double
    public var throttleBelow: Double
    public var freezeBelow: Double

    public init(
        idle: Double = 30,
        memory: Double = 25,
        restartability: Double = 15,
        workspace: Double = 80,
        foreground: Double = 999,
        idleCapMinutes: Double = 120,
        memoryCapMB: Double = 8192,
        noneBelow: Double = 30,
        throttleBelow: Double = 60,
        freezeBelow: Double = 85
    ) {
        self.idle = idle
        self.memory = memory
        self.restartability = restartability
        self.workspace = workspace
        self.foreground = foreground
        self.idleCapMinutes = idleCapMinutes
        self.memoryCapMB = memoryCapMB
        self.noneBelow = noneBelow
        self.throttleBelow = throttleBelow
        self.freezeBelow = freezeBelow
    }

    public static let `default` = ScoreWeights()

    public var positiveSum: Double {
        max(idle + memory + restartability, 0.0001)
    }
}

public struct UserFeedback: Codable, Sendable, Equatable {
    public let bundleID: String
    public let scoreAtDecisionTime: Double
    public let userAction: String
    public let timestamp: Date

    public init(bundleID: String, scoreAtDecisionTime: Double, userAction: String, timestamp: Date = Date()) {
        self.bundleID = bundleID
        self.scoreAtDecisionTime = scoreAtDecisionTime
        self.userAction = userAction
        self.timestamp = timestamp
    }
}
