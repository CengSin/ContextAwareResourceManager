import Foundation

public enum JevPipelineStatus: Sendable, Equatable {
    case loadNormal
    case observingLoad
    case noEligibleApps
    case noCandidates
    case assessing
    case deciding
    case failed(String)
    case requestCooldown
    case actionCooldown

    public var message: String {
        switch self {
        case .loadNormal: return "当前负载未达到 Jev 评估条件"
        case .observingLoad: return "正在观察持续负载：内存 20 秒 / CPU 30 秒"
        case .noEligibleApps: return "应用均受保护或不属于可治理应用，未请求 Jev"
        case .noCandidates: return "暂无满足空闲时间与资源占用条件的候选，未请求 Jev"
        case .assessing: return "Jev 正在评估负载与应用用途（1/2）…"
        case .deciding: return "Jev 正在根据评估选择动作（2/2）…"
        case .failed(let reason): return "Jev 评估失败，稍后重试：\(reason)"
        case .requestCooldown: return "等待上一批请求结束或请求间隔（至少 20 秒）"
        case .actionCooldown: return "正在观察处理效果，至少 30 秒后重新评估"
        }
    }

    public var code: String {
        switch self {
        case .loadNormal: return "load_normal"
        case .observingLoad: return "observing_load"
        case .noEligibleApps: return "no_eligible_apps"
        case .noCandidates: return "no_candidates"
        case .assessing: return "assessing"
        case .deciding: return "deciding"
        case .failed: return "failed"
        case .requestCooldown: return "request_cooldown"
        case .actionCooldown: return "action_cooldown"
        }
    }

    public static func idle(load: JevLoadState, grayAppCount: Int) -> JevPipelineStatus {
        guard ["warning", "critical"].contains(load.memory_pressure) || load.cpu_percent >= 80 else { return .loadNormal }
        guard grayAppCount > 0 else { return .noEligibleApps }
        let memoryReady = ["warning", "critical"].contains(load.memory_pressure) && load.memory_pressure_seconds >= 20
        let cpuReady = load.cpu_percent >= 80 && load.cpu_pressure_seconds >= 30
        return memoryReady || cpuReady ? .noCandidates : .observingLoad
    }
}
