import Foundation
import ResourceStewardCore

enum JevPipelineChecks {
    static func assessmentData(work: Double = 0.1, service: Double = 0.1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "memory_urgency": ["type": "score", "score": 3, "confidence": 1, "probabilities": ["0": 0, "1": 0, "2": 0, "3": 1]],
            "cpu_urgency": ["type": "score", "score": 2, "confidence": 1, "probabilities": ["0": 0, "1": 0, "2": 1, "3": 0]],
            "app_0_work_related": ["type": "noul", "noul": work],
            "app_0_continuous_service": ["type": "noul", "noul": service]
        ])
    }

    static func run() throws -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ value: Bool) {
            print("\(value ? "ok  " : "FAIL") \(name)")
            if !value { failures.append(name) }
        }
        var load = JevLoadState(memory_pressure: "warning", cpu_percent: 90, memory_used_ratio: 0.9, swap_used_mb: 500)
        var app = JevGrayApp(index: 0, bundle_id: "com.example.reader", name: "Reader", idle_seconds: 900, memory_mb: 800, cpu_percent: 30, owns_windows: true, process_identity: "1:2")
        var window = JevLoadWindow()
        let start = Date(timeIntervalSince1970: 100)
        load = window.observe(load, at: start)
        check("spikes do not create candidates", JevCandidateSelector.select(load: load, apps: [app]).isEmpty)
        load = window.observe(load, at: start.addingTimeInterval(20))
        var selected = JevCandidateSelector.select(load: load, apps: [app])
        check("sustained memory permits quit only", selected.first?.allowed_actions == ["keep", "quit"])
        load = window.observe(load, at: start.addingTimeInterval(30))
        selected = JevCandidateSelector.select(load: load, apps: [app])
        check("sustained CPU independently permits throttle", selected.first?.allowed_actions.contains("throttle") == true)
        var cpuOnly = load
        cpuOnly.memory_pressure = "normal"
        check("CPU only cannot propose quit", JevCandidateSelector.select(load: cpuOnly, apps: [app]).first?.allowed_actions == ["keep", "throttle"])
        var normal = cpuOnly
        normal.cpu_percent = 10
        check("normal load never proposes actions", JevCandidateSelector.select(load: normal, apps: [app]).isEmpty)
        app.idle_seconds = 10
        check("recent interaction protects candidates", JevCandidateSelector.select(load: load, apps: [app]).isEmpty)
        app.idle_seconds = 900
        var foreground = load
        foreground.foreground_bundle_id = app.bundle_id
        check("foreground excluded by candidate selector", JevCandidateSelector.select(load: foreground, apps: [app]).isEmpty)
        let gap = window.observe(load, at: start.addingTimeInterval(90))
        check("sampling gaps reset pressure evidence", gap.memory_pressure_seconds == 0 && gap.cpu_pressure_seconds == 0)
        let many = (0..<10).map { index -> JevGrayApp in
            var item = app
            item.bundle_id = "com.example.\(index)"
            item.memory_mb = Double(index + 1) * 200
            return item
        }
        check("candidate cap is five", JevCandidateSelector.select(load: load, apps: many).count == 5)
        let candidates = JevCandidateSelector.select(load: load, apps: [app])
        let assessment = try JevAssessmentQuestions.parse(assessmentData(), apps: candidates)
        let questions = JevAssessmentQuestions.payload(apps: candidates)
        check("assessment has two scores and two nouls", questions.count == 4 && (questions["memory_urgency"] as? [String: Any])?["type"] as? String == "score")
        let decisionState = JevDecisionState(observations: JevBatchRequestState(system: load, apps: candidates), assessment: assessment)
        let state = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decisionState)) as! [String: Any]
        check("second stage state includes actual assessment", state["assessment"] is [String: Any] && state["observations"] is [String: Any])
        func action(_ choice: String, confidence: Double, facts: JevAssessment? = nil) throws -> SuggestedAction? {
            let data = try JSONSerialization.data(withJSONObject: ["app_0": ["type": "choice", "choice": choice, "confidence": confidence]])
            return try JevActionQuestions.parse(data, apps: candidates, assessment: facts ?? assessment).actions[app.bundle_id]
        }
        check("confident eligible quit survives", try action("quit", confidence: 0.95) == .quit)
        check("uncertain quit stays keep, never throttle", try action("quit", confidence: 0.8) == SuggestedAction.none)
        check("freeze is refused", try action("freeze", confidence: 1) == SuggestedAction.none)
        let uncertain = try JevAssessmentQuestions.parse(assessmentData(work: 0.5), apps: candidates)
        check("uncertain relevance prevents action", try action("quit", confidence: 0.99, facts: uncertain) == SuggestedAction.none)
        let service = try JevAssessmentQuestions.parse(assessmentData(service: 0.9), apps: candidates)
        check("background service vetoes action", try action("throttle", confidence: 0.99, facts: service) == SuggestedAction.none)
        var lowUrgency = assessment
        lowUrgency.memory_urgency.score = 1
        check("low memory urgency vetoes quit", try action("quit", confidence: 0.99, facts: lowUrgency) == SuggestedAction.none)
        let memoryOnly = JevCandidateSelector.select(load: gapWithMemory(load), apps: [app])
        let throttle = Data(#"{"app_0":{"type":"choice","choice":"throttle","confidence":1}}"#.utf8)
        check("model cannot exceed allowed actions", try JevActionQuestions.parse(throttle, apps: memoryOnly, assessment: assessment).actions[app.bundle_id] == SuggestedAction.none)
        for invalid in [Data("{}".utf8), try assessmentData(work: 2)] {
            do {
                _ = try JevAssessmentQuestions.parse(invalid, apps: candidates)
                check("malformed assessment refused", false)
            } catch { check("malformed assessment refused", true) }
        }
        for raw: Any in [true, "0.99", Double.infinity, -0.1] {
            do {
                _ = try JevAnswerValidation.number(raw, in: 0...1)
                check("invalid number refused", false)
            } catch { check("invalid number refused", true) }
        }
        check("missing choice defaults keep", try JevActionQuestions.parse(Data("{}".utf8), apps: candidates, assessment: assessment).actions[app.bundle_id] == SuggestedAction.none)
        let parsed = try JevActionQuestions.parse(Data(#"{"app_0":{"type":"choice","choice":"quit","confidence":0.99}}"#.utf8), apps: candidates, assessment: assessment)
        check("display evidence preserves observation", parsed.evidence[app.bundle_id]?.memoryMB == 800 && parsed.evidence[app.bundle_id]?.assessment.work_related == 0.1)
        return failures
    }

    private static func gapWithMemory(_ load: JevLoadState) -> JevLoadState {
        var result = load
        result.cpu_pressure_seconds = 0
        return result
    }
}
