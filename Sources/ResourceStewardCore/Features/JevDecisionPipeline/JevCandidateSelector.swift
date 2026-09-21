import Foundation

public struct JevLoadWindow {
    private var memorySince: Date?
    private var cpuSince: Date?
    private var lastSample: Date?

    public init() {}

    public mutating func observe(_ load: JevLoadState, at now: Date = Date()) -> JevLoadState {
        if let lastSample, now.timeIntervalSince(lastSample) > 30 || now < lastSample {
            memorySince = nil
            cpuSince = nil
        }
        lastSample = now
        let memoryHigh = load.memory_pressure == "warning" || load.memory_pressure == "critical"
        memorySince = memoryHigh ? (memorySince ?? now) : nil
        cpuSince = load.cpu_percent >= 80 ? (cpuSince ?? now) : nil
        var observed = load
        observed.memory_pressure_seconds = memorySince.map { now.timeIntervalSince($0) } ?? 0
        observed.cpu_pressure_seconds = cpuSince.map { now.timeIntervalSince($0) } ?? 0
        return observed
    }
}

public enum JevCandidateSelector {
    public static func select(load: JevLoadState, apps: [JevGrayApp]) -> [JevGrayApp] {
        let memoryHigh = ["warning", "critical"].contains(load.memory_pressure) && load.memory_pressure_seconds >= 20
        let cpuHigh = load.cpu_percent >= 80 && load.cpu_pressure_seconds >= 30
        guard memoryHigh || cpuHigh else { return [] }
        return apps.compactMap { source -> JevGrayApp? in
            guard source.idle_seconds.isFinite, source.memory_mb.isFinite, source.cpu_percent.isFinite,
                  source.idle_seconds >= 60, source.bundle_id != load.foreground_bundle_id else { return nil }
            var app = source
            app.allowed_actions = ["keep"]
            var memoryScore = 0.0
            var cpuScore = 0.0
            if memoryHigh, app.idle_seconds >= 300, app.memory_mb >= 200 {
                app.allowed_actions.append("quit")
                memoryScore = min(app.memory_mb / 2048, 1) * min(app.idle_seconds / 1800, 1)
            }
            if cpuHigh, app.cpu_percent >= 20 {
                app.allowed_actions.append("throttle")
                cpuScore = min(app.cpu_percent / 100, 1) * min(app.idle_seconds / 300, 1)
            }
            guard app.allowed_actions.count > 1 else { return nil }
            app.candidate_score = max(memoryScore, cpuScore)
            return app
        }.sorted {
            $0.candidate_score == $1.candidate_score ? $0.bundle_id < $1.bundle_id : $0.candidate_score > $1.candidate_score
        }.prefix(JevBatchQuestions.maxApps).enumerated().map { index, source in
            var app = source
            app.index = index
            return app
        }
    }
}
