import CoreFoundation
import Foundation

public struct JevUrgency: Codable, Sendable, Equatable {
    public var score: Double
    public var confidence: Double
    public var probabilities: [String: Double]

    public var supportsAction: Bool { score >= 2 && confidence >= 0.7 }
    public var label: String {
        if confidence < 0.7 { return "判断不确定" }
        return ["资源充裕", "继续观察", "需要缓解", "优先处理"][min(3, max(0, Int(score.rounded())))]
    }
}

public struct JevAppAssessment: Codable, Sendable, Equatable {
    public var work_related: Double
    public var continuous_service: Double
}

public struct JevAssessment: Codable, Sendable, Equatable {
    public var memory_urgency: JevUrgency
    public var cpu_urgency: JevUrgency
    public var apps: [String: JevAppAssessment]
}

public struct JevDecisionEvidence: Sendable, Equatable {
    public var assessment: JevAppAssessment
    public var memoryUrgency: JevUrgency
    public var cpuUrgency: JevUrgency
    public var confidence: Double
    public var candidateScore: Double
    public var memoryMB: Double
    public var idleSeconds: Double

    public var loadSummary: String {
        "内存：\(memoryUrgency.label) · CPU：\(cpuUrgency.label)"
    }

    public var judgmentSummary: String {
        "工作关联：\(Self.label(assessment.work_related)) · 持续后台用途：\(Self.label(assessment.continuous_service))"
    }

    private static func label(_ value: Double) -> String {
        if value >= 0.8 { return "倾向有" }
        if value <= 0.2 { return "倾向无" }
        return "不确定"
    }
}

public struct JevDecisionState: Encodable, Sendable {
    public var observations: JevBatchRequestState
    public var assessment: JevAssessment

    public init(observations: JevBatchRequestState, assessment: JevAssessment) {
        self.observations = observations
        self.assessment = assessment
    }
}

public enum JevAnswerValidation {
    public static func number(_ raw: Any?, in range: ClosedRange<Double>) throws -> Double {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, range.contains(number.doubleValue) else {
            throw JevClientError.parse("invalid numeric answer")
        }
        return number.doubleValue
    }

    public static func object(_ raw: Any?, type: String) throws -> [String: Any] {
        guard let obj = raw as? [String: Any], obj["type"] as? String == type else {
            throw JevClientError.parse("missing or incorrect answer type")
        }
        return obj
    }
}
