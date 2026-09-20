import Foundation
import ResourceStewardCore

enum JevChecks {
    static func run() throws -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("ok   \(name)")
            } else {
                print("FAIL \(name)")
                failures.append(name)
            }
        }

        // Composition fixtures — no network.
        let safeFreeze = JevEvaluationAnswers(
            looksLikeNetworkOrSync: 0.1,
            looksLikeCommunication: 0.1,
            looksLikeInputOrA11y: 0.05,
            looksLikeAVOrCapture: 0.05,
            userLikelyNeedsSoon: 0.2,
            safeToReclaimIdle: 0.9,
            preferredAction: JevChoiceAnswer(choice: "freeze", confidence: 0.85)
        )
        let composedSafe = JevComposer.compose(safeFreeze)
        check("compose freeze is retired to throttle", composedSafe.action == .throttle)

        let midFreeze = JevEvaluationAnswers(
            looksLikeNetworkOrSync: 0.1,
            looksLikeCommunication: 0.1,
            looksLikeInputOrA11y: 0.05,
            looksLikeAVOrCapture: 0.05,
            userLikelyNeedsSoon: 0.2,
            safeToReclaimIdle: 0.9,
            preferredAction: JevChoiceAnswer(choice: "freeze", confidence: 0.75)
        )
        let composedMidFreeze = JevComposer.compose(midFreeze)
        check(
            "compose freeze at 0.75 → throttle",
            composedMidFreeze.action == .throttle
        )

        let midQuit = JevEvaluationAnswers(
            looksLikeNetworkOrSync: 0.1,
            looksLikeCommunication: 0.1,
            looksLikeInputOrA11y: 0.05,
            looksLikeAVOrCapture: 0.05,
            userLikelyNeedsSoon: 0.2,
            safeToReclaimIdle: 0.9,
            preferredAction: JevChoiceAnswer(choice: "quit", confidence: 0.8)
        )
        check(
            "compose quit below 0.85 → throttle",
            JevComposer.compose(midQuit).action == .throttle && JevComposer.compose(midQuit).rule == .highStakesConfidence
        )

        let highRisk = JevEvaluationAnswers(
            looksLikeNetworkOrSync: 0.8,
            looksLikeCommunication: 0.1,
            looksLikeInputOrA11y: 0.1,
            looksLikeAVOrCapture: 0.1,
            userLikelyNeedsSoon: 0.1,
            safeToReclaimIdle: 0.95,
            preferredAction: JevChoiceAnswer(choice: "freeze", confidence: 0.99)
        )
        check("compose risk gate → none", JevComposer.compose(highRisk).action == .none && JevComposer.compose(highRisk).rule == .risk)

        let needsSoon = JevEvaluationAnswers(
            looksLikeNetworkOrSync: 0.1,
            looksLikeCommunication: 0.1,
            looksLikeInputOrA11y: 0.1,
            looksLikeAVOrCapture: 0.1,
            userLikelyNeedsSoon: 0.7,
            safeToReclaimIdle: 0.95,
            preferredAction: JevChoiceAnswer(choice: "quit", confidence: 0.99)
        )
        check("compose needs_soon → none", JevComposer.compose(needsSoon).rule == .needsSoon)

        let unsafe = JevEvaluationAnswers(
            looksLikeNetworkOrSync: 0.1,
            looksLikeCommunication: 0.1,
            looksLikeInputOrA11y: 0.1,
            looksLikeAVOrCapture: 0.1,
            userLikelyNeedsSoon: 0.1,
            safeToReclaimIdle: 0.4,
            preferredAction: JevChoiceAnswer(choice: "freeze", confidence: 0.99)
        )
        check("compose safe_threshold → none", JevComposer.compose(unsafe).rule == .safeThreshold)

        let lowConf = JevEvaluationAnswers(
            looksLikeNetworkOrSync: 0.1,
            looksLikeCommunication: 0.1,
            looksLikeInputOrA11y: 0.1,
            looksLikeAVOrCapture: 0.1,
            userLikelyNeedsSoon: 0.1,
            safeToReclaimIdle: 0.9,
            preferredAction: JevChoiceAnswer(choice: "freeze", confidence: 0.5)
        )
        check("compose confidence → none", JevComposer.compose(lowConf).rule == .confidence)

        // Hard gates: WeChat / Notes never call client.
        final class EvaluateCounter: @unchecked Sendable {
            var value = 0
        }
        let evaluateCount = EvaluateCounter()
        let mock = JevMockClient(
            result: .success(
                JevClientResult(
                    requestID: "test",
                    model: "jev-latest",
                    answers: safeFreeze,
                    httpStatus: 200,
                    latencyMs: 1
                )
            ),
            onEvaluate: { _ in evaluateCount.value += 1 }
        )
        let advisor = JevReclaimAdvisor(
            enabled: true,
            client: mock,
            cache: JevCache(memoryOnly: true),
            apiKeyProvider: { "test-key" }
        )

        let wechat = JevHardGate.Candidate(
            pid: 1,
            bundleID: "com.tencent.xinWeChat",
            processName: "WeChat",
            path: "/Applications/WeChat.app",
            isForeground: false,
            isAccessory: false,
            isRegularApp: true,
            ownsWindows: false,
            inCurrentWorkspace: false,
            isProtected: false,
            windowOwnerPIDs: []
        )
        check("wechat hard-gated", JevHardGate.skipReason(for: wechat)?.0 == .categoryBan)
        _ = advisor.adjustSuggestion(
            scorerAction: .quit,
            candidate: wechat,
            pressure: .warning,
            idleSeconds: 600,
            memoryMB: 400,
            cpuPercent: 1,
            authorization: .suggestOnly,
            alreadyFrozen: false
        )
        check("wechat never calls client", evaluateCount.value == 0)

        let notes = JevHardGate.Candidate(
            pid: 2,
            bundleID: "com.apple.Notes",
            processName: "Notes",
            path: "/System/Applications/Notes.app",
            isForeground: false,
            isAccessory: false,
            isRegularApp: true,
            ownsWindows: true,
            inCurrentWorkspace: false,
            isProtected: false,
            windowOwnerPIDs: [2]
        )
        let notesReason = JevHardGate.skipReason(for: notes)?.0
        check("notes hard-gated", notesReason == .categoryBan)
        _ = advisor.adjustSuggestion(
            scorerAction: .freeze,
            candidate: notes,
            pressure: .warning,
            idleSeconds: 600,
            memoryMB: 200,
            cpuPercent: 0.5,
            authorization: .suggestOnly,
            alreadyFrozen: false
        )
        check("notes never calls client", evaluateCount.value == 0)

        let sublime = JevHardGate.Candidate(
            pid: 3,
            bundleID: "com.sublimetext.4",
            processName: "Sublime Text",
            path: "/Applications/Sublime Text.app",
            isForeground: false,
            isAccessory: false,
            isRegularApp: true,
            ownsWindows: false,
            inCurrentWorkspace: false,
            isProtected: false,
            windowOwnerPIDs: []
        )
        check("sublime is gray-zone", JevHardGate.isGrayZone(sublime))
        check(
            "headless sublime freeze clamped to throttle",
            JevHardGate.clampAction(.freeze, for: sublime) == .throttle
        )

        let windowedSublime = JevHardGate.Candidate(
            pid: 4,
            bundleID: "com.sublimetext.4",
            processName: "Sublime Text",
            path: "/Applications/Sublime Text.app",
            isForeground: false,
            isAccessory: false,
            isRegularApp: true,
            ownsWindows: true,
            inCurrentWorkspace: false,
            isProtected: false,
            windowOwnerPIDs: [4]
        )
        check("windowed sublime is gray-zone", JevHardGate.isGrayZone(windowedSublime))
        check("windowed sublime consult not skipped", JevHardGate.skipReason(for: windowedSublime) == nil)
        check(
            "windowed sublime freeze clamped to throttle",
            JevHardGate.clampAction(.freeze, for: windowedSublime) == .throttle
        )
        check(
            "windowed sublime quit not clamped",
            JevHardGate.clampAction(.quit, for: windowedSublime) == .quit
        )
        check("policy hint names owns_windows field", JevPolicyHint().note.contains("owns_windows"))
        check("policy hint does not treat windowed as consult skip", !JevPolicyHint().note.contains("refused VPN, meeting, IM, a11y, windowed"))
        check("policy hint says freeze disabled", JevPolicyHint().note.lowercased().contains("freeze"))

        check("chrome is third-party", InstalledAppCatalog.isThirdParty(bundleID: "com.google.Chrome"))
        check("safari is not third-party", !InstalledAppCatalog.isThirdParty(bundleID: "com.apple.Safari"))
        check("self app is not third-party", !InstalledAppCatalog.isThirdParty(bundleID: "cc.resourcesteward.app"))

        check(
            "stale jev keep needs reclassify",
            AppClassification(
                bundleID: "com.google.Chrome",
                name: "Chrome",
                path: "/Applications/Google Chrome.app",
                policy: .keep,
                source: .jev,
                schemaVersion: 1
            ).needsReclassify
        )
        check(
            "current jev class does not need reclassify",
            !AppClassification(
                bundleID: "com.google.Chrome",
                name: "Chrome",
                path: "/Applications/Google Chrome.app",
                policy: .quit,
                source: .jev
            ).needsReclassify
        )

        check(
            "batch compose keep",
            JevBatchComposer.compose(choice: "keep", confidence: 0.9) == .none
        )
        check(
            "batch compose throttle",
            JevBatchComposer.compose(choice: "throttle", confidence: 0.8) == .throttle
        )
        check(
            "batch compose quit high conf",
            JevBatchComposer.compose(choice: "quit", confidence: 0.9) == .quit
        )
        check(
            "batch compose quit mid conf → throttle",
            JevBatchComposer.compose(choice: "quit", confidence: 0.8) == .throttle
        )
        check(
            "batch compose freeze → throttle",
            JevBatchComposer.compose(choice: "freeze", confidence: 0.95) == .throttle
        )
        check(
            "batch compose low conf → keep",
            JevBatchComposer.compose(choice: "throttle", confidence: 0.4) == .none
        )
        let batchApps = JevBatchQuestions.capped([
            JevGrayApp(index: 0, bundle_id: "com.google.Chrome", name: "Chrome", idle_seconds: 400, memory_mb: 1800, cpu_percent: 1, owns_windows: true),
            JevGrayApp(index: 1, bundle_id: "io.masscode.app", name: "massCode", idle_seconds: 800, memory_mb: 200, cpu_percent: 0.2, owns_windows: true)
        ])
        check("batch caps preserve memory order", batchApps.first?.bundle_id == "com.google.Chrome")
        let parsed = JevBatchQuestions.parse(
            answers: [
                "app_0": ["choice": "quit", "confidence": 0.92],
                "app_1": ["choice": "keep", "confidence": 0.8]
            ],
            apps: batchApps
        )
        check("batch parse chrome quit", parsed["com.google.Chrome"] == .quit)
        check("batch parse mass keep", parsed["io.masscode.app"] == SuggestedAction.none)
        let wechatCandidate = JevHardGate.Candidate(
            pid: 9,
            bundleID: "com.tencent.xinWeChat",
            processName: "WeChat",
            isForeground: false,
            isAccessory: false,
            isRegularApp: true,
            ownsWindows: true,
            inCurrentWorkspace: false,
            isProtected: false
        )
        let golandBackground = JevHardGate.Candidate(
            pid: 10,
            bundleID: "com.jetbrains.goland",
            processName: "GoLand",
            path: "/Applications/GoLand.app",
            isForeground: false,
            isAccessory: false,
            isRegularApp: true,
            ownsWindows: true,
            inCurrentWorkspace: true,
            isProtected: false
        )
        check("wechat is not gray-zone", !JevHardGate.isGrayZone(wechatCandidate))
        check("workspace core is no longer a consult skip", JevHardGate.isGrayZone(golandBackground))
        check(
            "gray zone helper skips empty groups",
            JevGrayZone.apps(
                groups: [],
                favorites: [],
                windowOwnerPIDs: []
            ).isEmpty
        )

        // Response parser
        let json = """
        {
          "model": "jev-1.13.0",
          "answers": {
            "looks_like_network_or_sync": {"type":"noul","noul":0.1},
            "looks_like_communication": {"type":"noul","noul":0.1},
            "looks_like_input_or_a11y": {"type":"noul","noul":0.05},
            "looks_like_av_or_capture": {"type":"noul","noul":0.05},
            "user_likely_needs_soon": {"type":"noul","noul":0.2},
            "safe_to_reclaim_idle": {"type":"noul","noul":0.9},
            "preferred_action": {
              "type":"choice",
              "choice":"freeze",
              "confidence":0.85,
              "probabilities":{"none":0.05,"throttle":0.05,"freeze":0.85,"quit":0.05}
            }
          },
          "usage": {"input_tokens": 100, "output_tokens": 20}
        }
        """.data(using: .utf8)!
        let parsedResponse = try JevResponseParser.parse(data: json, requestID: "r1", httpStatus: 200, latencyMs: 12)
        check("parser model", parsedResponse.model == "jev-1.13.0")
        check("parser preferred freeze", parsedResponse.answers.preferredAction.choice == "freeze")
        check("parser usage tokens", parsedResponse.usage.inputTokens == 100 && parsedResponse.usage.outputTokens == 20)

        // Mock error → fail-closed decision path via composer already tested; incomplete parse
        do {
            _ = try JevResponseParser.parse(
                data: #"{"model":"jev-latest","answers":{}}"#.data(using: .utf8)!,
                requestID: "bad",
                httpStatus: 200,
                latencyMs: 1
            )
            check("incomplete answers throw", false)
        } catch let error as JevClientError {
            check("incomplete answers throw", error == .incompleteAnswers)
        } catch {
            check("incomplete answers throw", false)
        }

        // Settings migration: missing jevReclaimEnabled defaults false
        let legacy = #"{"authorizationLevel":0,"weights":{},"matchingWindowMinutes":10,"matchingThreshold":0.6,"sampleIntervalSeconds":5,"hasCompletedOnboarding":true,"showOnlyActionable":false,"favoriteApps":[],"scoringRevision":1}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        check("settings migrate jev default off", decoded.jevReclaimEnabled == false)

        check("log subsystem name", JevLog.subsystem == "cc.resourcesteward.jev")
        // Smoke: once/throttle helpers are callable (no assert on side effects).
        JevLog.infoOnce(key: "check-once", "check_once_ok")
        JevLog.infoThrottled(key: "check-throttle", interval: 3600, "check_throttle_ok")
        check("log helpers callable", true)

        let defaultEP = JevURLSessionClient.resolveEndpoint(baseURLString: "")
        check("empty base → default endpoint", defaultEP == JevURLSessionClient.defaultEndpoint)
        check(
            "default base is the full POST URL",
            JevURLSessionClient.defaultBaseURLString == "https://api.typesafe.ai/v1/systemone"
        )
        check(
            "openrouter preset URL",
            JevURLSessionClient.openRouterBaseURLString == "https://openrouter.ai/api/alpha/decisions"
        )
        check(
            "openrouter preset model",
            JevURLSessionClient.openRouterDefaultModel == "~typesafe/jev-latest"
        )
        let hostEP = JevURLSessionClient.resolveEndpoint(baseURLString: "https://api.typesafe.ai")
        check("host base is used as-is", hostEP.absoluteString == "https://api.typesafe.ai")
        let proxyEP = JevURLSessionClient.resolveEndpoint(baseURLString: "https://gateway.example.com/typesafe/")
        check(
            "proxy base keeps user path",
            proxyEP.absoluteString == "https://gateway.example.com/typesafe/"
        )
        let fullEP = JevURLSessionClient.resolveEndpoint(
            baseURLString: "https://gateway.example.com/v1/systemone"
        )
        check("full systemone URL kept", fullEP.absoluteString == "https://gateway.example.com/v1/systemone")
        let bare = JevURLSessionClient.resolveEndpoint(baseURLString: "api.typesafe.ai")
        check("bare host gets https and no path suffix", bare.absoluteString == "https://api.typesafe.ai")
        let openRouter = JevURLSessionClient.resolveEndpoint(
            baseURLString: "https://openrouter.ai/api/alpha/decisions"
        )
        check(
            "openrouter decisions URL kept",
            openRouter.absoluteString == "https://openrouter.ai/api/alpha/decisions"
        )
        let openRouterSlash = JevURLSessionClient.resolveEndpoint(
            baseURLString: "https://openrouter.ai/api/alpha/decisions/"
        )
        check(
            "openrouter trailing slash kept",
            openRouterSlash.absoluteString == "https://openrouter.ai/api/alpha/decisions/"
        )

        let decodedBase = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"authorizationLevel":0}"#.utf8)
        )
        check(
            "settings migrate jevBaseURL default",
            decodedBase.jevBaseURL == JevURLSessionClient.defaultBaseURLString
        )
        let oldHostDefault = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"authorizationLevel":0,"jevBaseURL":"https://api.typesafe.ai"}"#.utf8)
        )
        check(
            "old host-only default migrates to full URL",
            oldHostDefault.jevBaseURL == JevURLSessionClient.defaultBaseURLString
        )
        let customBase = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"authorizationLevel":0,"jevBaseURL":"https://gateway.example.com/custom"}"#.utf8)
        )
        check("custom base URL kept", customBase.jevBaseURL == "https://gateway.example.com/custom")
        check(
            "settings migrate jevModel default",
            decodedBase.jevModel == JevQuestions.defaultModel
        )

        check("api key env var name", JevAPIKey.environmentVariable == "RESOURCE_STEWARD_JEV_API_KEY")
        check("api key status never empty", !JevAPIKey.statusDescription().isEmpty)

        let controlled = ControlledBatchClient()
        let batchAdvisor = JevReclaimAdvisor(enabled: true, client: controlled, apiKeyProvider: { "test-key" })
        let resolved = DispatchSemaphore(value: 0)
        batchAdvisor.setOnBatchResolved { resolved.signal() }
        let app = JevGrayApp(index: 0, bundle_id: "com.example.test", name: "Test", idle_seconds: 120, memory_mb: 500, cpu_percent: 0, owns_windows: true, process_identity: "42:100")
        let load = JevLoadState(memory_pressure: "critical", cpu_percent: 90, memory_used_ratio: 0.95, swap_used_mb: 100)
        let first = batchAdvisor.syncBatch(load: load, apps: [app])
        check("first batch is pending with no actions", first.pending && first.actions.isEmpty)
        check("first batch request starts", controlled.started.wait(timeout: .now() + 2) == .success)
        controlled.resolve(0)
        check("first batch resolves", resolved.wait(timeout: .now() + 2) == .success)
        check("resolved batch is reusable", batchAdvisor.syncBatch(load: load, apps: [app]).actions[app.bundle_id] == .quit)
        var changed = load
        changed.memory_pressure = "normal"
        let waiting = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("new load never reuses old quit while pending", waiting.pending && waiting.actions.isEmpty && batchAdvisor.latestBatch().actions.isEmpty)
        check("second request starts", controlled.started.wait(timeout: .now() + 2) == .success)
        // Invalidate request 1 by changing the foreground; request 2 completes first.
        changed.foreground_bundle_id = "com.example.editor"
        _ = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("foreground change starts fresh request", controlled.started.wait(timeout: .now() + 2) == .success)
        controlled.resolve(2, choice: "keep")
        check("newest request resolves", resolved.wait(timeout: .now() + 2) == .success)
        controlled.resolve(1)
        check("superseded reply emits no resolved event", resolved.wait(timeout: .now() + 0.15) == .timedOut)
        check("late old quit cannot overwrite new keep", batchAdvisor.latestBatch().actions[app.bundle_id] == SuggestedAction.none)
        batchAdvisor.updateModel("another-model")
        check("model change invalidates cached decisions", batchAdvisor.latestBatch().actions.isEmpty)
        _ = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("changed model request starts", controlled.started.wait(timeout: .now() + 2) == .success)
        batchAdvisor.updateEnabled(false)
        controlled.resolve(3)
        check("disabled advisor rejects in-flight result", resolved.wait(timeout: .now() + 0.15) == .timedOut && batchAdvisor.latestBatch().actions.isEmpty)
        batchAdvisor.updateEnabled(true)
        _ = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("reenabled request starts", controlled.started.wait(timeout: .now() + 2) == .success)
        controlled.resolve(4, fail: true)
        check("request failure resolves safely", resolved.wait(timeout: .now() + 2) == .success && batchAdvisor.latestBatch().actions.isEmpty)
        var reopened = app
        reopened.process_identity = "42:200"
        check("relaunch invalidates batch signature", JevBatchQuestions.signature(load: load, apps: [app]) != JevBatchQuestions.signature(load: load, apps: [reopened]))
        _ = batchAdvisor.syncBatch(load: changed, apps: [reopened])
        check("reopened app request starts", controlled.started.wait(timeout: .now() + 2) == .success)
        _ = batchAdvisor.syncBatch(load: changed, apps: [])
        controlled.resolve(5)
        check("empty gray zone invalidates in-flight reply", resolved.wait(timeout: .now() + 0.15) == .timedOut && batchAdvisor.latestBatch().actions.isEmpty)

        return failures
    }
}

