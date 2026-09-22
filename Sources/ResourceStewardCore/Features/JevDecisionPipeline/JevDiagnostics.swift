import Foundation

public enum JevDiagnostics {
    public static func assessment(_ value: JevAssessment, requestID: String) {
        func urgency(_ value: JevUrgency) -> [String: Any] {
            ["score": value.score, "confidence": value.confidence, "probabilities": value.probabilities]
        }
        DiagnosticLog.shared.record("jev_assessment", [
            "request_id": requestID, "memory_urgency": urgency(value.memory_urgency),
            "cpu_urgency": urgency(value.cpu_urgency),
            "apps": value.apps.mapValues { ["work_related": $0.work_related, "continuous_service": $0.continuous_service] }
        ])
    }

    public static func observation(load: JevLoadState, apps: [JevGrayApp]) -> [String: Any] {
        let selected = JevCandidateSelector.select(load: load, apps: apps)
        let selectedIDs = Set(selected.map(\.bundle_id))
        return ["memory_pressure": load.memory_pressure, "memory_used_ratio": load.memory_used_ratio,
         "memory_pressure_seconds": load.memory_pressure_seconds, "cpu_percent": load.cpu_percent,
         "cpu_pressure_seconds": load.cpu_pressure_seconds, "swap_used_mb": load.swap_used_mb,
         "foreground_bundle_id": load.foreground_bundle_id,
         "apps": apps.map { ["bundle_id": $0.bundle_id, "app_index": $0.index,
                              "memory_mb": $0.memory_mb, "cpu_percent": $0.cpu_percent,
                              "idle_seconds": $0.idle_seconds, "allowed_actions": $0.allowed_actions,
                              "candidate_score": $0.candidate_score, "owns_windows": $0.owns_windows,
                              "process_identity": $0.process_identity ?? "unknown",
                              "selection_reason": selectionReason(app: $0, load: load, selectedIDs: selectedIDs)] as [String: Any] }]
    }

    public static func selectionReason(app: JevGrayApp, load: JevLoadState, selectedIDs: Set<String>) -> String {
        if selectedIDs.contains(app.bundle_id) { return "selected" }
        guard app.idle_seconds.isFinite, app.memory_mb.isFinite, app.cpu_percent.isFinite else { return "invalid_metrics" }
        if app.bundle_id == load.foreground_bundle_id { return "foreground" }
        if app.idle_seconds < 60 { return "idle_under_60_seconds" }
        let memoryReady = ["warning", "critical"].contains(load.memory_pressure) && load.memory_pressure_seconds >= 20
        let cpuReady = load.cpu_percent >= 80 && load.cpu_pressure_seconds >= 30
        if !memoryReady && !cpuReady { return "load_not_sustained_or_normal" }
        if !JevCandidateSelector.select(load: load, apps: [app]).isEmpty { return "outside_top_five" }
        if memoryReady && app.idle_seconds < 300 { return "memory_idle_under_300_seconds" }
        if memoryReady && app.memory_mb < 200 { return "memory_under_200_mb" }
        return "app_cpu_under_20_percent"
    }

    public static func errorCode(_ error: Error) -> String {
        guard let error = error as? JevClientError else { return "unexpected_\((error as NSError).code)" }
        switch error {
        case .missingAPIKey: return "missing_api_key"
        case .invalidURL: return "invalid_url"
        case .httpStatus(let code, _): return "http_\(code)"
        case .timeout: return "timeout"
        case .transport: return "transport_error"
        case .parse(let field): return "parse_" + String(field.prefix(160))
        }
    }
}
