import Foundation
import ResourceStewardCore

enum JevSequencingChecks {
    static func run() throws -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ value: Bool) {
            print("\(value ? "ok  " : "FAIL") \(name)")
            if !value { failures.append(name) }
        }
        let client = SequencedJevClient()
        let advisor = JevReclaimAdvisor(enabled: true, client: client, apiKeyProvider: { "test" })
        let completed = DispatchSemaphore(value: 0)
        advisor.setOnBatchResolved { completed.signal() }
        var load = JevLoadState(memory_pressure: "critical", cpu_percent: 10, memory_used_ratio: 0.95, swap_used_mb: 100, memory_pressure_seconds: 25)
        let app = JevGrayApp(index: 0, bundle_id: "com.example.reader", name: "Reader", idle_seconds: 900, memory_mb: 800, cpu_percent: 0, owns_windows: true, process_identity: "10:20")
        _ = advisor.syncBatch(load: load, apps: [app])
        check("stage one starts first", client.started.wait(timeout: .now() + 2) == .success && client.count == 1)
        check("assessment alone has no executable actions", advisor.latestBatch().actions.isEmpty)
        client.resolve(0, data: try JevPipelineChecks.assessmentData())
        check("stage two starts after assessment", client.started.wait(timeout: .now() + 2) == .success && client.count == 2)
        let request = client.request(1)
        let state = try JSONSerialization.jsonObject(with: request.0) as! [String: Any]
        let facts = state["assessment"] as? [String: Any]
        let apps = facts?["apps"] as? [String: Any]
        let assessment = apps?[app.bundle_id] as? [String: Any]
        check("actual second request carries first answers", assessment?["work_related"] as? Double == 0.1)
        let questions = try JSONSerialization.jsonObject(with: request.1) as! [String: Any]
        let criteria = (questions["app_0"] as? [String: Any])?["criteria"] as? [String: Any]
        check("second request restricts actual choices", Set(criteria?.keys.map { $0 } ?? []) == Set(["keep", "quit"]))
        client.resolve(1, data: Data(#"{"app_0":{"type":"choice","choice":"quit","confidence":0.99}}"#.utf8))
        check("second stage publishes final evidence", completed.wait(timeout: .now() + 2) == .success && advisor.latestBatch().actions[app.bundle_id] == .quit && advisor.latestBatch().evidence[app.bundle_id] != nil)
        load.foreground_bundle_id = "com.example.editor"
        _ = advisor.syncBatch(load: load, apps: [app])
        check("changed context starts new assessment", client.started.wait(timeout: .now() + 2) == .success)
        advisor.updateEnabled(false)
        client.resolve(2, data: try JevPipelineChecks.assessmentData())
        check("invalidated assessment never starts decision", client.started.wait(timeout: .now() + 0.15) == .timedOut && advisor.latestBatch().actions.isEmpty)
        advisor.updateEnabled(true)
        _ = advisor.syncBatch(load: load, apps: [app])
        check("assessment retries after reenable", client.started.wait(timeout: .now() + 2) == .success)
        client.resolve(3, data: Data("{}".utf8))
        check("malformed assessment fails closed", completed.wait(timeout: .now() + 2) == .success && advisor.latestBatch().actions.isEmpty && client.count == 4)
        _ = advisor.syncBatch(load: load, apps: [app])
        check("failed request obeys retry cooldown", client.started.wait(timeout: .now() + 0.15) == .timedOut)
        load.memory_pressure = "normal"
        load.cpu_percent = 0
        _ = advisor.syncBatch(load: load, apps: [app])
        check("pressure recovery clears all advice", advisor.latestBatch().actions.isEmpty && client.count == 4)
        return failures
    }
}

private final class SequencedJevClient: JevClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(Data, Data, String)] = []
    private var replies: [Int: CheckedContinuation<JevPayloadResult, Error>] = [:]
    let started = DispatchSemaphore(value: 0)

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func request(_ index: Int) -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (requests[index].0, requests[index].1)
    }

    func evaluatePayload(stateJSON: Data, questionsJSON: Data, apiKey: String, requestID: String, endpoint: URL, model: String) async throws -> JevPayloadResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            replies[requests.count] = continuation
            requests.append((stateJSON, questionsJSON, requestID))
            lock.unlock()
            started.signal()
        }
    }

    func resolve(_ index: Int, data: Data) {
        lock.lock()
        let continuation = replies.removeValue(forKey: index)
        let id = requests[index].2
        lock.unlock()
        continuation?.resume(returning: JevPayloadResult(requestID: id, model: "test", answersJSON: data, httpStatus: 200, latencyMs: 1))
    }
}
