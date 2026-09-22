import Foundation


public final class JevReclaimAdvisor: @unchecked Sendable {
    private let client: any JevClientProtocol
    
    private let stateQueue = DispatchQueue(label: "cc.resourcesteward.jev.advisor")
    
    private var batchInFlight = false
    private let monotonicNow: @Sendable () -> TimeInterval
    private var nextRequestAt: TimeInterval = 0
    private var lastSelectionLogAt: TimeInterval = -.infinity
    private var lastSelectionCode = ""
    private var batchEpoch = UUID()
    private var desiredBatchSignature = ""
    private var lastBatch = JevBatchSnapshot.empty
    private var lastBatchAt = Date.distantPast
    private var onBatchResolved: (@Sendable () -> Void)?
    public static let batchMinInterval: TimeInterval = 20
    public static let batchTTL: TimeInterval = 180
    private var apiKeyProvider: () -> String?
    private var endpoint: URL
    private var model: String
    public var isEnabled: Bool

    public init(
        enabled: Bool = false,
        client: any JevClientProtocol = JevURLSessionClient(),
        apiKeyProvider: @escaping () -> String?,
        baseURLString: String = JevURLSessionClient.defaultBaseURLString,
        model: String = JevURLSessionClient.defaultModel,
        monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.monotonicNow = monotonicNow
        self.isEnabled = enabled
        self.client = client
        self.apiKeyProvider = apiKeyProvider
        self.endpoint = JevURLSessionClient.resolveEndpoint(baseURLString: baseURLString)
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? JevURLSessionClient.defaultModel : trimmed
    }

    public var isActive: Bool {
        isEnabled && apiKeyProvider() != nil
    }

    public func updateAPIKey(_ value: String?) {
        let key = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        invalidateBatch()
        apiKeyProvider = { key?.isEmpty == false ? key : nil }
    }

    public func updateEnabled(_ enabled: Bool) {
        let was = isEnabled
        isEnabled = enabled
        if was != enabled {
            invalidateBatch()
            JevLog.info("enabled_updated enabled=\(enabled)")
        }
    }

    public func updateBaseURL(_ baseURLString: String) {
        let next = JevURLSessionClient.resolveEndpoint(baseURLString: baseURLString)
        if next != endpoint {
            invalidateBatch()
            endpoint = next
            JevLog.info("endpoint_updated")
        } else {
            endpoint = next
        }
    }

