import Foundation


public final class JevReclaimAdvisor: @unchecked Sendable {
    public struct Decision: Sendable, Equatable {
        public var action: SuggestedAction
        public var fromCache: Bool
        public var pending: Bool
        public var rule: JevComposeRule?
        public var requestID: String?

        public init(
            action: SuggestedAction,
            fromCache: Bool = false,
            pending: Bool = false,
            rule: JevComposeRule? = nil,
            requestID: String? = nil
        ) {
            self.action = action
            self.fromCache = fromCache
            self.pending = pending
            self.rule = rule
            self.requestID = requestID
        }
    }

    private let client: any JevClientProtocol
    private let cache: JevCache
    
    private let stateQueue = DispatchQueue(label: "cc.resourcesteward.jev.advisor")
    private var inFlight: Set<String> = []
    
    private var decisions: [String: Decision] = [:]
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
        cache: JevCache = JevCache(),
        apiKeyProvider: @escaping () -> String? = { JevAPIKey.loadAPIKey() },
        baseURLString: String = JevURLSessionClient.defaultBaseURLString,
        model: String = JevQuestions.defaultModel
    ) {
        self.isEnabled = enabled
        self.client = client
        self.cache = cache
        self.apiKeyProvider = apiKeyProvider
        self.endpoint = JevURLSessionClient.resolveEndpoint(baseURLString: baseURLString)
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? JevQuestions.defaultModel : trimmed
    }

    public var isActive: Bool {
        isEnabled && apiKeyProvider() != nil
    }

    public func updateEnabled(_ enabled: Bool) {
        let was = isEnabled
        isEnabled = enabled
        if was != enabled {
            invalidateBatch()
            let source = JevAPIKey.load().source.rawValue
            JevLog.info("enabled_updated enabled=\(enabled) api_key_source=\(source)")
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
        let next = trimmed.isEmpty ? JevQuestions.defaultModel : trimmed
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

    
    
    public func adjustSuggestion(
        scorerAction: SuggestedAction,
        candidate: JevHardGate.Candidate,
        pressure: MemoryPressureLevel,
        idleSeconds: Double,
        memoryMB: Double,
        cpuPercent: Double,
        authorization: AuthorizationLevel,
        alreadyFrozen: Bool,
        scheduleIfNeeded: Bool = true
    ) -> SuggestedAction {
        guard isActive else { return scorerAction }
        if let (reason, detail) = JevHardGate.skipReason(for: candidate) {
            JevLog.infoOnce(
                key: "hard_gate:\(candidate.bundleID):\(reason.rawValue)",
                "skip hard_gate=\(reason.rawValue) detail=\(detail) bundle=\(candidate.bundleID)"
            )
            return scorerAction
        }
        guard scorerAction != .none || scheduleIfNeeded else { return scorerAction }

        let pressureBucket = pressure.rawValue
        if let cached = cache.lookup(
            bundleID: candidate.bundleID,
            pressureBucket: pressureBucket,
            idleSeconds: idleSeconds,
            memoryMB: memoryMB
        ), cached.actionFresh {
            let answers = cached.entry.answers.toAnswers()
            let composed = JevComposer.compose(answers)
            let action = finalize(composed.action, candidate: candidate, rule: composed.rule)
            let decision = Decision(
                action: action,
                fromCache: true,
                pending: false,
                rule: action == composed.action ? composed.rule : .actionCeiling,
                requestID: cached.entry.requestID
            )
            withState { decisions[candidate.bundleID] = decision }
            JevLog.infoThrottled(
                key: "cache_hit:\(candidate.bundleID)",
                interval: 300,
                "cache_hit bundle=\(candidate.bundleID) request_id=\(cached.entry.requestID) action=\(action.rawValue) rule=\(decision.rule?.rawValue ?? composed.rule.rawValue)"
            )
            return action
        }

        let (existing, pending) = withState {
            (decisions[candidate.bundleID], inFlight.contains(candidate.bundleID))
        }

        if let existing, !existing.pending {
            return finalize(existing.action, candidate: candidate, rule: existing.rule)
        }

        if scheduleIfNeeded {
            scheduleEvaluation(
                candidate: candidate,
                pressure: pressure,
                idleSeconds: idleSeconds,
                memoryMB: memoryMB,
                cpuPercent: cpuPercent,
                authorization: authorization,
                alreadyFrozen: alreadyFrozen
            )
        }

        if pending || existing?.pending == true {
            return scorerAction
        }
        return scorerAction
    }

    
    public func decisionForAuto(
        candidate: JevHardGate.Candidate,
        pressure: MemoryPressureLevel,
        idleSeconds: Double,
        memoryMB: Double,
        cpuPercent: Double,
        authorization: AuthorizationLevel,
        alreadyFrozen: Bool,
        scorerAction: SuggestedAction
    ) -> SuggestedAction {
        guard isActive else { return scorerAction }
        if let (reason, detail) = JevHardGate.skipReason(for: candidate) {
            
            JevLog.debug("auto_skip hard_gate=\(reason.rawValue) detail=\(detail) bundle=\(candidate.bundleID)")
            return .none
        }

        let adjusted = adjustSuggestion(
            scorerAction: scorerAction,
            candidate: candidate,
            pressure: pressure,
            idleSeconds: idleSeconds,
            memoryMB: memoryMB,
            cpuPercent: cpuPercent,
            authorization: authorization,
            alreadyFrozen: alreadyFrozen,
            scheduleIfNeeded: true
        )

        let (decision, pending) = withState {
            let decision = decisions[candidate.bundleID]
            let pending = inFlight.contains(candidate.bundleID) || decision?.pending == true
            return (decision, pending)
        }

        if pending {
            JevLog.infoThrottled(
                key: "auto_pending:\(candidate.bundleID)",
                "auto_fail_closed pending bundle=\(candidate.bundleID)"
            )
            return .none
        }
        if decision == nil,
           cache.lookup(
               bundleID: candidate.bundleID,
               pressureBucket: pressure.rawValue,
               idleSeconds: idleSeconds,
               memoryMB: memoryMB
           )?.actionFresh != true {
            JevLog.infoThrottled(
                key: "auto_none:\(candidate.bundleID)",
                "auto_fail_closed no_decision bundle=\(candidate.bundleID)"
            )
            return .none
        }
        return finalize(adjusted, candidate: candidate, rule: decision?.rule)
    }

    public func knownDecision(bundleID: String) -> Decision? {
        withState { decisions[bundleID] }
    }

    private func scheduleEvaluation(
        candidate: JevHardGate.Candidate,
        pressure: MemoryPressureLevel,
        idleSeconds: Double,
        memoryMB: Double,
        cpuPercent: Double,
        authorization: AuthorizationLevel,
        alreadyFrozen: Bool
    ) {
        let key = candidate.bundleID
        guard !key.isEmpty else { return }
        let alreadyFlying = withState { () -> Bool in
            if inFlight.contains(key) { return true }
            inFlight.insert(key)
            decisions[key] = Decision(action: .none, pending: true)
            return false
        }
        if alreadyFlying { return }

        guard let apiKey = apiKeyProvider() else {
            withState {
                inFlight.remove(key)
                decisions[key] = Decision(action: .none, pending: false)
            }
            JevLog.infoThrottled(
                key: "missing_api_key",
                interval: 120,
                "ERROR missing_api_key bundle=\(key)"
            )
            return
        }

        let requestID = UUID().uuidString
        let state = JevRequestState(
            app: JevAppState(
                bundle_id: candidate.bundleID,
                name: candidate.processName,
                is_regular_app: candidate.isRegularApp,
                is_accessory: candidate.isAccessory,
                owns_windows: candidate.ownsWindows,
                idle_seconds: idleSeconds,
                memory_mb: memoryMB,
                cpu_percent_recent: cpuPercent,
                in_current_workspace: candidate.inCurrentWorkspace,
                already_frozen: alreadyFrozen,
                english_name_hint: englishHint(bundleID: candidate.bundleID, name: candidate.processName)
            ),
            system: JevSystemState(
                memory_pressure: pressureBucketName(pressure),
                authorization_level: authorization == .sceneSwitch ? "scene_switch" : "suggest_only"
            ),
            policy_hint: .init(hard_gates_passed: true)
        )

        JevLog.info(
            "request_start request_id=\(requestID) bundle=\(key) endpoint=\(self.endpoint.absoluteString) model=\(self.model) cache_hit=false state=\(state.app.truncatedSummary) pressure=\(pressure.rawValue)"
        )

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.evaluate(state: state, apiKey: apiKey, requestID: requestID, endpoint: self.endpoint, model: self.model)
                let composed = JevComposer.compose(result.answers)
                let action = self.finalize(composed.action, candidate: candidate, rule: composed.rule)
                var stored = composed
                if action != composed.action {
                    stored = JevComposeResult(
                        action: action,
                        rule: .actionCeiling,
                        risk: composed.risk,
                        needsSoon: composed.needsSoon,
                        safeToReclaim: composed.safeToReclaim,
                        preferredConfidence: composed.preferredConfidence,
                        preferredChoice: composed.preferredChoice
                    )
                }
                self.cache.store(
                    bundleID: key,
                    pressureBucket: pressure.rawValue,
                    idleSeconds: idleSeconds,
                    memoryMB: memoryMB,
                    answers: result.answers,
                    composed: stored,
                    model: result.model,
                    requestID: result.requestID
                )
                self.withState {
                    self.inFlight.remove(key)
                    self.decisions[key] = Decision(
                        action: action,
                        fromCache: false,
                        pending: false,
                        rule: stored.rule,
                        requestID: result.requestID
                    )
                }
                let tokens = "in=\(result.usage.inputTokens.map(String.init) ?? "?") out=\(result.usage.outputTokens.map(String.init) ?? "?")"
                JevLog.info(
                    "request_ok request_id=\(result.requestID) bundle=\(key) status=\(result.httpStatus) latency_ms=\(result.latencyMs) usage=\(tokens) noul_network=\(fmt(result.answers.looksLikeNetworkOrSync)) noul_comm=\(fmt(result.answers.looksLikeCommunication)) noul_input=\(fmt(result.answers.looksLikeInputOrA11y)) noul_av=\(fmt(result.answers.looksLikeAVOrCapture)) noul_needs=\(fmt(result.answers.userLikelyNeedsSoon)) noul_safe=\(fmt(result.answers.safeToReclaimIdle)) choice=\(result.answers.preferredAction.choice) conf=\(fmt(result.answers.preferredAction.confidence)) composed=\(composed.action.rawValue) action=\(action.rawValue) rule=\(stored.rule.rawValue)"
                )
            } catch let error as JevClientError {
                self.withState {
                    self.inFlight.remove(key)
                    self.decisions[key] = Decision(action: .none, pending: false)
                }
                JevLog.error(
                    "request_fail request_id=\(requestID) bundle=\(key) recoverable=\(error.isRecoverable) message=\(error.localizedDescription)"
                )
            } catch {
                self.withState {
                    self.inFlight.remove(key)
                    self.decisions[key] = Decision(action: .none, pending: false)
                }
                JevLog.error(
                    "request_fail request_id=\(requestID) bundle=\(key) recoverable=true message=\(error.localizedDescription)"
                )
            }
        }
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
        let capped = JevBatchQuestions.capped(apps)
        let signature = JevBatchQuestions.signature(load: load, apps: capped)
        withState {
            if desiredBatchSignature != signature {
                batchEpoch = UUID()
                batchInFlight = false
                lastBatch = .empty
                desiredBatchSignature = signature
            }
        }
        guard !capped.isEmpty else { return .empty }
        let cached = latestBatch()
        if cached.signature == signature, !cached.actions.isEmpty { return cached }
        if scheduleIfNeeded { scheduleBatch(load: load, apps: capped, signature: signature) }
        return JevBatchSnapshot(signature: signature, pending: true)
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
                pending: true
            )
            return false
        }
        if tooSoon { return }

        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            withState {
                batchInFlight = false
                lastBatch = JevBatchSnapshot(signature: signature)
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
            do {
                let stateJSON = try JSONEncoder().encode(state)
                let questionsJSON = try JSONSerialization.data(
                    withJSONObject: JevBatchQuestions.payload(appCount: apps.count)
                )
                let payload = try await client.evaluatePayload(
                    stateJSON: stateJSON,
                    questionsJSON: questionsJSON,
                    apiKey: apiKey,
                    requestID: requestID,
                    endpoint: endpoint,
                    model: model
                )
                let actions = try JevBatchQuestions.parseJSON(payload.answersJSON, apps: apps)
                let accepted = self.withState { () -> Bool in
                    guard self.batchEpoch == epoch, self.desiredBatchSignature == signature else { return false }
                    self.batchInFlight = false
                    self.lastBatchAt = Date()
                    self.lastBatch = JevBatchSnapshot(
                        signature: signature,
                        actions: actions,
                        pending: false,
                        requestID: payload.requestID
                    )
                    for (bundle, action) in actions {
                        self.decisions[bundle] = Decision(
                            action: action,
                            fromCache: false,
                            pending: false,
                            rule: .choice,
                            requestID: payload.requestID
                        )
                    }
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
                    self.lastBatch = JevBatchSnapshot(signature: signature, pending: false)
                    return true
                }
                guard accepted else { return }
                JevLog.error(
                    "request_fail request_id=\(requestID) batch message=\(error.localizedDescription)"
                )
                let handler = self.withState { self.onBatchResolved }
                handler?()
            }
        }
    }

    
    private func finalize(
        _ action: SuggestedAction,
        candidate: JevHardGate.Candidate,
        rule: JevComposeRule? = nil
    ) -> SuggestedAction {
        let clamped = JevHardGate.clampAction(action, for: candidate)
        if clamped != action {
            let reason = JevHardGate.freezeCeilingReason(for: candidate)
            JevLog.infoThrottled(
                key: "ceiling:\(candidate.bundleID)",
                "action_ceiling bundle=\(candidate.bundleID) composed=\(action.rawValue) clamped=\(clamped.rawValue) reason=\(reason?.1 ?? "owns_windows") prior_rule=\(rule?.rawValue ?? "-")"
            )
        }
        return clamped
    }

    private func pressureBucketName(_ pressure: MemoryPressureLevel) -> String {
        switch pressure {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }

    private func englishHint(bundleID: String, name: String) -> String? {
        let id = bundleID.lowercased()
        if id.contains("chrome") { return "Google Chrome browser" }
        if id.contains("firefox") { return "Mozilla Firefox browser" }
        if id.contains("sublime") { return "Sublime Text editor" }
        if id.contains("spotify") { return "Spotify music" }
        if id.contains("slack") { return "Slack chat" }
        if name.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) != nil {
            return "localized_name=\(name); bundle=\(bundleID)"
        }
        return nil
    }
}

private func fmt(_ value: Double) -> String {
    String(format: "%.3f", value)
}
