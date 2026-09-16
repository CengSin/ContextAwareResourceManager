import Foundation
import ResourceStewardCore

enum V2Checks {
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

        let coding = Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.WebStorm", "com.googlecode.iterm2"])
        let fun = Workspace(name: "Fun", coreAppBundleIDs: ["com.apple.Music"])
        let meeting = Workspace(name: "Meeting", coreAppBundleIDs: ["com.apple.FaceTime"])
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        check("daypart night", DayPart.from(hour: 2) == .night)
        check("daypart morning", DayPart.from(hour: 9) == .morning)
        check("daypart afternoon", DayPart.from(hour: 14) == .afternoon)
        check("daypart evening", DayPart.from(hour: 21) == .evening)
        check("markov skips self transition", !WorkspaceMarkov.shouldRecord(from: coding.id, to: coding.id))
        check("markov records real switch", WorkspaceMarkov.shouldRecord(from: coding.id, to: fun.id))
        check("markov records to unclassified", WorkspaceMarkov.shouldRecord(from: coding.id, to: nil))

        let hour22 = (0..<9).map { i in
            WorkspaceTransition(
                id: Int64(i),
                fromWorkspaceID: coding.id,
                toWorkspaceID: fun.id,
                hourOfDay: 22,
                weekday: 3,
                timestamp: t0
            )
        } + [
            WorkspaceTransition(
                id: 9,
                fromWorkspaceID: coding.id,
                toWorkspaceID: meeting.id,
                hourOfDay: 22,
                weekday: 3,
                timestamp: t0
            )
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 2
        components.hour = 22
        let at22 = calendar.date(from: components)!
        let forecast22 = WorkspaceMarkov.forecast(
            from: coding.id,
            at: at22,
            transitions: hour22,
            workspaceIDs: [coding.id, fun.id, meeting.id],
            calendar: calendar
        )
        let pFun = forecast22.predictions.first { $0.workspaceID == fun.id }
        let pMeet = forecast22.predictions.first { $0.workspaceID == meeting.id }
        let pUnclass = forecast22.predictions.first { $0.workspaceID == nil }
        let probabilitySum = forecast22.predictions.reduce(0.0) { $0 + $1.probability }
        check("hour scope with enough samples", forecast22.scope == .hour && forecast22.sampleCount == 10)
        check("laplace fun 10/13", pFun.map { abs($0.probability - 10.0 / 13.0) < 0.0001 } ?? false)
        check("laplace meeting 2/13", pMeet.map { abs($0.probability - 2.0 / 13.0) < 0.0001 } ?? false)
        check("laplace unclassified 1/13", pUnclass.map { abs($0.probability - 1.0 / 13.0) < 0.0001 } ?? false)
        check("probabilities sum to 1", abs(probabilitySum - 1) < 0.0001)
        check("top destination is fun", forecast22.predictions.first?.workspaceID == fun.id)

        let sparseHour = [
            WorkspaceTransition(id: 1, fromWorkspaceID: coding.id, toWorkspaceID: fun.id, hourOfDay: 22, weekday: 3, timestamp: t0),
            WorkspaceTransition(id: 2, fromWorkspaceID: coding.id, toWorkspaceID: fun.id, hourOfDay: 22, weekday: 3, timestamp: t0),
            WorkspaceTransition(id: 3, fromWorkspaceID: coding.id, toWorkspaceID: meeting.id, hourOfDay: 21, weekday: 3, timestamp: t0),
            WorkspaceTransition(id: 4, fromWorkspaceID: coding.id, toWorkspaceID: meeting.id, hourOfDay: 21, weekday: 3, timestamp: t0),
            WorkspaceTransition(id: 5, fromWorkspaceID: coding.id, toWorkspaceID: meeting.id, hourOfDay: 20, weekday: 3, timestamp: t0)
        ]
        let eveningForecast = WorkspaceMarkov.forecast(
            from: coding.id,
            at: at22,
            transitions: sparseHour,
            workspaceIDs: [coding.id, fun.id, meeting.id],
            calendar: calendar
        )
        check("falls back to daypart", eveningForecast.scope == .dayPart && eveningForecast.sampleCount == 5)
        check("daypart prefers meeting", eveningForecast.predictions.first?.workspaceID == meeting.id)

        let mixedHours = [
            WorkspaceTransition(id: 1, fromWorkspaceID: coding.id, toWorkspaceID: fun.id, hourOfDay: 9, weekday: 2, timestamp: t0),
            WorkspaceTransition(id: 2, fromWorkspaceID: coding.id, toWorkspaceID: meeting.id, hourOfDay: 15, weekday: 2, timestamp: t0)
        ]
        let allDayForecast = WorkspaceMarkov.forecast(
            from: coding.id,
            at: at22,
            transitions: mixedHours,
            workspaceIDs: [coding.id, fun.id, meeting.id],
            calendar: calendar
        )
        check("falls back to all day", allDayForecast.scope == .allDay && allDayForecast.sampleCount == 2)

        let emptyForecast = WorkspaceMarkov.forecast(
            from: fun.id,
            at: at22,
            transitions: hour22,
            workspaceIDs: [coding.id, fun.id, meeting.id],
            calendar: calendar
        )
        check("no samples yields empty forecast", emptyForecast.isEmpty)

        check("quit caps to freeze", SceneSwitchPolicy.autoAction(for: .quit) == .freeze)
        check("freeze stays freeze", SceneSwitchPolicy.autoAction(for: .freeze) == .freeze)
        check("throttle stays throttle", SceneSwitchPolicy.autoAction(for: .throttle) == .throttle)
        check("none is skipped", SceneSwitchPolicy.autoAction(for: .none) == nil)

        let codingMatch = WorkspaceMatch(workspace: coding, similarity: 0.8, activeBundleIDs: coding.coreAppBundleIDs)
        let funMatch = WorkspaceMatch(workspace: fun, similarity: 0.7, activeBundleIDs: fun.coreAppBundleIDs)
        let unclassified = WorkspaceMatch(workspace: nil, similarity: 0.05, activeBundleIDs: ["com.apple.Safari"])

        let chrome = SceneSwitchTarget(
            groupKey: "com.google.Chrome",
            bundleID: "com.google.Chrome",
            processName: "Chrome",
            suggestedAction: .quit,
            isForeground: false,
            isProtected: false,
            isInCurrentWorkspace: false,
            alreadyFrozen: false,
            alreadyThrottled: false
        )
        let music = SceneSwitchTarget(
            groupKey: "com.apple.Music",
            bundleID: "com.apple.Music",
            processName: "Music",
            suggestedAction: .freeze,
            isForeground: false,
            isProtected: false,
            isInCurrentWorkspace: true,
            alreadyFrozen: false,
            alreadyThrottled: false
        )
        let ideFrozen = FrozenProcess(
            pid: 4242,
            bundleID: "com.jetbrains.WebStorm",
            processName: "WebStorm",
            action: .freeze
        )
        let musicFrozen = FrozenProcess(
            pid: 4444,
            bundleID: "com.apple.Music",
            processName: "Music",
            action: .freeze
        )

        var state = SceneSwitchState()
        var plan: SceneSwitchPlan
        (state, plan) = SceneSwitchPolicy.evaluate(
            state: state,
            authorization: .sceneSwitch,
            current: codingMatch,
            targets: [chrome],
            frozen: [],
            now: t0,
            debounceSeconds: 15
        )
        check("first sample is session start", plan.outcome == .sessionStart && !plan.shouldRecordTransition && !plan.didAutoProcess)
        check("session adopts current workspace", state.sessionReady && state.committedWorkspaceID == coding.id)

        (state, plan) = SceneSwitchPolicy.evaluate(
            state: state,
            authorization: .sceneSwitch,
            current: funMatch,
            targets: [chrome, music],
            frozen: [ideFrozen, musicFrozen],
            now: t0.addingTimeInterval(1),
            debounceSeconds: 15
        )
        check("first sight of new workspace debounces", plan.outcome == .debouncing && state.candidateWorkspaceID == fun.id)

        (state, plan) = SceneSwitchPolicy.evaluate(
            state: state,
            authorization: .sceneSwitch,
            current: funMatch,
            targets: [chrome, music],
            frozen: [ideFrozen, musicFrozen],
            now: t0.addingTimeInterval(10),
            debounceSeconds: 15
        )
        check("still debouncing before window", plan.outcome == .debouncing && !plan.shouldRecordTransition)

        (state, plan) = SceneSwitchPolicy.evaluate(
            state: state,
            authorization: .sceneSwitch,
            current: funMatch,
            targets: [chrome, music],
            frozen: [ideFrozen, musicFrozen],
            now: t0.addingTimeInterval(16),
            debounceSeconds: 15
        )
        check("level1 commits after debounce", plan.outcome == .committedWithAuto && plan.shouldRecordTransition)
        check("quit becomes freeze", plan.actions.contains(where: { $0.bundleID == "com.google.Chrome" && $0.action == .freeze && $0.originalSuggestion == .quit }))
        check("in-workspace app not auto processed", !plan.actions.contains(where: { $0.bundleID == "com.apple.Music" }))
        check("thaws new-scene core apps", plan.thaw.contains(where: { $0.pid == 4444 }))
        check("does not thaw old-scene freeze", !plan.thaw.contains(where: { $0.pid == 4242 }))
        check("committed workspace updates", state.committedWorkspaceID == fun.id && state.candidateWorkspaceID == nil)

        (state, plan) = SceneSwitchPolicy.evaluate(
            state: state,
            authorization: .sceneSwitch,
            current: unclassified,
            targets: [chrome],
            frozen: [ideFrozen],
            now: t0.addingTimeInterval(17),
            debounceSeconds: 15
        )
        check("unclassified starts debounce", plan.outcome == .debouncing)
        (state, plan) = SceneSwitchPolicy.evaluate(
            state: state,
            authorization: .sceneSwitch,
            current: unclassified,
            targets: [chrome],
            frozen: [ideFrozen],
            now: t0.addingTimeInterval(33),
            debounceSeconds: 15
        )
        check("unclassified records but does not act", plan.outcome == .committedUnclassified && plan.shouldRecordTransition && !plan.didAutoProcess && plan.actions.isEmpty)

        var level0 = SceneSwitchState(sessionReady: true, committedWorkspaceID: coding.id)
        (level0, plan) = SceneSwitchPolicy.evaluate(
            state: level0,
            authorization: .suggestOnly,
            current: funMatch,
            targets: [chrome],
            frozen: [],
            now: t0,
            debounceSeconds: 0
        )
        check("level0 records without acting", plan.outcome == .committedRecordOnly && plan.shouldRecordTransition && plan.actions.isEmpty && !plan.didAutoProcess)

        var level2 = SceneSwitchState(sessionReady: true, committedWorkspaceID: coding.id)
        (level2, plan) = SceneSwitchPolicy.evaluate(
            state: level2,
            authorization: .fullyAutomatic,
            current: funMatch,
            targets: [chrome],
            frozen: [],
            now: t0,
            debounceSeconds: 0
        )
        check("level2 still unavailable so no auto", plan.outcome == .committedRecordOnly && plan.actions.isEmpty)

        let foreground = SceneSwitchTarget(
            groupKey: "com.apple.Safari",
            bundleID: "com.apple.Safari",
            processName: "Safari",
            suggestedAction: .freeze,
            isForeground: true,
            isProtected: false,
            isInCurrentWorkspace: false,
            alreadyFrozen: false,
            alreadyThrottled: false
        )
        let protected = SceneSwitchTarget(
            groupKey: "com.apple.dock",
            bundleID: "com.apple.dock",
            processName: "Dock",
            suggestedAction: .freeze,
            isForeground: false,
            isProtected: true,
            isInCurrentWorkspace: false,
            alreadyFrozen: false,
            alreadyThrottled: false
        )
        let noneScore = SceneSwitchTarget(
            groupKey: "com.apple.Notes",
            bundleID: "com.apple.Notes",
            processName: "Notes",
            suggestedAction: .none,
            isForeground: false,
            isProtected: false,
            isInCurrentWorkspace: false,
            alreadyFrozen: false,
            alreadyThrottled: false
        )
        var skipState = SceneSwitchState(sessionReady: true, committedWorkspaceID: coding.id)
        (skipState, plan) = SceneSwitchPolicy.evaluate(
            state: skipState,
            authorization: .sceneSwitch,
            current: funMatch,
            targets: [foreground, protected, noneScore],
            frozen: [],
            now: t0,
            debounceSeconds: 0
        )
        check("skips foreground protected and none", plan.outcome == .committedWithAuto && plan.actions.isEmpty)

        let alreadyFrozen = SceneSwitchTarget(
            groupKey: "com.google.Chrome",
            bundleID: "com.google.Chrome",
            processName: "Chrome",
            suggestedAction: .freeze,
            isForeground: false,
            isProtected: false,
            isInCurrentWorkspace: false,
            alreadyFrozen: true,
            alreadyThrottled: false
        )
        var frozenState = SceneSwitchState(sessionReady: true, committedWorkspaceID: coding.id)
        (frozenState, plan) = SceneSwitchPolicy.evaluate(
            state: frozenState,
            authorization: .sceneSwitch,
            current: funMatch,
            targets: [alreadyFrozen],
            frozen: [],
            now: t0,
            debounceSeconds: 0
        )
        check("skips already frozen", plan.actions.isEmpty)

        let accessory = SceneSwitchTarget(
            groupKey: "com.liguangming.Shadowrocket",
            bundleID: "com.liguangming.Shadowrocket",
            processName: "Shadowrocket",
            suggestedAction: .freeze,
            isForeground: false,
            isProtected: false,
            isInCurrentWorkspace: false,
            alreadyFrozen: false,
            alreadyThrottled: false,
            isAccessory: true
        )
        var accessoryState = SceneSwitchState(sessionReady: true, committedWorkspaceID: coding.id)
        (accessoryState, plan) = SceneSwitchPolicy.evaluate(
            state: accessoryState,
            authorization: .sceneSwitch,
            current: funMatch,
            targets: [accessory],
            frozen: [],
            now: t0,
            debounceSeconds: 0
        )
        check("skips accessory menu-bar apps", plan.actions.isEmpty)

        let keepAlive = SceneSwitchTarget(
            groupKey: "com.liguangming.Shadowrocket",
            bundleID: "com.liguangming.Shadowrocket",
            processName: "Shadowrocket",
            suggestedAction: .freeze,
            isForeground: false,
            isProtected: true,
            isInCurrentWorkspace: false,
            alreadyFrozen: false,
            alreadyThrottled: false
        )
        var keepAliveState = SceneSwitchState(sessionReady: true, committedWorkspaceID: coding.id)
        (keepAliveState, plan) = SceneSwitchPolicy.evaluate(
            state: keepAliveState,
            authorization: .sceneSwitch,
            current: funMatch,
            targets: [keepAlive],
            frozen: [],
            now: t0,
            debounceSeconds: 0
        )
        check("skips keep-alive vpn", plan.actions.isEmpty)

        let pythonCLI = SceneSwitchTarget(
            groupKey: "python",
            bundleID: "python",
            processName: "python",
            suggestedAction: .throttle,
            isForeground: false,
            isProtected: false,
            isInCurrentWorkspace: false,
            alreadyFrozen: false,
            alreadyThrottled: false
        )
        let vmgrTarget = SceneSwitchTarget(
            groupKey: "dev.kdrag0n.MacVirt",
            bundleID: "dev.kdrag0n.MacVirt.vmgr",
            processName: "OrbStack Helper",
            suggestedAction: .freeze,
            isForeground: false,
            isProtected: true,
            isInCurrentWorkspace: false,
            alreadyFrozen: false,
            alreadyThrottled: false
        )
        var daemonState = SceneSwitchState(sessionReady: true, committedWorkspaceID: coding.id)
        (daemonState, plan) = SceneSwitchPolicy.evaluate(
            state: daemonState,
            authorization: .sceneSwitch,
            current: funMatch,
            targets: [pythonCLI, vmgrTarget],
            frozen: [],
            now: t0,
            debounceSeconds: 0
        )
        check("skips python cli and orbstack vmgr", plan.outcome == .committedWithAuto && plan.actions.isEmpty)

        let userFavorite = SceneSwitchTarget(
            groupKey: "com.sequel.ace",
            bundleID: "com.sequel.ace",
            processName: "Sequel Ace",
            suggestedAction: .freeze,
            isForeground: false,
            isProtected: true,
            isInCurrentWorkspace: false,
            alreadyFrozen: false,
            alreadyThrottled: false
        )
        var favoriteState = SceneSwitchState(sessionReady: true, committedWorkspaceID: coding.id)
        (favoriteState, plan) = SceneSwitchPolicy.evaluate(
            state: favoriteState,
            authorization: .sceneSwitch,
            current: funMatch,
            targets: [userFavorite],
            frozen: [],
            now: t0,
            debounceSeconds: 0
        )
        check("skips user favorite apps", plan.outcome == .committedWithAuto && plan.actions.isEmpty)

        var flap = SceneSwitchState(sessionReady: true, committedWorkspaceID: coding.id)
        (flap, plan) = SceneSwitchPolicy.evaluate(
            state: flap,
            authorization: .sceneSwitch,
            current: funMatch,
            targets: [chrome],
            frozen: [],
            now: t0,
            debounceSeconds: 15
        )
        (flap, plan) = SceneSwitchPolicy.evaluate(
            state: flap,
            authorization: .sceneSwitch,
            current: codingMatch,
            targets: [chrome],
            frozen: [],
            now: t0.addingTimeInterval(5),
            debounceSeconds: 15
        )
        check("flapping back clears debounce without commit", plan.outcome == .unchanged && flap.committedWorkspaceID == coding.id && !plan.shouldRecordTransition)

        let summary = SceneSwitchPolicy.summary(workspaceName: "娱乐", freezeCount: 2, throttleCount: 1, thawCount: 1)
        check("summary mentions workspace", summary.contains("娱乐") && summary.contains("冻结 2") && summary.contains("降低 1") && summary.contains("恢复 1"))

        let store = try LocalStore(path: NSTemporaryDirectory() + "rs-v2-\(UUID().uuidString).sqlite")
        try store.insertWorkspaceTransition(from: coding.id, to: coding.id, at: at22, calendar: calendar)
        check("store ignores self transition", store.loadWorkspaceTransitions().isEmpty)
        try store.insertWorkspaceTransition(from: coding.id, to: fun.id, at: at22, calendar: calendar)
        try store.insertWorkspaceTransition(from: coding.id, to: nil, at: at22, calendar: calendar)
        let loaded = store.loadWorkspaceTransitions()
        check("store roundtrip count", loaded.count == 2)
        check("store roundtrip ids", loaded.contains(where: { $0.fromWorkspaceID == coding.id && $0.toWorkspaceID == fun.id }))
        check("store roundtrip unclassified", loaded.contains(where: { $0.fromWorkspaceID == coding.id && $0.toWorkspaceID == nil }))
        check("store hour persisted", loaded.allSatisfy { $0.hourOfDay == 22 })

        var storedSettings = AppSettings()
        storedSettings.authorizationLevel = .sceneSwitch
        storedSettings.hasCompletedOnboarding = true
        try store.saveSettings(storedSettings)
        check("level1 settings persist", store.loadSettings().authorizationLevel == .sceneSwitch)

        let legacy = """
        {"weights":{"idle":30,"memory":25,"restartability":15,"workspace":80,"foreground":999,"idleCapMinutes":120,"memoryCapMB":8192,"noneBelow":30,"throttleBelow":60,"freezeBelow":85},"matchingWindowMinutes":12,"matchingThreshold":0.2,"sampleIntervalSeconds":3,"hasCompletedOnboarding":true,"showOnlyActionable":false}
        """
        let decodedLegacy = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        check("legacy settings default to level0", decodedLegacy.authorizationLevel == .suggestOnly && decodedLegacy.matchingWindowMinutes == 12)
        check("legacy jaccard threshold migrates to evidence", abs(decodedLegacy.matchingThreshold - WorkspaceMatcher.defaultMinEvidence) < 0.0001)

        let forcedAuto = """
        {"authorizationLevel":2,"weights":{"idle":30,"memory":25,"restartability":15,"workspace":80,"foreground":999,"idleCapMinutes":120,"memoryCapMB":8192,"noneBelow":30,"throttleBelow":60,"freezeBelow":85},"matchingWindowMinutes":10,"matchingThreshold":0.2,"sampleIntervalSeconds":3,"hasCompletedOnboarding":true,"showOnlyActionable":false}
        """
        let decodedAuto = try JSONDecoder().decode(AppSettings.self, from: Data(forcedAuto.utf8))
        check("level2 settings coerce to level0", decodedAuto.authorizationLevel == .suggestOnly)

        check("level1 available", AuthorizationLevel.sceneSwitch.isAvailable)
        check("level2 unavailable", !AuthorizationLevel.fullyAutomatic.isAvailable)

        return failures
    }
}