    public func updateModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? JevURLSessionClient.defaultModel : trimmed
        if next != self.model {
            invalidateBatch()
            self.model = next
            JevLog.info("model_updated id=\(next)")
        } else {
            self.model = next
        }
    }


    private func withState<T>(_ body: () -> T) -> T {
        stateQueue.sync(execute: body)
    }

    
    
    public func knownBatchActions() -> [String: SuggestedAction] {
        latestBatch().actions
    }

    public func latestBatch() -> JevBatchSnapshot {
        withState {
            guard !lastBatch.pending, lastBatch.signature == desiredBatchSignature,
                  Date().timeIntervalSince(lastBatchAt) < Self.batchTTL else { return .empty }
            return lastBatch
        }
    }

    public func invalidateBatch() {
        withState {
            batchEpoch = UUID()
            lastBatch = .empty
            lastBatchAt = .distantPast
            desiredBatchSignature = ""
        }
    }

    public func setOnBatchResolved(_ handler: (@Sendable () -> Void)?) {
        withState { onBatchResolved = handler }
    }

    
    public func syncBatch(
        load: JevLoadState,
        apps: [JevGrayApp],
        scheduleIfNeeded: Bool = true
    ) -> JevBatchSnapshot {
        guard isActive else {
            logSelection(code: isEnabled ? "missing_api_key" : "disabled", load: load, apps: apps)
            return .empty
        }
        let capped = JevCandidateSelector.select(load: load, apps: apps)
        let signature = JevBatchQuestions.signature(load: load, apps: capped)
        withState {
            if desiredBatchSignature != signature {
                batchEpoch = UUID()
                lastBatch = .empty
                desiredBatchSignature = signature
            }
        }
        guard !capped.isEmpty else {
            let status = JevPipelineStatus.idle(load: load, grayAppCount: apps.count)
            logSelection(code: status.code, load: load, apps: apps)
            JevLog.infoThrottled(key: "selection_\(status.code)", interval: 60,
                "request_skipped reason=\(status.code) gray=\(apps.count) pressure=\(load.memory_pressure) memory_seconds=\(Int(load.memory_pressure_seconds)) cpu_seconds=\(Int(load.cpu_pressure_seconds))")
            return JevBatchSnapshot(signature: signature, status: status)
        }
        let cached = latestBatch()
        if cached.signature == signature, !cached.actions.isEmpty { return cached }
        if scheduleIfNeeded { scheduleBatch(load: load, apps: capped, signature: signature) }
        return withState {
            if lastBatch.signature == signature { return lastBatch }
            return JevBatchSnapshot(signature: signature, status: .requestCooldown)
        }
    }

    private func logSelection(code: String, load: JevLoadState, apps: [JevGrayApp]) {
        let shouldLog = withState {
            let now = monotonicNow()
            guard now - lastSelectionLogAt >= 60 || code != lastSelectionCode else { return false }
            lastSelectionLogAt = now
            lastSelectionCode = code
            return true
        }
        guard shouldLog else { return }
        var fields = JevDiagnostics.observation(load: load, apps: apps)
        fields["reason"] = code
        fields["retry_after_seconds"] = withState { max(0, nextRequestAt - monotonicNow()) }
        fields["network_batch_in_flight"] = withState { batchInFlight }
        DiagnosticLog.shared.record("jev_selection", fields)
    }

    private func scheduleBatch(load: JevLoadState, apps: [JevGrayApp], signature: String) {
        let tooSoon = withState { () -> Bool in
            if batchInFlight { return true }
            if monotonicNow() < nextRequestAt { return true }
            nextRequestAt = monotonicNow() + Self.batchMinInterval
            batchInFlight = true
            lastBatch = JevBatchSnapshot(
                signature: signature,
                pending: true,
                status: .assessing
            )
            return false
        }
        if tooSoon {
            logSelection(code: "request_cooldown", load: load, apps: apps)
            return
        }

        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            withState {
                batchInFlight = false
                lastBatch = JevBatchSnapshot(signature: signature, status: .failed(JevClientError.missingAPIKey.localizedDescription))
                lastBatchAt = Date()
            }
            JevLog.infoThrottled(key: "missing_api_key", interval: 120, "ERROR missing_api_key batch")
            return
        }

        let requestID = UUID().uuidString
        let state = JevBatchRequestState(system: load, apps: apps)
        var diagnostics = JevDiagnostics.observation(load: load, apps: apps)
        diagnostics["request_id"] = requestID
        diagnostics["model"] = model
        DiagnosticLog.shared.record("jev_request_start", diagnostics)
        JevLog.info(
            "request_start request_id=\(requestID) batch apps=\(apps.count) pressure=\(load.memory_pressure) cpu=\(Int(load.cpu_percent)) "
        )

        let epoch = withState { batchEpoch }
        let client = self.client
        let endpoint = self.endpoint
        let model = self.model
        Task.detached { [weak self] in
            guard let self else { return }
            var stage = "assessment"
            var notifyResolved = false
            defer {
                let handler = self.withState {
                    self.batchInFlight = false
                    return self.onBatchResolved
                }
                if notifyResolved { handler?() }
            }
            do {
                let stateJSON = try JSONEncoder().encode(state)
                let questionsJSON = try JSONSerialization.data(
                    withJSONObject: JevAssessmentQuestions.payload(apps: apps)
                )
                let assessmentPayload = try await client.evaluatePayload(
                    stateJSON: stateJSON,
                    questionsJSON: questionsJSON,
                    apiKey: apiKey,
                    requestID: requestID,
                    endpoint: endpoint,
                    model: model
                )
                let assessment = try JevAssessmentQuestions.parse(assessmentPayload.answersJSON, apps: apps)
                DiagnosticLog.shared.record("jev_stage_complete", ["request_id": requestID, "stage": stage,
                    "http_status": assessmentPayload.httpStatus, "latency_ms": assessmentPayload.latencyMs])
                JevDiagnostics.assessment(assessment, requestID: requestID)
                guard self.withState({ () -> Bool in
                    guard self.batchEpoch == epoch && self.desiredBatchSignature == signature else { return false }
                    self.lastBatch.status = .deciding
                    return true
                }) else {
                    DiagnosticLog.shared.record("jev_response_discarded", ["request_id": requestID, "stage": stage, "reason": "context_or_configuration_changed"])
                    return
                }
                JevLog.info("stage_ok request_id=\(requestID) stage=assessment status=\(assessmentPayload.httpStatus) latency_ms=\(assessmentPayload.latencyMs)")
                stage = "decision"
                DiagnosticLog.shared.record("jev_stage_start", ["request_id": requestID, "stage": stage])
                JevLog.info("stage_start request_id=\(requestID)-decision stage=decision")
                let decisionState = JevDecisionState(observations: state, assessment: assessment)
                let payload = try await client.evaluatePayload(
                    stateJSON: JSONEncoder().encode(decisionState),
                    questionsJSON: JSONSerialization.data(withJSONObject: JevActionQuestions.payload(apps: apps)),
                    apiKey: apiKey,
                    requestID: requestID + "-decision",
                    endpoint: endpoint,
                    model: model
                )
                let decision = try JevActionQuestions.parse(payload.answersJSON, apps: apps, assessment: assessment, requestID: requestID)
                let actions = decision.actions
                let accepted = self.withState { () -> Bool in
                    guard self.batchEpoch == epoch, self.desiredBatchSignature == signature else { return false }
                    self.lastBatchAt = Date()
                    self.lastBatch = JevBatchSnapshot(
                        signature: signature,
                        actions: actions,
                        pending: false,
                        requestID: requestID,
                        evidence: decision.evidence
                    )
                    return true
                }
                DiagnosticLog.shared.record("jev_request_complete", ["request_id": requestID, "stage": stage,
                    "accepted": accepted, "http_status": payload.httpStatus, "latency_ms": payload.latencyMs,
                    "reason": accepted ? "current_context" : "context_or_configuration_changed"])
                notifyResolved = accepted
                guard accepted else { return }
                let summary = actions.map { "\($0.key)=\($0.value.rawValue)" }.sorted().joined(separator: ",")
                JevLog.info(
                    "request_ok request_id=\(payload.requestID) batch status=\(payload.httpStatus) latency_ms=\(payload.latencyMs) actions=\(summary)"
                )
            } catch {
                let code = JevDiagnostics.errorCode(error)
                DiagnosticLog.shared.record("jev_request_failed", ["request_id": requestID, "stage": stage, "reason": code])
                let accepted = self.withState { () -> Bool in
                    self.nextRequestAt = max(self.nextRequestAt, self.monotonicNow() + Self.batchMinInterval)
                    guard self.batchEpoch == epoch, self.desiredBatchSignature == signature else { return false }
                    self.lastBatchAt = Date()
                    self.lastBatch = JevBatchSnapshot(signature: signature, pending: false, status: .failed(error.localizedDescription))
                    return true
                }
                notifyResolved = accepted
                guard accepted else { return }
                JevLog.error(
                    "request_fail request_id=\(requestID) batch stage=\(stage) reason=\(code)"
                )
            }
        }
    }
}