/// Holds responses so checks can drive cache invalidation and out-of-order replies.
private final class ControlledBatchClient: JevClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: CheckedContinuation<JevPayloadResult, Error>] = [:]
    private var ids: [String] = []
    let started = DispatchSemaphore(value: 0)

    func evaluate(state: JevRequestState, apiKey: String, requestID: String, endpoint: URL, model: String) async throws -> JevClientResult {
        throw JevClientError.incompleteAnswers
    }

    func evaluatePayload(stateJSON: Data, questionsJSON: Data, apiKey: String, requestID: String, endpoint: URL, model: String) async throws -> JevPayloadResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            replies[requestID] = continuation
            ids.append(requestID)
            lock.unlock()
            started.signal()
        }
    }

    func resolve(_ index: Int, choice: String = "quit", fail: Bool = false) {
        lock.lock()
        guard ids.indices.contains(index) else { lock.unlock(); return }
        let id = ids[index]
        let reply = replies.removeValue(forKey: id)
        lock.unlock()
        if fail {
            reply?.resume(throwing: JevClientError.timeout)
        } else {
            let json = "{\"app_0\":{\"choice\":\"\(choice)\",\"confidence\":0.99}}"
            reply?.resume(returning: JevPayloadResult(requestID: id, model: "test", answersJSON: Data(json.utf8), httpStatus: 200, latencyMs: 1))
        }
    }
}
