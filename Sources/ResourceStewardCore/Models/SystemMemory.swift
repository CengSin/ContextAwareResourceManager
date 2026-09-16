import Foundation

public enum MemoryPressureLevel: String, Codable, Sendable, Equatable {
    case normal
    case warning
    case critical

    public var title: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "紧张"
        }
    }

    public var symbolName: String {
        switch self {
        case .normal: return "circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }
}

public struct HostMemory: Sendable, Equatable {
    public let pageSize: UInt64
    public let physicalBytes: UInt64
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let speculativeBytes: UInt64
    public let purgeableBytes: UInt64
    public let internalBytes: UInt64
    public let externalBytes: UInt64
    public let swapTotalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapins: UInt64
    public let swapouts: UInt64
    public let sampledAt: Date

    public init(
        pageSize: UInt64,
        physicalBytes: UInt64,
        freeBytes: UInt64,
        activeBytes: UInt64,
        inactiveBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        speculativeBytes: UInt64,
        purgeableBytes: UInt64,
        internalBytes: UInt64,
        externalBytes: UInt64,
        swapTotalBytes: UInt64,
        swapUsedBytes: UInt64,
        swapins: UInt64,
        swapouts: UInt64,
        sampledAt: Date = Date()
    ) {
        self.pageSize = pageSize
        self.physicalBytes = physicalBytes
        self.freeBytes = freeBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.speculativeBytes = speculativeBytes
        self.purgeableBytes = purgeableBytes
        self.internalBytes = internalBytes
        self.externalBytes = externalBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapins = swapins
        self.swapouts = swapouts
        self.sampledAt = sampledAt
    }

    public var usedBytes: UInt64 {
        internalBytes + wiredBytes + compressedBytes
    }

    public var usedRatio: Double {
        guard physicalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(physicalBytes))
    }

    public var compressedRatio: Double {
        guard physicalBytes > 0 else { return 0 }
        return Double(compressedBytes) / Double(physicalBytes)
    }

    public func inferredPressure(sourceLevel: MemoryPressureLevel?) -> MemoryPressureLevel {
        if let sourceLevel, sourceLevel == .critical { return .critical }
        // swapins/swapouts are cumulative since boot; only current swap usage is a live signal.
        if swapUsedBytes > 1_073_741_824 {
            return .critical
        }
        if sourceLevel == .warning
            || compressedRatio > 0.25
            || usedRatio > 0.88
            || swapUsedBytes > 256 * 1024 * 1024 {
            return .warning
        }
        return .normal
    }

    public static let empty = HostMemory(
        pageSize: 4096,
        physicalBytes: 0,
        freeBytes: 0,
        activeBytes: 0,
        inactiveBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        speculativeBytes: 0,
        purgeableBytes: 0,
        internalBytes: 0,
        externalBytes: 0,
        swapTotalBytes: 0,
        swapUsedBytes: 0,
        swapins: 0,
        swapouts: 0
    )
}

public struct FavoriteApp: Codable, Hashable, Identifiable, Sendable, Equatable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    public var path: String

    public init(bundleID: String, name: String, path: String = "") {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var authorizationLevel: AuthorizationLevel
    public var weights: ScoreWeights
    public var matchingWindowMinutes: Double
    public var matchingThreshold: Double
    public var sampleIntervalSeconds: Double
    public var hasCompletedOnboarding: Bool
    public var showOnlyActionable: Bool
    public var favoriteApps: [FavoriteApp]

    public init(
        authorizationLevel: AuthorizationLevel = .suggestOnly,
        weights: ScoreWeights = .default,
        matchingWindowMinutes: Double = 10,
        matchingThreshold: Double = WorkspaceMatcher.defaultMinEvidence,
        sampleIntervalSeconds: Double = 3,
        hasCompletedOnboarding: Bool = false,
        showOnlyActionable: Bool = false,
        favoriteApps: [FavoriteApp] = []
    ) {
        self.authorizationLevel = authorizationLevel
        self.weights = weights
        self.matchingWindowMinutes = matchingWindowMinutes
        self.matchingThreshold = matchingThreshold
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.showOnlyActionable = showOnlyActionable
        self.favoriteApps = favoriteApps
    }

    public static let `default` = AppSettings()

    public var favoriteBundleIDs: Set<String> {
        Set(favoriteApps.map(\.bundleID))
    }

    enum CodingKeys: String, CodingKey {
        case authorizationLevel
        case weights
        case matchingWindowMinutes
        case matchingThreshold
        case sampleIntervalSeconds
        case hasCompletedOnboarding
        case showOnlyActionable
        case favoriteApps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authorizationLevel = try container.decodeIfPresent(AuthorizationLevel.self, forKey: .authorizationLevel) ?? .suggestOnly
        if authorizationLevel == .fullyAutomatic {
            authorizationLevel = .suggestOnly
        }
        weights = try container.decodeIfPresent(ScoreWeights.self, forKey: .weights) ?? .default
        matchingWindowMinutes = try container.decodeIfPresent(Double.self, forKey: .matchingWindowMinutes) ?? 10
        if let storedThreshold = try container.decodeIfPresent(Double.self, forKey: .matchingThreshold) {
            // 0.2 was the Jaccard default; evidence matching uses 0.6 so shared apps
            // like Chrome cannot classify a scene by themselves.
            matchingThreshold = abs(storedThreshold - 0.2) < 0.0001
                ? WorkspaceMatcher.defaultMinEvidence
                : storedThreshold
        } else {
            matchingThreshold = WorkspaceMatcher.defaultMinEvidence
        }
        sampleIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .sampleIntervalSeconds) ?? 3
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        showOnlyActionable = try container.decodeIfPresent(Bool.self, forKey: .showOnlyActionable) ?? false
        favoriteApps = try container.decodeIfPresent([FavoriteApp].self, forKey: .favoriteApps) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authorizationLevel, forKey: .authorizationLevel)
        try container.encode(weights, forKey: .weights)
        try container.encode(matchingWindowMinutes, forKey: .matchingWindowMinutes)
        try container.encode(matchingThreshold, forKey: .matchingThreshold)
        try container.encode(sampleIntervalSeconds, forKey: .sampleIntervalSeconds)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encode(showOnlyActionable, forKey: .showOnlyActionable)
        try container.encode(favoriteApps, forKey: .favoriteApps)
    }
}

public struct FrozenProcess: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let bundleID: String
    public let processName: String
    public let frozenAt: Date
    public let action: SuggestedAction

    public init(pid: Int32, bundleID: String, processName: String, frozenAt: Date = Date(), action: SuggestedAction) {
        self.pid = pid
        self.bundleID = bundleID
        self.processName = processName
        self.frozenAt = frozenAt
        self.action = action
    }
}
