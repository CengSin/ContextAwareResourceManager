import Foundation


public enum JevComposer: Sendable {
    public static let riskThreshold = 0.55
    public static let needsSoonThreshold = 0.6
    public static let safeThreshold = 0.65
    
    public static let confidenceThreshold = 0.7
    public static let freezeConfidenceThreshold = 0.85
    public static let quitConfidenceThreshold = 0.85

    public static func compose(_ answers: JevEvaluationAnswers) -> JevComposeResult {
        let risk = max(
            answers.looksLikeNetworkOrSync,
            answers.looksLikeCommunication,
            answers.looksLikeInputOrA11y,
            answers.looksLikeAVOrCapture
        )
        let needsSoon = answers.userLikelyNeedsSoon
        let safe = answers.safeToReclaimIdle
        let conf = answers.preferredAction.confidence
        let choiceRaw = answers.preferredAction.choice.lowercased()

        if risk >= riskThreshold {
            return result(.none, .risk, risk, needsSoon, safe, conf, choiceRaw)
        }
        if needsSoon >= needsSoonThreshold {
            return result(.none, .needsSoon, risk, needsSoon, safe, conf, choiceRaw)
        }
        if safe < safeThreshold {
            return result(.none, .safeThreshold, risk, needsSoon, safe, conf, choiceRaw)
        }
        if conf < confidenceThreshold {
            return result(.none, .confidence, risk, needsSoon, safe, conf, choiceRaw)
        }
        var action = (SuggestedAction(rawValue: choiceRaw) ?? .none).withoutFreeze()
        if action == .freeze {
            action = .throttle
        }
        if action == .quit, conf < quitConfidenceThreshold {
            return result(.throttle, .highStakesConfidence, risk, needsSoon, safe, conf, choiceRaw)
        }
        if choiceRaw == "freeze" {
            return result(.throttle, .actionCeiling, risk, needsSoon, safe, conf, choiceRaw)
        }
        return result(action, .choice, risk, needsSoon, safe, conf, choiceRaw)
    }

    private static func result(
        _ action: SuggestedAction,
        _ rule: JevComposeRule,
        _ risk: Double,
        _ needsSoon: Double,
        _ safe: Double,
        _ conf: Double,
        _ choice: String
    ) -> JevComposeResult {
        JevComposeResult(
            action: action,
            rule: rule,
            risk: risk,
            needsSoon: needsSoon,
            safeToReclaim: safe,
            preferredConfidence: conf,
            preferredChoice: choice
        )
    }
}
