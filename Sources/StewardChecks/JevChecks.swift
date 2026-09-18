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
        check("compose chooses freeze when safe", composedSafe.action == .freeze && composedSafe.rule == .choice)

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
        check(
            "notes hard-gated",
            notesReason == .ownsWindows || notesReason == .categoryBan
        )
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
        let parsed = try JevResponseParser.parse(data: json, requestID: "r1", httpStatus: 200, latencyMs: 12)
        check("parser model", parsed.model == "jev-1.13.0")
        check("parser preferred freeze", parsed.answers.preferredAction.choice == "freeze")
        check("parser usage tokens", parsed.usage.inputTokens == 100 && parsed.usage.outputTokens == 20)

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
        let hostEP = JevURLSessionClient.resolveEndpoint(baseURLString: "https://api.typesafe.ai")
        check("host base appends systemone", hostEP.absoluteString == "https://api.typesafe.ai/v1/systemone")
        let proxyEP = JevURLSessionClient.resolveEndpoint(baseURLString: "https://gateway.example.com/typesafe/")
        check(
            "proxy base keeps prefix path",
            proxyEP.absoluteString == "https://gateway.example.com/typesafe/v1/systemone"
        )
        let fullEP = JevURLSessionClient.resolveEndpoint(
            baseURLString: "https://gateway.example.com/v1/systemone"
        )
        check("full systemone URL kept", fullEP.absoluteString == "https://gateway.example.com/v1/systemone")
        let bare = JevURLSessionClient.resolveEndpoint(baseURLString: "api.typesafe.ai")
        check("bare host gets https", bare.absoluteString == "https://api.typesafe.ai/v1/systemone")
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
            "openrouter decisions trailing slash normalized",
            openRouterSlash.absoluteString == "https://openrouter.ai/api/alpha/decisions"
        )

        let decodedBase = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"authorizationLevel":0}"#.utf8)
        )
        check(
            "settings migrate jevBaseURL default",
            decodedBase.jevBaseURL == JevURLSessionClient.defaultBaseURLString
        )
        check(
            "settings migrate jevModel default",
            decodedBase.jevModel == JevQuestions.defaultModel
        )

        check("api key env var name", JevAPIKey.environmentVariable == "RESOURCE_STEWARD_JEV_API_KEY")
        check("api key status never empty", !JevAPIKey.statusDescription().isEmpty)

        return failures
    }
}
