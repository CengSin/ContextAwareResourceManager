import Foundation
import ResourceStewardCore

enum ResourceDiagnosticsChecks {
    static func run() throws -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ value: Bool) {
            print("\(value ? "ok  " : "FAIL") \(name)")
            if !value { failures.append(name) }
        }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory, maxBytes: 1024, archives: 2)
        for index in 0..<60 { log.record("rotation_test", ["index": index, "text": "line\nbreak"]) }
        log.flush()
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        check("diagnostic rotation bounds total files", files.count == 3)
        var total = 0
        var rows: [[String: Any]] = []
        for url in files {
            let data = try Data(contentsOf: url)
            total += data.count
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                rows.append(try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])
            }
        }
        check("diagnostic rotation bounds bytes", total <= 3072)
        check("diagnostic lines retain latest record and schema", rows.contains { $0["index"] as? Int == 59 && $0["schema"] as? Int == 1 && $0["session_id"] != nil })
        check("diagnostic JSON escapes newline", rows.allSatisfy { $0["text"] as? String == "line\nbreak" })
        let permissions = try fm.attributesOfItem(atPath: directory.appendingPathComponent("events.jsonl").path)[.posixPermissions] as? NSNumber
        check("diagnostic files private to owner", permissions?.intValue == 0o600)
        let beforeDisabled = try Data(contentsOf: directory.appendingPathComponent("events.jsonl"))
        log.configure(enabled: false)
        log.record("should_not_write")
        log.flush()
        check("disabled file logging writes nothing", try Data(contentsOf: directory.appendingPathComponent("events.jsonl")) == beforeDisabled)
        for url in files { try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86400)], ofItemAtPath: url.path) }
        let restarted = DiagnosticLog(directory: directory)
        restarted.record("after_retention")
        restarted.flush()
        check("old diagnostic archives expire on next write", try fm.contentsOfDirectory(atPath: directory.path) == ["events.jsonl"])

        let evidenceDir = directory.appendingPathComponent("evidence")
        let evidenceLog = DiagnosticLog(directory: evidenceDir)
        let app = JevGrayApp(index: 0, bundle_id: "com.example.reader", name: "Do not log this secret title", idle_seconds: 600, memory_mb: 800, cpu_percent: 0, owns_windows: true, allowed_actions: ["keep", "quit"])
        let assessment = try JevAssessmentQuestions.parse(JevPipelineChecks.assessmentData(), apps: [app])
        let low = Data(#"{"app_0":{"type":"choice","choice":"quit","confidence":0.8}}"#.utf8)
        let kept = try JevActionQuestions.parse(low, apps: [app], assessment: assessment, requestID: "correlation", diagnostics: evidenceLog)
        check("low confidence quit preserves safe behavior", kept.actions[app.bundle_id] == SuggestedAction.none)
        _ = try JevActionQuestions.parse(Data(#"{"app_0":{"type":"choice","choice":"keep","confidence":0.9}}"#.utf8), apps: [app], assessment: assessment, requestID: "keep", diagnostics: evidenceLog)
        _ = try JevActionQuestions.parse(Data(#"{"app_0":{"type":"choice","choice":"SECRET_INVALID_RESPONSE","confidence":"bad"}}"#.utf8), apps: [app], assessment: assessment, requestID: "invalid", diagnostics: evidenceLog)
        evidenceLog.flush()
        let evidenceText = try String(contentsOf: evidenceDir.appendingPathComponent("events.jsonl"), encoding: .utf8)
        check("evidence distinguishes keep veto and malformed choice", evidenceText.contains("model_keep") && evidenceText.contains("quit_confidence_below_threshold") && evidenceText.contains("invalid_or_missing_choice"))
        check("evidence carries request correlation and actual choice", evidenceText.contains("correlation") && evidenceText.contains("\"model_choice\":\"quit\""))
        check("evidence omits app names and untrusted response text", !evidenceText.contains("SECRET") && !evidenceText.contains("secret title"))

        let history = ResourceHistory(log: evidenceLog)
        let load = JevLoadState(memory_pressure: "normal", cpu_percent: 10, memory_used_ratio: 0, swap_used_mb: 0)
        let base = Date()
        for offset in [0.0, 10, 29, 30] {
            history.sample(host: .empty, cpu: .empty, gpu: .unavailable, source: .normal, load: load, snapshots: [], groups: [], favorites: [], authorization: 0, jevActive: false, at: base.addingTimeInterval(offset))
        }
        history.sample(host: .empty, cpu: .empty, gpu: .unavailable, source: .warning, load: load, snapshots: [], groups: [], favorites: [], authorization: 0, jevActive: false, at: base.addingTimeInterval(31))
        evidenceLog.flush()
        let historyRows = try String(contentsOf: evidenceDir.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }.filter { $0["event"] as? String == "resource_sample" }
        check("history records every 30 seconds and pressure transitions", historyRows.count == 3)
        check("unavailable GPU remains null instead of zero", historyRows.allSatisfy { $0["gpu_memory_used_bytes"] is NSNull && $0["gpu_percent"] is NSNull })
        check("history includes authorization and pressure provenance", historyRows.last?["authorization_level"] as? Int == 0 && historyRows.last?["os_pressure_event"] as? String == "warning")
        let partialGPU = HostGPU(usagePercent: 40, memoryTotalBytes: 1024, available: true, memoryUsedAvailable: false)
        check("missing GPU memory counter stays null even with utilization", ResourceHistory.hostFields(host: .empty, cpu: .empty, gpu: partialGPU)["gpu_memory_used_bytes"] is NSNull)
        let generation = ProcessGeneration(pid: 123, startUnix: 100)
        check("action observation distinguishes running from exited", ActionDiagnostics.processState(expected: generation, current: generation, definitelyGone: false) == "running" && ActionDiagnostics.processState(expected: generation, current: nil, definitelyGone: true) == "exited")
        check("action observation never treats unreadable PID as exited", ActionDiagnostics.processState(expected: generation, current: nil, definitelyGone: false) == "unknown")
        check("action observation detects PID reuse", ActionDiagnostics.processState(expected: generation, current: ProcessGeneration(pid: 123, startUnix: 200), definitelyGone: false) == "pid_reused")
        return failures
    }
}
