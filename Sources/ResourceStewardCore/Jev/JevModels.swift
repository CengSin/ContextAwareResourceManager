import Foundation

public struct JevAppState: Codable, Sendable, Equatable {
    public var bundle_id: String
    public var name: String
    public var is_regular_app: Bool
    public var is_accessory: Bool
    public var owns_windows: Bool
    public var idle_seconds: Double
    public var memory_mb: Double
    public var cpu_percent_recent: Double
    public var in_current_workspace: Bool
    public var already_frozen: Bool
    public var english_name_hint: String?

    public init(
        bundle_id: String,
        name: String,
        is_regular_app: Bool,
        is_accessory: Bool,
        owns_windows: Bool,
        idle_seconds: Double,
        memory_mb: Double,
        cpu_percent_recent: Double,
        in_current_workspace: Bool,
        already_frozen: Bool,
        english_name_hint: String? = nil
    ) {
        self.bundle_id = bundle_id
        self.name = name
        self.is_regular_app = is_regular_app
        self.is_accessory = is_accessory
        self.owns_windows = owns_windows
        self.idle_seconds = idle_seconds
        self.memory_mb = memory_mb
        self.cpu_percent_recent = cpu_percent_recent
        self.in_current_workspace = in_current_workspace
        self.already_frozen = already_frozen
        self.english_name_hint = english_name_hint
    }

    public var truncatedSummary: String {
        let hint = english_name_hint.map { " hint=\($0)" } ?? ""
        return "bundle=\(bundle_id) name=\(name)\(hint) idle=\(Int(idle_seconds))s mem=\(Int(memory_mb))MB cpu=\(String(format: "%.1f", cpu_percent_recent))% windows=\(owns_windows) ws=\(in_current_workspace) frozen=\(already_frozen)"
    }
}

public struct JevSystemState: Codable, Sendable, Equatable {
    public var memory_pressure: String
    public var authorization_level: String

    public init(memory_pressure: String, authorization_level: String) {
        self.memory_pressure = memory_pressure
        self.authorization_level = authorization_level
    }
}

public struct JevPolicyHint: Codable, Sendable, Equatable {
    public var hard_gates_passed: Bool
    public var note: String

    public init(
        hard_gates_passed: Bool = true,
        note: String = "Local code already refused VPN, meeting, IM, a11y, keep-alive, and system processes. Freeze is disabled. Window ownership is in app.owns_windows as a fact only."
    ) {
        self.hard_gates_passed = hard_gates_passed
        self.note = note
    }
}

public struct JevRequestState: Codable, Sendable, Equatable {
    public var app: JevAppState
    public var system: JevSystemState
    public var policy_hint: JevPolicyHint

    public init(app: JevAppState, system: JevSystemState, policy_hint: JevPolicyHint = .init()) {
        self.app = app
        self.system = system
        self.policy_hint = policy_hint
    }
}

public struct JevNoulAnswer: Sendable, Equatable {
    public var value: Double

    public init(value: Double) {
        self.value = value
    }
}

public struct JevChoiceAnswer: Sendable, Equatable {
    public var choice: String
    public var confidence: Double
    public var probabilities: [String: Double]

    public init(choice: String, confidence: Double, probabilities: [String: Double] = [:]) {
        self.choice = choice
        self.confidence = confidence
        self.probabilities = probabilities
    }
}

public struct JevEvaluationAnswers: Sendable, Equatable {
    public var looksLikeNetworkOrSync: Double
    public var looksLikeCommunication: Double
    public var looksLikeInputOrA11y: Double
    public var looksLikeAVOrCapture: Double
    public var userLikelyNeedsSoon: Double
    public var safeToReclaimIdle: Double
    public var preferredAction: JevChoiceAnswer

    public init(
        looksLikeNetworkOrSync: Double,
        looksLikeCommunication: Double,
        looksLikeInputOrA11y: Double,
        looksLikeAVOrCapture: Double,
        userLikelyNeedsSoon: Double,
        safeToReclaimIdle: Double,
        preferredAction: JevChoiceAnswer
    ) {
        self.looksLikeNetworkOrSync = looksLikeNetworkOrSync
        self.looksLikeCommunication = looksLikeCommunication
        self.looksLikeInputOrA11y = looksLikeInputOrA11y
        self.looksLikeAVOrCapture = looksLikeAVOrCapture
        self.userLikelyNeedsSoon = userLikelyNeedsSoon
        self.safeToReclaimIdle = safeToReclaimIdle
        self.preferredAction = preferredAction
    }
}

public enum JevComposeRule: String, Sendable, Equatable {
    case risk
    case needsSoon = "needs_soon"
    case safeThreshold = "safe_threshold"
    case confidence
    case highStakesConfidence = "high_stakes_confidence"
    case choice
    case actionCeiling = "action_ceiling"
}

public struct JevComposeResult: Sendable, Equatable {
    public var action: SuggestedAction
    public var rule: JevComposeRule
    public var risk: Double
    public var needsSoon: Double
    public var safeToReclaim: Double
    public var preferredConfidence: Double
    public var preferredChoice: String

    public init(
        action: SuggestedAction,
        rule: JevComposeRule,
        risk: Double,
        needsSoon: Double,
        safeToReclaim: Double,
        preferredConfidence: Double,
        preferredChoice: String
    ) {
        self.action = action
        self.rule = rule
        self.risk = risk
        self.needsSoon = needsSoon
        self.safeToReclaim = safeToReclaim
        self.preferredConfidence = preferredConfidence
        self.preferredChoice = preferredChoice
    }
}

public struct JevUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct JevClientResult: Sendable, Equatable {
    public var requestID: String
    public var model: String
    public var answers: JevEvaluationAnswers
    public var usage: JevUsage
    public var httpStatus: Int
    public var latencyMs: Int
    public var fromCache: Bool

    public init(
        requestID: String,
        model: String,
        answers: JevEvaluationAnswers,
        usage: JevUsage = .init(),
        httpStatus: Int,
        latencyMs: Int,
        fromCache: Bool = false
    ) {
        self.requestID = requestID
        self.model = model
        self.answers = answers
        self.usage = usage
        self.httpStatus = httpStatus
        self.latencyMs = latencyMs
        self.fromCache = fromCache
    }
}

public enum JevClientError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidURL
    case httpStatus(Int, String)
    case timeout
    case transport(String)
    case parse(String)
    case incompleteAnswers

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "TypeSafe API Key 未配置。"
        case .invalidURL:
            return "Jev API URL 无效。"
        case .httpStatus(let code, let body):
            return "Jev HTTP \(code)：\(body.prefix(160))"
        case .timeout:
            return "Jev 请求超时。"
        case .transport(let message):
            return "Jev 网络错误：\(message)"
        case .parse(let message):
            return "Jev 响应解析失败：\(message)"
        case .incompleteAnswers:
            return "Jev 响应缺少必要答案字段。"
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .missingAPIKey, .invalidURL, .parse, .incompleteAnswers:
            return false
        case .httpStatus, .timeout, .transport:
            return true
        }
    }
}

public enum JevHardGateReason: String, Sendable, Equatable {
    case categoryBan = "category_ban"
    case keepAliveOrFavorite = "keep_alive_or_favorite"
    case ownsWindows = "owns_windows"
    case companionAlone = "companion_alone"
    case foreground = "foreground"
    case inWorkspaceCore = "in_workspace_core"
    case accessoryNotAllowed = "accessory_not_allowed"
    case notUserFacing = "not_user_facing"
    case protectedProcess = "protected"
}
