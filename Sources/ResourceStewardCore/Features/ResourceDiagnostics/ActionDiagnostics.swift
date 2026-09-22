import Darwin
import Foundation

public final class ActionDiagnostics {
    private struct Observation {
        let id: String
        let requestID: String
        let action: SuggestedAction
        let generations: [ProcessGeneration]
        let bundleID: String
        let started: Date
        let memoryBeforeMB: Double
        let cpuBefore: Double
        let hostBefore: UInt64
        var firstChecked = false
    }
    private var pending: [Observation] = []

    public init() {}

    public func execute(group: ProcessGroupViewModel, action: SuggestedAction, origin: String, requestID: String?,
                        executor: ActionExecutor, host: HostMemory) -> ActionResult {
        let id = UUID().uuidString
        let correlation = requestID ?? "manual"
        DiagnosticLog.shared.record("action_requested", ["action_id": id, "request_id": correlation,
            "bundle_id": group.key, "action": action.rawValue, "origin": origin,
            "memory_before_mb": group.totalMemoryMB, "cpu_before_percent": group.cpuPercent,
            "host_used_before_bytes": host.usedBytes,
            "generations": group.members.map { $0.snapshot.generation.key }])
        let result = executor.execute(action: action, snapshots: group.members.map(\.snapshot),
            groupBundleID: group.key.hasPrefix("pid:") ? group.primary.snapshot.bundleID : group.key)
        DiagnosticLog.shared.record("action_result", ["action_id": id, "request_id": correlation,
            "bundle_id": group.key, "requested_action": action.rawValue, "result_action": result.action.rawValue,
            "ok": result.ok, "pid": result.pid, "message": result.message,
            "quit_result_is_request_only": action == .quit])
        if action.isActable {
            pending.append(Observation(id: id, requestID: correlation, action: action,
                generations: group.members.map { $0.snapshot.generation }, bundleID: group.key, started: Date(),
                memoryBeforeMB: group.totalMemoryMB, cpuBefore: group.cpuPercent, hostBefore: host.usedBytes))
        }
        return result
    }

    public static func processState(expected: ProcessGeneration, current: ProcessGeneration?, definitelyGone: Bool) -> String {
        if definitelyGone { return "exited" }
        guard let current, expected.isKnown else { return "unknown" }
        return expected.sameGeneration(current) ? "running" : "pid_reused"
    }

    public func observe(snapshots: [ProcessSnapshot], host: HostMemory, at now: Date) {
        pending = pending.compactMap { entry in
            var item = entry
            let elapsed = now.timeIntervalSince(item.started)
            guard elapsed >= 5, !item.firstChecked || elapsed >= 30 else { return item }
            let states = item.generations.map { expected -> [String: Any] in
                let current = SystemMonitor.processGeneration(pid: expected.pid)
                let gone = kill(expected.pid, 0) == -1 && errno == ESRCH
                return ["generation": expected.key, "state": Self.processState(expected: expected, current: current, definitelyGone: gone)]
            }
            let matching = snapshots.filter { snapshot in item.generations.contains { $0.sameGeneration(snapshot.generation) } }
            let runningCount = states.filter { $0["state"] as? String == "running" }.count
            let observable = !states.contains { $0["state"] as? String == "unknown" } && matching.count == runningCount
            let memory = matching.reduce(0) { $0 + $1.memoryFootprintMB }
            let cpu = matching.reduce(0) { $0 + $1.cpuPercent }
            DiagnosticLog.shared.record("action_observed", ["action_id": item.id, "request_id": item.requestID,
                "bundle_id": item.bundleID, "action": item.action.rawValue, "elapsed_seconds": elapsed,
                "final_observation": elapsed >= 30, "target_states": states, "all_targets_observable": observable,
                "sampled_target_memory_mb": memory, "sampled_target_cpu_percent": cpu,
                "target_memory_delta_mb": observable ? memory - item.memoryBeforeMB as Any : NSNull(),
                "target_cpu_delta_percent": observable ? cpu - item.cpuBefore as Any : NSNull(),
                "host_used_delta_bytes": host.physicalBytes > 0 ? Double(host.usedBytes) - Double(item.hostBefore) as Any : NSNull(),
                "delta_note": "observation_not_causal_reclaimed_memory_or_new_process_tracking"], at: now)
            item.firstChecked = true
            return elapsed >= 30 ? nil : item
        }
    }

    public func stop() {
        for item in pending {
            DiagnosticLog.shared.record("action_observation_incomplete", ["action_id": item.id, "request_id": item.requestID, "reason": "app_stopping"])
        }
        pending.removeAll()
    }
}
