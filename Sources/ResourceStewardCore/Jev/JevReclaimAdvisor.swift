import Foundation

/// Orchestrates hard-gate checks, caching, async Jev calls, and fail-closed overrides.
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
    private let lock = NSLock()
    private var inFlight: Set<String> = []
    /// Fresh composed decisions keyed by bundle ID.
    private var decisions: [String: Decision] = [:]
    private var apiKeyProvider: () -> String?
    public var isEnabled: Bool

    public init(
        enabled: Bool = false,
        client: any JevClientProtocol = JevURLSessionClient(),
        cache: JevCache = JevCache(),
        apiKeyProvider: @escaping () -> String? = { JevKeychain.loadAPIKey() }
    ) {
        self.isEnabled = enabled
        self.client = client
        self.cache = cache
        self.apiKeyProvider = apiKeyProvider
    }

    public var isActive: Bool {
        isEnabled && apiKeyProvider() != nil
    }

    public func updateEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Apply Jev override to a scorer suggestion for display (suggest-only / list).
    /// Pending leaves the scorer suggestion unchanged for display; auto uses `decisionForAuto`.
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
            JevLog.info("skip hard_gate=\(reason.rawValue) detail=\(detail) bundle=\(candidate.bundleID)")
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
            let decision = Decision(
                action: composed.action,
                fromCache: true,
                pending: false,
                rule: composed.rule,
                requestID: cached.entry.requestID
            )
            lock.lock()
            decisions[candidate.bundleID] = decision
            lock.unlock()
            JevLog.info(
                "cache_hit bundle=\(candidate.bundleID) request_id=\(cached.entry.requestID) action=\(composed.action.rawValue) rule=\(composed.rule.rawValue)"
            )
            return composed.action
        }

        lock.lock()
        let existing = decisions[candidate.bundleID]
        let pending = inFlight.contains(candidate.bundleID)
        lock.unlock()

        if let existing, !existing.pending {
            return existing.action
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

    /// Fail-closed for Level-1 auto: pending / missing / error → none.
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
            JevLog.info("auto_skip hard_gate=\(reason.rawValue) detail=\(detail) bundle=\(candidate.bundleID)")
            // Hard-gated candidates should not reach auto; local SceneSwitchPolicy already filters.
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

        lock.lock()
        let decision = decisions[candidate.bundleID]
        let pending = inFlight.contains(candidate.bundleID) || decision?.pending == true
        lock.unlock()

        if pending {
            JevLog.info("auto_fail_closed pending bundle=\(candidate.bundleID)")
            return .none
        }
        if decision == nil,
           cache.lookup(
               bundleID: candidate.bundleID,
               pressureBucket: pressure.rawValue,
               idleSeconds: idleSeconds,
               memoryMB: memoryMB
           )?.actionFresh != true {
            JevLog.info("auto_fail_closed no_decision bundle=\(candidate.bundleID)")
            return .none
        }
        return adjusted
    }

    public func knownDecision(bundleID: String) -> Decision? {
        lock.lock()
        defer { lock.unlock() }
        return decisions[bundleID]
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
        lock.lock()
        if inFlight.contains(key) {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        decisions[key] = Decision(action: .none, pending: true)
        lock.unlock()

        guard let apiKey = apiKeyProvider() else {
            lock.lock()
            inFlight.remove(key)
            decisions[key] = Decision(action: .none, pending: false)
            lock.unlock()
            JevLog.error("missing_api_key bundle=\(key)")
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
            "request_start request_id=\(requestID) bundle=\(key) cache_hit=false state=\(state.app.truncatedSummary) pressure=\(pressure.rawValue)"
        )

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.evaluate(state: state, apiKey: apiKey, requestID: requestID)
                let composed = JevComposer.compose(result.answers)
                self.cache.store(
                    bundleID: key,
                    pressureBucket: pressure.rawValue,
                    idleSeconds: idleSeconds,
                    memoryMB: memoryMB,
                    answers: result.answers,
                    composed: composed,
                    model: result.model,
                    requestID: result.requestID
                )
                self.lock.lock()
                self.inFlight.remove(key)
                self.decisions[key] = Decision(
                    action: composed.action,
                    fromCache: false,
                    pending: false,
                    rule: composed.rule,
                    requestID: result.requestID
                )
                self.lock.unlock()
                let tokens = "in=\(result.usage.inputTokens.map(String.init) ?? "?") out=\(result.usage.outputTokens.map(String.init) ?? "?")"
                JevLog.info(
                    "request_ok request_id=\(result.requestID) bundle=\(key) status=\(result.httpStatus) latency_ms=\(result.latencyMs) usage=\(tokens) noul_network=\(fmt(result.answers.looksLikeNetworkOrSync)) noul_comm=\(fmt(result.answers.looksLikeCommunication)) noul_input=\(fmt(result.answers.looksLikeInputOrA11y)) noul_av=\(fmt(result.answers.looksLikeAVOrCapture)) noul_needs=\(fmt(result.answers.userLikelyNeedsSoon)) noul_safe=\(fmt(result.answers.safeToReclaimIdle)) choice=\(result.answers.preferredAction.choice) conf=\(fmt(result.answers.preferredAction.confidence)) composed=\(composed.action.rawValue) rule=\(composed.rule.rawValue)"
                )
            } catch let error as JevClientError {
                self.lock.lock()
                self.inFlight.remove(key)
                self.decisions[key] = Decision(action: .none, pending: false)
                self.lock.unlock()
                JevLog.error(
                    "request_fail request_id=\(requestID) bundle=\(key) recoverable=\(error.isRecoverable) message=\(error.localizedDescription)"
                )
            } catch {
                self.lock.lock()
                self.inFlight.remove(key)
                self.decisions[key] = Decision(action: .none, pending: false)
                self.lock.unlock()
                JevLog.error(
                    "request_fail request_id=\(requestID) bundle=\(key) recoverable=true message=\(error.localizedDescription)"
                )
            }
        }
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
