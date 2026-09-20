import Foundation


public enum AppIdlePolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case keep
    case throttle
    case freeze
    case quit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keep: return "保活"
        case .throttle: return "可降速"
        case .freeze: return "可冻结"
        case .quit: return "可退出"
        }
    }

    public var suggestedAction: SuggestedAction {
        switch self {
        case .keep: return .none
        case .throttle: return .throttle
        case .freeze: return .freeze
        case .quit: return .quit
        }
    }
}

public enum AppClassificationSource: String, Codable, Sendable {
    case localRule = "local_rule"
    case jev
}

public struct AppClassification: Codable, Sendable, Equatable, Identifiable {
    
    public static let currentSchemaVersion = 2

    public var id: String { bundleID }

    public var bundleID: String
    public var name: String
    public var path: String
    public var policy: AppIdlePolicy
    public var source: AppClassificationSource
    public var keepRunning: Double
    public var loseWorkIfQuit: Double
    public var cheapToRelaunch: Double
    public var confidence: Double
    public var requestID: String?
    public var classifiedAt: Date
    public var schemaVersion: Int

    public init(
        bundleID: String,
        name: String,
        path: String,
        policy: AppIdlePolicy,
        source: AppClassificationSource,
        keepRunning: Double = 0,
        loseWorkIfQuit: Double = 0,
        cheapToRelaunch: Double = 0,
        confidence: Double = 1,
        requestID: String? = nil,
        classifiedAt: Date = Date(),
        schemaVersion: Int = AppClassification.currentSchemaVersion
    ) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.policy = policy
        self.source = source
        self.keepRunning = keepRunning
        self.loseWorkIfQuit = loseWorkIfQuit
        self.cheapToRelaunch = cheapToRelaunch
        self.confidence = confidence
        self.requestID = requestID
        self.classifiedAt = classifiedAt
        self.schemaVersion = schemaVersion
    }

    public var allowsAutoReclaim: Bool { policy != .keep }

    public var needsReclassify: Bool {
        source == .jev && schemaVersion < AppClassification.currentSchemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case bundleID, name, path, policy, source
        case keepRunning, loseWorkIfQuit, cheapToRelaunch, confidence
        case requestID, classifiedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        policy = try c.decode(AppIdlePolicy.self, forKey: .policy)
        source = try c.decode(AppClassificationSource.self, forKey: .source)
        keepRunning = try c.decodeIfPresent(Double.self, forKey: .keepRunning) ?? 0
        loseWorkIfQuit = try c.decodeIfPresent(Double.self, forKey: .loseWorkIfQuit) ?? 0
        cheapToRelaunch = try c.decodeIfPresent(Double.self, forKey: .cheapToRelaunch) ?? 0
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        classifiedAt = try c.decodeIfPresent(Date.self, forKey: .classifiedAt) ?? Date()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(policy, forKey: .policy)
        try c.encode(source, forKey: .source)
        try c.encode(keepRunning, forKey: .keepRunning)
        try c.encode(loseWorkIfQuit, forKey: .loseWorkIfQuit)
        try c.encode(cheapToRelaunch, forKey: .cheapToRelaunch)
        try c.encode(confidence, forKey: .confidence)
        try c.encodeIfPresent(requestID, forKey: .requestID)
        try c.encode(classifiedAt, forKey: .classifiedAt)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }
}
