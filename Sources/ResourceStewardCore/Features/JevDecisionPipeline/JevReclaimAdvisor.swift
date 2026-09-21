import Foundation


public final class JevReclaimAdvisor: @unchecked Sendable {
    private let client: any JevClientProtocol
    
    private let stateQueue = DispatchQueue(label: "cc.resourcesteward.jev.advisor")
    
    private var batchInFlight = false
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
        model: String = JevURLSessionClient.defaultModel
    ) {
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
            JevLog.info("endpoint_updated url=\(next.absoluteString)")
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
            batchInFlight = false
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
        guard isActive else { return .empty }
        let capped = JevCandidateSelector.select(load: load, apps: apps)
        let signature = JevBatchQuestions.signature(load: load, apps: capped)
        withState {
            if desiredBatchSignature != signature {
                batchEpoch = UUID()
                batchInFlight = false
                lastBatch = .empty
                desiredBatchSignature = signature
            }
        }
        guard !capped.isEmpty else {
            let status = JevPipelineStatus.idle(load: load, grayAppCount: apps.count)
            JevLog.infoThrottled(key: "selection_\(status.code)", interval: 60,
                "request_skipped reason=\(status.code) gray=\(apps.count) pressure=\(load.memory_pressure) memory_seconds=\(Int(load.memory_pressure_seconds)) cpu_seconds=\(Int(load.cpu_pressure_seconds))")
            return JevBatchSnapshot(signature: signature, status: status)
        }
        let cached = latestBatch()
        if cached.signature == signature, !cached.actions.isEmpty { return cached }
        if scheduleIfNeeded { scheduleBatch(load: load, apps: capped, signature: signature) }
        return withState {
            if lastBatch.signature == signature { return lastBatch }
            return JevBatchSnapshot(signature: signature, pending: true, status: .assessing)
        }
    }

    private func scheduleBatch(load: JevLoadState, apps: [JevGrayApp], signature: String) {
        let tooSoon = withState { () -> Bool in
            if batchInFlight { return true }
            if Date().timeIntervalSince(lastBatchAt) < Self.batchMinInterval,
               lastBatch.signature == signature {
                return true
            }
            batchInFlight = true
            lastBatch = JevBatchSnapshot(
                signature: signature,
                pending: true,
                status: .assessing
            )
            return false
        }
        if tooSoon { return }

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
        JevLog.info(
            "request_start request_id=\(requestID) batch apps=\(apps.count) pressure=\(load.memory_pressure) cpu=\(Int(load.cpu_percent)) signature=\(signature)"
        )

        let epoch = withState { batchEpoch }
        let client = self.client
        let endpoint = self.endpoint
        let model = self.model
        Task.detached { [weak self] in
            guard let self else { return }
            var stage = "assessment"
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
                guard self.withState({ () -> Bool in
                    guard self.batchEpoch == epoch && self.desiredBatchSignature == signature else { return false }
                    self.lastBatch.status = .deciding
                    return true
                }) else { return }
                JevLog.info("stage_ok request_id=\(requestID) stage=assessment status=\(assessmentPayload.httpStatus) latency_ms=\(assessmentPayload.latencyMs)")
                stage = "decision"
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
                let decision = try JevActionQuestions.parse(payload.answersJSON, apps: apps, assessment: assessment)
                let actions = decision.actions
                let accepted = self.withState { () -> Bool in
                    guard self.batchEpoch == epoch, self.desiredBatchSignature == signature else { return false }
                    self.batchInFlight = false
                    self.lastBatchAt = Date()
                    self.lastBatch = JevBatchSnapshot(
                        signature: signature,
                        actions: actions,
                        pending: false,
                        requestID: payload.requestID,
                        evidence: decision.evidence
                    )
                    return true
                }
                guard accepted else { return }
                let summary = actions.map { "\($0.key)=\($0.value.rawValue)" }.sorted().joined(separator: ",")
                JevLog.info(
                    "request_ok request_id=\(payload.requestID) batch status=\(payload.httpStatus) latency_ms=\(payload.latencyMs) actions=\(summary)"
                )
                let handler = self.withState { self.onBatchResolved }
                handler?()
            } catch {
                let accepted = self.withState { () -> Bool in
                    guard self.batchEpoch == epoch, self.desiredBatchSignature == signature else { return false }
                    self.batchInFlight = false
                    self.lastBatchAt = Date()
                    self.lastBatch = JevBatchSnapshot(signature: signature, pending: false, status: .failed(error.localizedDescription))
                    return true
                }
                guard accepted else { return }
                JevLog.error(
                    "request_fail request_id=\(requestID) batch stage=\(stage) message=\(error.localizedDescription)"
                )
                let handler = self.withState { self.onBatchResolved }
                handler?()
            }
        }
    }
}
