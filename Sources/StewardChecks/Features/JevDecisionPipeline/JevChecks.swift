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

        
        let legacy = #"{"authorizationLevel":0,"weights":{},"matchingWindowMinutes":10,"matchingThreshold":0.6,"sampleIntervalSeconds":5,"hasCompletedOnboarding":true,"showOnlyActionable":false,"favoriteApps":[],"scoringRevision":1}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        check("settings migrate jev default off", decoded.jevReclaimEnabled == false)

        check("log subsystem name", JevLog.subsystem == "cc.resourcesteward.jev")
        
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
            decodedBase.jevModel == JevURLSessionClient.defaultModel
        )

        failures += try JevCredentialChecks.run()

        let clock = JevTestClock()
        let controlled = ControlledBatchClient()
        let batchAdvisor = JevReclaimAdvisor(enabled: true, client: controlled, apiKeyProvider: { "test-key" }, monotonicNow: { clock.now })
        let resolved = DispatchSemaphore(value: 0)
        batchAdvisor.setOnBatchResolved { resolved.signal() }
        let app = JevGrayApp(index: 0, bundle_id: "com.example.test", name: "Test", idle_seconds: 600, memory_mb: 500, cpu_percent: 0, owns_windows: true, process_identity: "42:100")
        let load = JevLoadState(memory_pressure: "critical", cpu_percent: 90, memory_used_ratio: 0.95, swap_used_mb: 100, memory_pressure_seconds: 30, cpu_pressure_seconds: 30)
        let first = batchAdvisor.syncBatch(load: load, apps: [app])
        check("first batch is pending with no actions", first.pending && first.actions.isEmpty)
        check("first batch request starts", controlled.started.wait(timeout: .now() + 2) == .success)
        controlled.resolve(0)
        check("first batch resolves", resolved.wait(timeout: .now() + 2) == .success)
        check("resolved batch is reusable", batchAdvisor.syncBatch(load: load, apps: [app]).actions[app.bundle_id] == .quit)
        var changed = load
        changed.memory_pressure = "warning"
        let cooling = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("signature change obeys global cooldown", cooling.status == .requestCooldown && !cooling.pending && cooling.actions.isEmpty)
        check("cooldown does not start network request", controlled.started.wait(timeout: .now() + 0.15) == .timedOut)
        clock.advance(20)
        let waiting = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("new load never reuses old quit while pending", waiting.pending && waiting.actions.isEmpty && batchAdvisor.latestBatch().actions.isEmpty)
        check("second request starts", controlled.started.wait(timeout: .now() + 2) == .success)
        
        changed.foreground_bundle_id = "com.example.editor"
        _ = batchAdvisor.syncBatch(load: changed, apps: [app])
        clock.advance(25)
        _ = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("in-flight request blocks overlapping context request", controlled.started.wait(timeout: .now() + 0.15) == .timedOut)
        controlled.resolve(1)
        check("superseded reply emits no resolved event", resolved.wait(timeout: .now() + 0.15) == .timedOut)
        check("late old quit cannot overwrite changed context", batchAdvisor.latestBatch().actions.isEmpty)
        _ = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("latest context starts after old flight ends", controlled.started.wait(timeout: .now() + 2) == .success)
        controlled.resolve(2, choice: "keep")
        check("newest request resolves", resolved.wait(timeout: .now() + 2) == .success)
        check("newest keep is preserved", batchAdvisor.latestBatch().actions[app.bundle_id] == SuggestedAction.none)
        batchAdvisor.updateModel("another-model")
        check("model change invalidates cached decisions", batchAdvisor.latestBatch().actions.isEmpty)
        clock.advance(20)
        _ = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("changed model request starts", controlled.started.wait(timeout: .now() + 2) == .success)
        batchAdvisor.updateEnabled(false)
        controlled.resolve(3)
        check("disabled advisor rejects in-flight result", resolved.wait(timeout: .now() + 0.15) == .timedOut && batchAdvisor.latestBatch().actions.isEmpty)
        batchAdvisor.updateEnabled(true)
        clock.advance(20)
        _ = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("reenabled request starts", controlled.started.wait(timeout: .now() + 2) == .success)
        clock.advance(30)
        controlled.resolve(4, fail: true)
        check("request failure resolves safely", resolved.wait(timeout: .now() + 2) == .success && batchAdvisor.latestBatch().actions.isEmpty)
        batchAdvisor.updateAPIKey("replacement")
        let retry = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("key change cannot bypass failure cooldown", retry.status == .requestCooldown && controlled.started.wait(timeout: .now() + 0.15) == .timedOut)
        clock.advance(19)
        _ = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("failure cooldown measures from completion", controlled.started.wait(timeout: .now() + 0.15) == .timedOut)
        clock.advance(1)
        _ = batchAdvisor.syncBatch(load: changed, apps: [app])
        check("replacement key starts fresh request", controlled.started.wait(timeout: .now() + 2) == .success)
        batchAdvisor.updateAPIKey(nil)
        controlled.resolve(5)
        check("cleared key rejects in-flight result", resolved.wait(timeout: .now() + 0.15) == .timedOut && batchAdvisor.latestBatch().actions.isEmpty && !batchAdvisor.isActive)
        batchAdvisor.updateAPIKey("replacement")
        var reopened = app
        reopened.process_identity = "42:200"
        check("relaunch invalidates batch signature", JevBatchQuestions.signature(load: load, apps: [app]) != JevBatchQuestions.signature(load: load, apps: [reopened]))
        clock.advance(20)
        _ = batchAdvisor.syncBatch(load: changed, apps: [reopened])
        check("reopened app request starts", controlled.started.wait(timeout: .now() + 2) == .success)
        _ = batchAdvisor.syncBatch(load: changed, apps: [])
        controlled.resolve(6)
        check("empty gray zone invalidates in-flight reply", resolved.wait(timeout: .now() + 0.15) == .timedOut && batchAdvisor.latestBatch().actions.isEmpty)

        failures.append(contentsOf: try JevPipelineChecks.run())
        failures.append(contentsOf: try JevSequencingChecks.run())
        failures.append(contentsOf: try JevFamilyChecks.run())
        return failures
    }
}


private final class ControlledBatchClient: JevClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: CheckedContinuation<JevPayloadResult, Error>] = [:]
    private var ids: [String] = []
    let started = DispatchSemaphore(value: 0)

    func evaluatePayload(stateJSON: Data, questionsJSON: Data, apiKey: String, requestID: String, endpoint: URL, model: String) async throws -> JevPayloadResult {
        if !requestID.hasSuffix("-decision") {
            return JevPayloadResult(requestID: requestID, model: model, answersJSON: try JevPipelineChecks.assessmentData(), httpStatus: 200, latencyMs: 1)
        }
        return try await withCheckedThrowingContinuation { continuation in
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
            let json = "{\"app_0\":{\"type\":\"choice\",\"choice\":\"\(choice)\",\"confidence\":0.99}}"
            reply?.resume(returning: JevPayloadResult(requestID: id, model: "test", answersJSON: Data(json.utf8), httpStatus: 200, latencyMs: 1))
        }
    }
}
