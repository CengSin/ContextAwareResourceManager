import Foundation

public struct JevUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum JevClientError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidURL
    case httpStatus(Int, String)
    case timeout
    case transport(String)
    case parse(String)

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
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .missingAPIKey, .invalidURL, .parse:
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
