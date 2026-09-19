import Foundation

public struct ScoreComponents: Codable, Sendable, Equatable {
    public let idleContribution: Double
    public let memorySizeContribution: Double
    public let restartabilityContribution: Double
    public let workspacePenalty: Double
    public let foregroundPenalty: Double
    public let offWorkspaceContribution: Double

    public init(
        idleContribution: Double,
        memorySizeContribution: Double,
        restartabilityContribution: Double,
        workspacePenalty: Double,
        foregroundPenalty: Double,
        offWorkspaceContribution: Double = 0
    ) {
        self.idleContribution = idleContribution
        self.memorySizeContribution = memorySizeContribution
        self.restartabilityContribution = restartabilityContribution
        self.workspacePenalty = workspacePenalty
        self.foregroundPenalty = foregroundPenalty
        self.offWorkspaceContribution = offWorkspaceContribution
    }

    public var items: [(label: String, value: Double, isPenalty: Bool)] {
        [
            ("空闲", idleContribution, false),
            ("内存", memorySizeContribution, false),
            ("可重启", restartabilityContribution, false),
            ("离场景", offWorkspaceContribution, false),
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

    public static func == (lhs: ReclaimScoreRecord, rhs: ReclaimScoreRecord) -> Bool {
        lhs.pid == rhs.pid
            && lhs.bundleID == rhs.bundleID
            && lhs.processName == rhs.processName
            && abs(lhs.score - rhs.score) < 0.5
            && lhs.components == rhs.components
            && lhs.suggestedAction == rhs.suggestedAction
            && abs(lhs.estimatedReleaseMB - rhs.estimatedReleaseMB) < 0.5
            && lhs.isProtected == rhs.isProtected
            && lhs.isInCurrentWorkspace == rhs.isInCurrentWorkspace
    }

    public func with(suggestedAction action: SuggestedAction) -> ReclaimScoreRecord {
        ReclaimScoreRecord(
            pid: pid,
            bundleID: bundleID,
            processName: processName,
            score: score,
            components: components,
            suggestedAction: action,
            computedAt: computedAt,
            estimatedReleaseMB: estimatedReleaseMB,
            isProtected: isProtected,
            isInCurrentWorkspace: isInCurrentWorkspace
        )
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
    /// Bonus when a classified workspace is active and this app is not in it.
    public var offWorkspace: Double

    public init(
        idle: Double = 30,
        memory: Double = 25,
        restartability: Double = 15,
        workspace: Double = 80,
        foreground: Double = 999,
        idleCapMinutes: Double = 45,
        memoryCapMB: Double = 2048,
        noneBelow: Double = 30,
        throttleBelow: Double = 60,
        freezeBelow: Double = 85,
        offWorkspace: Double = 28
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
        self.offWorkspace = offWorkspace
    }

    public static let `default` = ScoreWeights()

    public var positiveSum: Double {
        max(idle + memory + restartability, 0.0001)
    }

    enum CodingKeys: String, CodingKey {
        case idle, memory, restartability, workspace, foreground
        case idleCapMinutes, memoryCapMB, noneBelow, throttleBelow, freezeBelow
        case offWorkspace
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idle = try container.decodeIfPresent(Double.self, forKey: .idle) ?? 30
        memory = try container.decodeIfPresent(Double.self, forKey: .memory) ?? 25
        restartability = try container.decodeIfPresent(Double.self, forKey: .restartability) ?? 15
        workspace = try container.decodeIfPresent(Double.self, forKey: .workspace) ?? 80
        foreground = try container.decodeIfPresent(Double.self, forKey: .foreground) ?? 999
        idleCapMinutes = try container.decodeIfPresent(Double.self, forKey: .idleCapMinutes) ?? 45
        memoryCapMB = try container.decodeIfPresent(Double.self, forKey: .memoryCapMB) ?? 2048
        noneBelow = try container.decodeIfPresent(Double.self, forKey: .noneBelow) ?? 30
        throttleBelow = try container.decodeIfPresent(Double.self, forKey: .throttleBelow) ?? 60
        freezeBelow = try container.decodeIfPresent(Double.self, forKey: .freezeBelow) ?? 85
        offWorkspace = try container.decodeIfPresent(Double.self, forKey: .offWorkspace) ?? 28
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(idle, forKey: .idle)
        try container.encode(memory, forKey: .memory)
        try container.encode(restartability, forKey: .restartability)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(foreground, forKey: .foreground)
        try container.encode(idleCapMinutes, forKey: .idleCapMinutes)
        try container.encode(memoryCapMB, forKey: .memoryCapMB)
        try container.encode(noneBelow, forKey: .noneBelow)
        try container.encode(throttleBelow, forKey: .throttleBelow)
        try container.encode(freezeBelow, forKey: .freezeBelow)
        try container.encode(offWorkspace, forKey: .offWorkspace)
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
