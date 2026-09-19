import AppKit
import Darwin
import Foundation
import ResourceStewardCore

@main
enum StewardChecks {
    static func main() throws {
        var failures: [String] = []
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("ok   \(name)")
            } else {
                print("FAIL \(name)")
                failures.append(name)
            }
        }

        let snapA = ProcessSnapshot(
            timestamp: Date(timeIntervalSince1970: 1),
            pid: 9, uid: 501, bundleID: "com.example.app", processName: "Example",
            memoryFootprintMB: 100, cpuPercent: 1, isForeground: false, idleSeconds: 30
        )
        let snapB = ProcessSnapshot(
            timestamp: Date(timeIntervalSince1970: 99),
            pid: 9, uid: 501, bundleID: "com.example.app", processName: "Example",
            memoryFootprintMB: 100.2, cpuPercent: 1.2, isForeground: false, idleSeconds: 40
        )
        check("snapshot equality ignores timestamp and small idle drift", snapA == snapB)
        let snapC = ProcessSnapshot(
            timestamp: snapA.timestamp,
            pid: 9, uid: 501, bundleID: "com.example.app", processName: "Example",
            memoryFootprintMB: 100, cpuPercent: 1, isForeground: true, idleSeconds: 30
        )
        check("snapshot equality sees foreground change", snapA != snapC)

        check("normalize mid", abs(ReclaimScorer.normalize(60, cap: 120) - 0.5) < 0.0001)
        check("normalize cap", ReclaimScorer.normalize(240, cap: 120) == 1)
        check("normalize floor", ReclaimScorer.normalize(-10, cap: 120) == 0)

        let foreground = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 42, uid: 501, bundleID: "com.example.idle", processName: "IdleApp",
                memoryFootprintMB: 4096, cpuPercent: 0, isForeground: true, idleSeconds: 10_000
            ),
            workspace: nil
        )
        check("foreground zeroes score", foreground.score == 0 && foreground.suggestedAction == .none)
        check("foreground penalty large", foreground.components.foregroundPenalty > 100)

        let inWorkspace = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 99, uid: 501, bundleID: "com.jetbrains.WebStorm", processName: "WebStorm",
                memoryFootprintMB: 6000, cpuPercent: 1, isForeground: false, idleSeconds: 8_000
            ),
            workspace: Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.WebStorm"])
        )
        check("workspace core not suggested", inWorkspace.suggestedAction == .none && inWorkspace.isInCurrentWorkspace && inWorkspace.score < 30)

        let chrome = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 77, uid: 501, bundleID: "com.google.Chrome", processName: "Google Chrome",
                memoryFootprintMB: 8192, cpuPercent: 0, isForeground: false, idleSeconds: 120 * 60
            ),
            workspace: nil
        )
        check("idle heavy chrome reaches quit", chrome.score >= 85 && chrome.suggestedAction == .quit)

        let offSceneChrome = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 78, uid: 501, bundleID: "com.google.Chrome", processName: "Google Chrome",
                memoryFootprintMB: 800, cpuPercent: 0, isForeground: false, idleSeconds: 5 * 60
            ),
            workspace: Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.goland"])
        )
        check(
            "off-scene chrome is throttle or quit, never freeze",
            (offSceneChrome.suggestedAction == .throttle || offSceneChrome.suggestedAction == .quit)
                && offSceneChrome.suggestedAction != .freeze
        )
        check("off-scene bonus applied", offSceneChrome.components.offWorkspaceContribution >= 20)

        let idleCodex = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 79, uid: 501, bundleID: "com.openai.codex", processName: "ChatGPT",
                memoryFootprintMB: 369, cpuPercent: 0, isForeground: false, idleSeconds: 53 * 60
            ),
            workspace: Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.goland"])
        )
        check("long-idle off-scene app never freeze", idleCodex.suggestedAction != .freeze)

        let windowedIdle = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 80, uid: 501, bundleID: "com.sublimetext.4", processName: "Sublime Text",
                memoryFootprintMB: 400, cpuPercent: 0, isForeground: false, ownsWindows: true, idleSeconds: 53 * 60
            ),
            workspace: Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.goland"])
        )
        check("windowed idle app does not suggest freeze", windowedIdle.suggestedAction != .freeze)

        check("chronod is not suggestable", !UserFacingAppPolicy.isSuggestable(bundleID: "com.apple.chronod", processName: "chronod"))
        check("controlstrip is not auto eligible", !UserFacingAppPolicy.isAutoEligible(bundleID: "com.apple.controlstrip", processName: "Control Strip"))
        check("safari is suggestable", UserFacingAppPolicy.isSuggestable(bundleID: "com.apple.Safari", processName: "Safari"))
        check("chrome is auto eligible", UserFacingAppPolicy.isAutoEligible(bundleID: "com.google.Chrome", processName: "Chrome"))
        check("widget extension is not suggestable", UserFacingAppPolicy.isWidgetOrExtension(bundleID: "com.apple.ScreenTimeWidgetApplication", processName: "Screen Time"))

        let notesWindow = WindowSurface(ownerPID: 24088, layer: 0, width: 800, height: 600)
        let menuBar = WindowSurface(ownerPID: 24088, layer: 25, width: 400, height: 22)
        let tiny = WindowSurface(ownerPID: 99, layer: 0, width: 1, height: 1)
        let invisible = WindowSurface(ownerPID: 88, layer: 0, width: 100, height: 100, alpha: 0)
        check("layer 0 window participates", notesWindow.participatesInCompositor)
        check("menu bar does not participate", !menuBar.participatesInCompositor)
        check("tiny window skipped", !tiny.participatesInCompositor)
        check("zero alpha skipped", !invisible.participatesInCompositor)
        check("owner pids ignore non-surfaces", WindowedProcessPolicy.ownerPIDs(from: [notesWindow, menuBar, tiny, invisible]) == [24088])
        check("regular app fail-closed without list", WindowedProcessPolicy.snapshotOwnsWindows(pid: 1, isRegularApp: true, ownerPIDs: nil))
        check("daemon not assumed windowed", !WindowedProcessPolicy.snapshotOwnsWindows(pid: 1, isRegularApp: false, ownerPIDs: nil))
        check("pid in list owns windows", WindowedProcessPolicy.snapshotOwnsWindows(pid: 24088, isRegularApp: true, ownerPIDs: [24088]))
        check("pid not in list has no windows", !WindowedProcessPolicy.snapshotOwnsWindows(pid: 2, isRegularApp: true, ownerPIDs: [24088]))
        check("unsafe when window list missing", WindowedProcessPolicy.isUnsafeToFreeze(pid: 1, bundleID: nil, ownerPIDs: nil))
        check("unsafe when pid owns window", WindowedProcessPolicy.isUnsafeToFreeze(pid: 24088, bundleID: "com.apple.Notes", ownerPIDs: [24088]))
        check("safe when pid has no window", !WindowedProcessPolicy.isUnsafeToFreeze(pid: 9, bundleID: nil, ownerPIDs: [24088]))
        let parsedWindow = WindowedProcessPolicy.parse([
            "kCGWindowOwnerPID": 24088,
            "kCGWindowLayer": 0,
            "kCGWindowAlpha": 1.0,
            "kCGWindowBounds": ["Width": 800.0, "Height": 600.0]
        ])
        check("parse window owner", parsedWindow?.ownerPID == 24088 && parsedWindow?.participatesInCompositor == true)

        let cachedExecutor = ActionExecutor()
        cachedExecutor.windowOwnerPIDs = [24088]
        cachedExecutor.reuseWindowOwnerPIDs = true
        check(
            "cached owner set marks windowed pid unsafe",
            cachedExecutor.isUnsafeToFreeze(24088, "com.apple.Notes")
        )
        check(
            "cached owner set marks other pid safe",
            !cachedExecutor.isUnsafeToFreeze(9, nil)
        )
        cachedExecutor.windowOwnerPIDs = nil
        check(
            "cached nil owner set fails closed",
            cachedExecutor.isUnsafeToFreeze(9, nil)
        )
        cachedExecutor.reuseWindowOwnerPIDs = false

        let emptyPrevious: Set<String> = []
        let frozenOnce = [
            FrozenProcess(pid: 42, bundleID: "com.example.app", processName: "Example", action: .freeze)
        ]
        check(
            "persist writes when signature changes",
            FrozenPersistPolicy.shouldReplace(previous: emptyPrevious, current: frozenOnce)
        )
        check(
            "persist skips when signature unchanged",
            !FrozenPersistPolicy.shouldReplace(
                previous: FrozenPersistPolicy.signature(frozenOnce),
                current: frozenOnce
            )
        )
        check(
            "persist writes when pid leaves set",
            FrozenPersistPolicy.shouldReplace(
                previous: FrozenPersistPolicy.signature(frozenOnce),
                current: []
            )
        )

        check("default sample interval is 5s", abs(AppSettings.default.sampleIntervalSeconds - 5) < 0.001)
        let decodedIntervalDefault = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"matchingWindowMinutes":10}"#.utf8)
        )
        check(
            "missing sampleIntervalSeconds decodes to 5",
            abs(decodedIntervalDefault.sampleIntervalSeconds - 5) < 0.001
        )
        check("gpu sample interval is 20s", abs(SystemMonitor.gpuSampleIntervalSeconds - 20) < 0.001)

        check("threshold none", ReclaimScorer.suggestedAction(for: 10) == .none)
        check("threshold throttle", ReclaimScorer.suggestedAction(for: 30) == .throttle)
        check("threshold mid-score is throttle not freeze", ReclaimScorer.suggestedAction(for: 60) == .throttle)
        check("threshold quit", ReclaimScorer.suggestedAction(for: 85) == .quit)

        let launchd = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 1, uid: 0, bundleID: nil, processName: "launchd",
                memoryFootprintMB: 200, cpuPercent: 0, isForeground: false, idleSeconds: 10_000
            ),
            workspace: nil
        )
        check("protected launchd", launchd.isProtected && launchd.suggestedAction == .none)

        let shadowrocket = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 888, uid: 501, bundleID: "com.liguangming.Shadowrocket", processName: "Shadowrocket",
                memoryFootprintMB: 180, cpuPercent: 2, isForeground: false, idleSeconds: 20_000
            ),
            workspace: nil
        )
        check("shadowrocket keep-alive protected", shadowrocket.isProtected && shadowrocket.suggestedAction == .none)
        check("shadowrocket detected by bundle", KeepAlivePolicy.isKeepAlive(bundleID: "com.liguangming.Shadowrocket", processName: "Shadowrocket"))
        check("clashx detected by name", KeepAlivePolicy.isKeepAlive(bundleID: "com.example.foo", processName: "ClashX Pro"))
        check("chrome is not keep-alive", !KeepAlivePolicy.isKeepAlive(bundleID: "com.google.Chrome", processName: "Google Chrome"))
        check("orbstack vmgr keep-alive", KeepAlivePolicy.isKeepAlive(bundleID: "dev.kdrag0n.MacVirt.vmgr", processName: "OrbStack Helper"))
        check("orbstack app keep-alive", KeepAlivePolicy.isKeepAlive(bundleID: "dev.kdrag0n.MacVirt", processName: "OrbStack"))
        check("docker desktop keep-alive", KeepAlivePolicy.isKeepAlive(bundleID: "com.docker.docker", processName: "Docker Desktop"))
        check("colima keep-alive by name", KeepAlivePolicy.isKeepAlive(bundleID: nil, processName: "colima"))
        check("sublime is not keep-alive", !KeepAlivePolicy.isKeepAlive(bundleID: "com.sublimetext.4", processName: "Sublime Text"))

        let vmgr = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 9779, uid: 501, bundleID: "dev.kdrag0n.MacVirt.vmgr", processName: "OrbStack Helper",
                path: "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app",
                memoryFootprintMB: 2500, cpuPercent: 12, isForeground: false, idleSeconds: 80_000
            ),
            workspace: nil
        )
        check("orbstack vmgr score zero", vmgr.isProtected && vmgr.score == 0 && vmgr.suggestedAction == .none)

        let refuseVmgr = ActionExecutor().execute(
            action: .freeze,
            snapshot: ProcessSnapshot(
                pid: 9779, uid: getuid(), bundleID: "dev.kdrag0n.MacVirt.vmgr", processName: "OrbStack Helper",
                memoryFootprintMB: 2500, cpuPercent: 12, isForeground: false, idleSeconds: 80_000
            )
        )
        check("refuses to freeze orbstack vmgr", !refuseVmgr.ok)

        check("tencent meeting is audio category", CategoryBanPolicy.match(bundleID: "com.tencent.meeting", processName: "TencentMeeting") == .audioMeetingScreen)
        check("screen studio fragment", CategoryBanPolicy.match(bundleID: "app.macked.screenstudio", processName: "Screen Studio") == .audioMeetingScreen)
        check("wechat is messaging", CategoryBanPolicy.match(bundleID: "com.tencent.xinWeChat", processName: "WeChat") == .instantMessaging)
        check("lark fragment", CategoryBanPolicy.match(bundleID: "com.electron.lark", processName: "Lark") == .instantMessaging)
        check("raycast is a11y", CategoryBanPolicy.match(bundleID: "com.raycast.macos", processName: "Raycast") == .accessibilityInputShell)
        check("macs fan control is a11y", CategoryBanPolicy.match(bundleID: "com.crystalidea.macsfancontrol", processName: "Macs Fan Control") == .accessibilityInputShell)
        check("squirrel ime fragment", CategoryBanPolicy.match(bundleID: "im.rime.inputmethod.Squirrel", processName: "Squirrel") == .accessibilityInputShell)
        check("notes is apple windowed", CategoryBanPolicy.match(bundleID: "com.apple.Notes", processName: "Notes") == .appleWindowedUI)
        check("safari is apple windowed", CategoryBanPolicy.match(bundleID: "com.apple.Safari", processName: "Safari") == .appleWindowedUI)
        check("openusage is local monitor", CategoryBanPolicy.match(bundleID: "com.robinebers.openusage", processName: "OpenUsage") == .localMonitorSelf)
        check("resource steward is local monitor", CategoryBanPolicy.match(bundleID: "cc.resourcesteward.app", processName: "ResourceSteward") == .localMonitorSelf)
        check("vpn still keep-alive category", CategoryBanPolicy.match(bundleID: "com.liguangming.Shadowrocket", processName: "Shadowrocket") == .keepAlive)
        check("orbstack still keep-alive category", CategoryBanPolicy.match(bundleID: "dev.kdrag0n.MacVirt.vmgr", processName: "OrbStack Helper") == .keepAlive)
        check("chrome has no category ban", CategoryBanPolicy.match(bundleID: "com.google.Chrome", processName: "Google Chrome") == nil)
        check("sublime has no category ban", CategoryBanPolicy.match(bundleID: "com.sublimetext.4", processName: "Sublime Text") == nil)

        check("meeting bans throttle and freeze", !CategoryBanPolicy.allows(.throttle, bundleID: "com.tencent.meeting", processName: "TencentMeeting") && !CategoryBanPolicy.allows(.freeze, bundleID: "com.tencent.meeting", processName: "TencentMeeting"))
        check("meeting does not suggest quit", !CategoryBanPolicy.allows(.quit, bundleID: "com.tencent.meeting", processName: "TencentMeeting"))
        check("wechat bans freeze and throttle", !CategoryBanPolicy.allows(.freeze, bundleID: "com.tencent.xinWeChat", processName: "WeChat") && !CategoryBanPolicy.allows(.throttle, bundleID: "com.tencent.xinWeChat", processName: "WeChat"))
        check("wechat may suggest quit", CategoryBanPolicy.allows(.quit, bundleID: "com.tencent.xinWeChat", processName: "WeChat"))
        check("notes bans freeze only", !CategoryBanPolicy.allows(.freeze, bundleID: "com.apple.Notes", processName: "Notes") && CategoryBanPolicy.allows(.throttle, bundleID: "com.apple.Notes", processName: "Notes"))
        check("chrome freeze still allowed", CategoryBanPolicy.allows(.freeze, bundleID: "com.google.Chrome", processName: "Google Chrome"))

        let meetingScore = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 7101, uid: 501, bundleID: "com.tencent.meeting", processName: "TencentMeeting",
                memoryFootprintMB: 1200, cpuPercent: 8, isForeground: false, idleSeconds: 20 * 60
            ),
            workspace: Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.goland"])
        )
        check("meeting score is not throttle or freeze", meetingScore.suggestedAction == .none)

        let wechatScore = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 7102, uid: 501, bundleID: "com.tencent.xinWeChat", processName: "WeChat",
                memoryFootprintMB: 900, cpuPercent: 1, isForeground: false, idleSeconds: 8 * 60
            ),
            workspace: Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.goland"])
        )
        check("wechat does not suggest freeze or throttle", wechatScore.suggestedAction == .none || wechatScore.suggestedAction == .quit)

        let raycastScore = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 7103, uid: 501, bundleID: "com.raycast.macos", processName: "Raycast",
                memoryFootprintMB: 400, cpuPercent: 2, isForeground: false, idleSeconds: 30 * 60
            ),
            workspace: Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.goland"])
        )
        check("raycast score is none", raycastScore.suggestedAction == .none)

        let fanScore = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 7104, uid: 501, bundleID: "com.crystalidea.macsfancontrol", processName: "Macs Fan Control",
                memoryFootprintMB: 80, cpuPercent: 1, isForeground: false, idleSeconds: 40 * 60
            ),
            workspace: Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.goland"])
        )
        check("macs fan control score is none", fanScore.suggestedAction == .none)

        let notesScore = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 7105, uid: 501, bundleID: "com.apple.Notes", processName: "Notes",
                memoryFootprintMB: 300, cpuPercent: 0, isForeground: false, idleSeconds: 10 * 60
            ),
            workspace: Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.goland"])
        )
        check("notes does not suggest freeze", notesScore.suggestedAction != .freeze)

        let openUsageScore = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 7106, uid: 501, bundleID: "com.robinebers.openusage", processName: "OpenUsage",
                memoryFootprintMB: 150, cpuPercent: 3, isForeground: false, idleSeconds: 50 * 60
            ),
            workspace: Workspace(name: "办公", coreAppBundleIDs: ["com.jetbrains.goland"])
        )
        check("openusage score is none", openUsageScore.suggestedAction == .none)

        let refuseMeeting = ActionExecutor()
        refuseMeeting.isUnsafeToFreeze = { _, _ in false }
        let refuseMeetingResult = refuseMeeting.execute(
            action: .freeze,
            snapshot: ProcessSnapshot(
                pid: 910_001, uid: getuid(), bundleID: "com.tencent.meeting", processName: "TencentMeeting",
                memoryFootprintMB: 800, cpuPercent: 2, isForeground: false, idleSeconds: 600
            )
        )
        check("refuses to freeze tencent meeting", !refuseMeetingResult.ok && refuseMeetingResult.message.contains("冻结"))

        let refuseWeChat = ActionExecutor()
        refuseWeChat.isUnsafeToFreeze = { _, _ in false }
        let refuseWeChatResult = refuseWeChat.execute(
            action: .freeze,
            snapshot: ProcessSnapshot(
                pid: 910_002, uid: getuid(), bundleID: "com.tencent.xinWeChat", processName: "WeChat",
                memoryFootprintMB: 600, cpuPercent: 1, isForeground: false, idleSeconds: 600
            )
        )
        check("refuses to freeze wechat", !refuseWeChatResult.ok && refuseWeChatResult.message.contains("冻结"))

        let refuseWeChatThrottle = ActionExecutor().execute(
            action: .throttle,
            snapshot: ProcessSnapshot(
                pid: 910_003, uid: getuid(), bundleID: "com.tencent.xinWeChat", processName: "WeChat",
                memoryFootprintMB: 600, cpuPercent: 1, isForeground: false, idleSeconds: 600
            )
        )
        check("refuses to throttle wechat", !refuseWeChatThrottle.ok && refuseWeChatThrottle.message.contains("即时"))

        let refuseRaycast = ActionExecutor()
        refuseRaycast.isUnsafeToFreeze = { _, _ in false }
        let refuseRaycastResult = refuseRaycast.execute(
            action: .freeze,
            snapshot: ProcessSnapshot(
                pid: 910_004, uid: getuid(), bundleID: "com.raycast.macos", processName: "Raycast",
                memoryFootprintMB: 200, cpuPercent: 1, isForeground: false, idleSeconds: 600
            )
        )
        check("refuses to freeze raycast", !refuseRaycastResult.ok && refuseRaycastResult.message.contains("冻结"))

        let refuseFan = ActionExecutor().execute(
            action: .throttle,
            snapshot: ProcessSnapshot(
                pid: 910_005, uid: getuid(), bundleID: "com.crystalidea.macsfancontrol", processName: "Macs Fan Control",
                memoryFootprintMB: 80, cpuPercent: 1, isForeground: false, idleSeconds: 600
            )
        )
        check("refuses to throttle macs fan control", !refuseFan.ok && refuseFan.message.contains("辅助"))

        let refuseNotes = ActionExecutor()
        refuseNotes.isUnsafeToFreeze = { _, _ in false }
        let refuseNotesResult = refuseNotes.execute(
            action: .freeze,
            snapshot: ProcessSnapshot(
                pid: 910_006, uid: getuid(), bundleID: "com.apple.Notes", processName: "Notes",
                memoryFootprintMB: 140, cpuPercent: 0, isForeground: false, idleSeconds: 600
            )
        )
        check("refuses to freeze notes even if headless", !refuseNotesResult.ok && refuseNotesResult.message.contains("冻结"))

        let refuseOpenUsage = ActionExecutor()
        refuseOpenUsage.isUnsafeToFreeze = { _, _ in false }
        let refuseOpenUsageResult = refuseOpenUsage.execute(
            action: .freeze,
            snapshot: ProcessSnapshot(
                pid: 910_007, uid: getuid(), bundleID: "com.robinebers.openusage", processName: "OpenUsage",
                memoryFootprintMB: 120, cpuPercent: 2, isForeground: false, idleSeconds: 600
            )
        )
        check("refuses to freeze openusage", !refuseOpenUsageResult.ok && refuseOpenUsageResult.message.contains("冻结"))

        let blacklisted = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 1234, uid: 501, bundleID: "com.example.fragile", processName: "Fragile",
                memoryFootprintMB: 4000, cpuPercent: 0, isForeground: false, idleSeconds: 8000
            ),
            workspace: nil,
            blacklist: ["com.example.fragile"]
        )
        check("blacklist zeroes", blacklisted.score == 0 && blacklisted.suggestedAction == .none)

        check("chrome renderer roots to chrome", ProcessFamily.rootBundleID(from: "com.google.Chrome.helper.renderer") == "com.google.Chrome")
        check("wechat helper roots to wechat", ProcessFamily.rootBundleID(from: "com.tencent.xinWeChat.WeChatHelper") == "com.tencent.xinWeChat")
        check("wechat flue roots to wechat", ProcessFamily.rootBundleID(from: "com.tencent.flue.WeChatAppEx") == "com.tencent.xinWeChat")
        check("electron helper roots to parent", ProcessFamily.rootBundleID(from: "com.anysphere.sand.electron-helper.Renderer") == "com.anysphere.sand")
        check("chrome gpu helper roots to chrome", ProcessFamily.rootBundleID(from: "com.google.Chrome.helper.gpu") == "com.google.Chrome")
        check("electron helper roots to parent", ProcessFamily.rootBundleID(from: "com.figma.Desktop.helper") == "com.figma.Desktop")
        check("plain app is its own root", ProcessFamily.rootBundleID(from: "com.jetbrains.WebStorm") == "com.jetbrains.WebStorm")
        check("webstorm helper roots to webstorm", ProcessFamily.rootBundleID(from: "com.jetbrains.WebStorm.helper.renderer") == "com.jetbrains.WebStorm")
        check("pycharm ce still jetbrains", abs(RestartabilityTable.bonus(bundleID: "com.jetbrains.pycharm.ce", processName: "PyCharm") - 0.15) < 0.0001)
        check("goland is hard to restart", abs(RestartabilityTable.bonus(bundleID: "com.jetbrains.goland", processName: "GoLand") - 0.15) < 0.0001)
        check("jetbrains toolbox is milder", abs(RestartabilityTable.bonus(bundleID: "com.jetbrains.toolbox", processName: "JetBrains Toolbox") - 0.45) < 0.0001)
        check("firefox plugincontainer alias", ProcessFamily.rootBundleID(from: "org.mozilla.plugincontainer") == "org.mozilla.firefox")
        check("orbstack vmgr roots to orbstack", ProcessFamily.rootBundleID(from: "dev.kdrag0n.MacVirt.vmgr") == "dev.kdrag0n.MacVirt")
        check("orbstack scli roots to orbstack", ProcessFamily.rootBundleID(from: "dev.kdrag0n.MacVirt.scli") == "dev.kdrag0n.MacVirt")
        check("orbstack main is its own root", ProcessFamily.rootBundleID(from: "dev.kdrag0n.MacVirt") == "dev.kdrag0n.MacVirt")
        check("orbstack vmgr is companion", ProcessFamily.isCompanion(bundleID: "dev.kdrag0n.MacVirt.vmgr", processName: "OrbStack Helper"))
        check(
            "opening chrome thaws chrome helper freeze",
            ProcessFamily.matchesUserOpen(
                frozenBundleID: "com.google.Chrome.helper.renderer",
                frozenName: "Google Chrome Helper (Renderer)",
                openedBundleID: "com.google.Chrome",
                openedName: "Google Chrome"
            )
        )
        check(
            "opening chrome does not thaw safari",
            !ProcessFamily.matchesUserOpen(
                frozenBundleID: "com.apple.Safari",
                frozenName: "Safari",
                openedBundleID: "com.google.Chrome",
                openedName: "Google Chrome"
            )
        )
        check(
            "empty open does not match empty freeze",
            !ProcessFamily.matchesUserOpen(
                frozenBundleID: "",
                frozenName: "sleep",
                openedBundleID: "",
                openedName: ""
            )
        )
        check("renderer is companion", ProcessFamily.isCompanion(bundleID: "com.google.Chrome.helper.renderer", processName: "Google Chrome Helper (Renderer)"))
        check("chrome main is not companion", !ProcessFamily.isCompanion(bundleID: "com.google.Chrome", processName: "Google Chrome"))
        check("identity keys include parent", ProcessFamily.identityKeys(bundleID: "com.google.Chrome.helper.renderer", processName: "Renderer").contains("com.google.Chrome"))

        let chromeMainSnap = ProcessSnapshot(
            pid: 10, uid: 501, bundleID: "com.google.Chrome", processName: "Google Chrome",
            memoryFootprintMB: 400, cpuPercent: 1, isForeground: true, idleSeconds: 2
        )
        let chromeRendererSnap = ProcessSnapshot(
            pid: 11, uid: 501, bundleID: "com.google.Chrome.helper.renderer",
            processName: "Google Chrome Helper (Renderer)",
            memoryFootprintMB: 1200, cpuPercent: 0, isForeground: false, idleSeconds: 8000
        )
        let familyGroups = AppCoordinator.grouped([
            ProcessViewModel(snapshot: chromeMainSnap, score: ReclaimScorer.score(snapshot: chromeMainSnap, workspace: nil), appPath: nil),
            ProcessViewModel(snapshot: chromeRendererSnap, score: ReclaimScorer.score(snapshot: chromeRendererSnap, workspace: nil), appPath: nil)
        ])
        check("chrome family grouped together", familyGroups.count == 1 && familyGroups[0].members.count == 2)
        check("chrome family key is parent", familyGroups.first?.key == "com.google.Chrome")
        check("chrome family counts companions", familyGroups.first?.companionCount == 1)

        let exampleMain = ProcessSnapshot(
            pid: 20, uid: 501, bundleID: "com.example.app", processName: "Example",
            path: "/Applications/Example.app/Contents/MacOS/Example",
            memoryFootprintMB: 80, cpuPercent: 1, isForeground: false, idleSeconds: 10
        )
        let exampleChild = ProcessSnapshot(
            pid: 21, uid: 501, bundleID: nil, processName: "ExampleWorker",
            path: "/Applications/Example.app/Contents/MacOS/ExampleWorker",
            memoryFootprintMB: 20, cpuPercent: 0, isForeground: false, idleSeconds: 10,
            parentPID: 20
        )
        let exampleHint = AppProcessHint(
            pid: 20,
            bundleID: "com.example.app",
            name: "Example",
            bundlePath: "/Applications/Example.app",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let treeKeys = ProcessGrouper.keys(snapshots: [exampleMain, exampleChild], hints: [exampleHint])
        check("parent pid child joins running app group", treeKeys[20] == "com.example.app" && treeKeys[21] == "com.example.app")
        let noHintKeys = ProcessGrouper.keys(snapshots: [exampleMain, exampleChild])
        check(
            "parent tree joins without hints",
            noHintKeys[20] == "com.example.app" && noHintKeys[21] == "com.example.app"
        )
        check(
            "path inside app bundle",
            ProcessGrouper.pathIsInside(
                "/Applications/Example.app/Contents/MacOS/ExampleWorker",
                directory: "/Applications/Example.app"
            )
        )
        check(
            "path outside app bundle",
            !ProcessGrouper.pathIsInside("/usr/bin/yes", directory: "/Applications/Example.app")
        )
        let orphan = ProcessSnapshot(
            pid: 22, uid: 501, bundleID: "com.other.app", processName: "Other",
            path: "/Applications/Other.app/Contents/MacOS/Other",
            memoryFootprintMB: 10, cpuPercent: 0, isForeground: false, idleSeconds: 10
        )
        let mixedKeys = ProcessGrouper.keys(snapshots: [exampleMain, orphan], hints: [exampleHint])
        check("unrelated apps stay separate", mixedKeys[20] != mixedKeys[22])

        let sameGen = ProcessGeneration(pid: 42, startUnix: 100.5)
        check("generation matches same start", sameGen.sameGeneration(ProcessGeneration(pid: 42, startUnix: 100.5)))
        check("generation rejects reused pid", !sameGen.sameGeneration(ProcessGeneration(pid: 42, startUnix: 200)))
        check("unknown generation does not match known", !ProcessGeneration(pid: 42).sameGeneration(sameGen))

        let helperInWorkspace = ReclaimScorer.score(
            snapshot: chromeRendererSnap,
            workspace: Workspace(name: "Web", coreAppBundleIDs: ["com.google.Chrome"])
        )
        check("helper inherits parent workspace", helperInWorkspace.isInCurrentWorkspace)

        let helperForeground = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 12, uid: 501, bundleID: "com.google.Chrome.helper.renderer",
                processName: "Google Chrome Helper (Renderer)",
                memoryFootprintMB: 1200, cpuPercent: 0, isForeground: true, idleSeconds: 8000
            ),
            workspace: nil
        )
        check("foreground helper not suggested", helperForeground.score == 0 && helperForeground.suggestedAction == .none)

        let refuseRenderer = ActionExecutor().execute(action: .throttle, snapshot: chromeRendererSnap)
        check("refuses independent renderer throttle", !refuseRenderer.ok && refuseRenderer.message.contains("Helper"))
        let refuseFreeze = ActionExecutor().execute(action: .freeze, snapshots: [chromeRendererSnap], groupBundleID: chromeRendererSnap.bundleID)
        check("refuses independent renderer freeze", !refuseFreeze.ok)
        check(
            "family batch is not independent companion",
            !ProcessFamily.isIndependentCompanionAction(snapshots: [chromeMainSnap, chromeRendererSnap])
        )

        func stubGroup(name: String, bundle: String, pid: Int32, memory: Double, score: Double, foreground: Bool = false) -> ProcessGroupViewModel {
            let snapshot = ProcessSnapshot(
                pid: pid, uid: 501, bundleID: bundle, processName: name,
                memoryFootprintMB: memory, cpuPercent: 0, isForeground: foreground, idleSeconds: 60
            )
            let record = ReclaimScoreRecord(
                pid: pid, bundleID: bundle, processName: name, score: score,
                components: ScoreComponents(idleContribution: 0, memorySizeContribution: 0, restartabilityContribution: 0, workspacePenalty: 0, foregroundPenalty: 0),
                suggestedAction: ReclaimScorer.suggestedAction(for: score),
                estimatedReleaseMB: memory, isProtected: false, isInCurrentWorkspace: false
            )
            return ProcessGroupViewModel(
                key: bundle,
                members: [ProcessViewModel(snapshot: snapshot, score: record, appPath: nil)]
            )
        }
        var crowded = (1...90).map { i in
            stubGroup(name: "Idle\(i)", bundle: "dev.idle.\(i)", pid: Int32(1000 + i), memory: 12, score: 45)
        }
        crowded.append(stubGroup(name: "Google Chrome", bundle: "com.google.Chrome", pid: 10, memory: 2400, score: 0, foreground: true))
        let listed = AppCoordinator.listed(crowded, limit: 80)
        check("listed keeps foreground chrome", listed.contains(where: { $0.key == "com.google.Chrome" }))
        check("listed respects limit", listed.count == 80)
        var memoryCrowd = (1...90).map { i in
            stubGroup(name: "Idle\(i)", bundle: "dev.idle.\(i)", pid: Int32(2000 + i), memory: 12, score: 50)
        }
        memoryCrowd.append(stubGroup(name: "Google Chrome", bundle: "com.google.Chrome", pid: 11, memory: 1800, score: 0))
        check(
            "listed keeps heavy chrome at score 0",
            AppCoordinator.listed(memoryCrowd, limit: 80).contains(where: { $0.key == "com.google.Chrome" })
        )

        let estimated = ReclaimScorer.estimatedReleaseMB(from: [
            ReclaimScoreRecord(
                pid: 1, bundleID: "x", processName: "x", score: 10,
                components: ScoreComponents(idleContribution: 0, memorySizeContribution: 0, restartabilityContribution: 0, workspacePenalty: 0, foregroundPenalty: 0),
                suggestedAction: .none, estimatedReleaseMB: 100, isProtected: false, isInCurrentWorkspace: false
            ),
            ReclaimScoreRecord(
                pid: 2, bundleID: "y", processName: "y", score: 70,
                components: ScoreComponents(idleContribution: 0, memorySizeContribution: 0, restartabilityContribution: 0, workspacePenalty: 0, foregroundPenalty: 0),
                suggestedAction: .freeze, estimatedReleaseMB: 250, isProtected: false, isInCurrentWorkspace: false
            )
        ])
        check("estimated release sums actionable", abs(estimated - 250) < 0.01)

        let store = try LocalStore(path: NSTemporaryDirectory() + "rs-check-\(UUID().uuidString).sqlite")
        let workspace = Workspace(
            name: "Coding",
            coreAppBundleIDs: ["com.jetbrains.WebStorm", "com.googlecode.iterm2"],
            observedAppFrequency: ["com.apple.Safari": 3]
        )
        try store.saveWorkspace(workspace)
        let loaded = store.loadWorkspaces()
        check("workspace roundtrip", loaded.first?.name == "Coding" && loaded.first?.coreAppBundleIDs == workspace.coreAppBundleIDs)

        var settings = AppSettings()
        settings.matchingWindowMinutes = 15
        settings.hasCompletedOnboarding = true
        settings.weights.idle = 40
        try store.saveSettings(settings)
        let loadedSettings = store.loadSettings()
        check("settings persist", loadedSettings.matchingWindowMinutes == 15 && loadedSettings.weights.idle == 40)

        var withFavorites = AppSettings()
        withFavorites.favoriteApps = [FavoriteApp(bundleID: "com.sequel.ace", name: "Sequel Ace")]
        try store.saveSettings(withFavorites)
        let loadedFavorites = store.loadSettings()
        check(
            "favorites persist",
            loadedFavorites.favoriteBundleIDs.contains("com.sequel.ace")
                && loadedFavorites.favoriteApps.first?.name == "Sequel Ace"
        )
        let decodedLegacyFavorites = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"matchingWindowMinutes":11,"hasCompletedOnboarding":true}"#.utf8)
        )
        check("legacy settings have empty favorites", decodedLegacyFavorites.favoriteApps.isEmpty && decodedLegacyFavorites.matchingWindowMinutes == 11)

        check(
            "chrome helper matches chrome favorite",
            KeepAlivePolicy.isUserListed(
                bundleID: "com.google.Chrome.helper.renderer",
                extras: ["com.google.Chrome"]
            )
        )
        check(
            "unrelated app is not user listed",
            !KeepAlivePolicy.isUserListed(bundleID: "com.apple.Safari", extras: ["com.google.Chrome"])
        )

        let favoriteScore = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 4242, uid: 501, bundleID: "com.google.Chrome.helper.renderer", processName: "Chrome Helper",
                memoryFootprintMB: 2000, cpuPercent: 4, isForeground: false, idleSeconds: 20_000
            ),
            workspace: nil,
            favorites: ["com.google.Chrome"]
        )
        check("favorite helper score zero", favoriteScore.isProtected && favoriteScore.suggestedAction == .none)

        let favoriteExecutor = ActionExecutor()
        favoriteExecutor.extraKeepAliveBundleIDs = ["com.google.Chrome"]
        let refuseFavorite = favoriteExecutor.execute(
            action: .freeze,
            snapshot: ProcessSnapshot(
                pid: 4242, uid: getuid(), bundleID: "com.google.Chrome", processName: "Google Chrome",
                memoryFootprintMB: 800, cpuPercent: 1, isForeground: false, idleSeconds: 5000
            )
        )
        check("refuses to freeze user favorite", !refuseFavorite.ok)

        check(
            "favorite chrome still eligible for workspace picker",
            WorkspaceAppEligibility.shouldList(
                bundleID: "com.google.Chrome",
                name: "Chrome",
                path: "/Applications/Google Chrome.app",
                pid: 4243,
                activationPolicy: 0,
                isProtected: ProtectedProcessPolicy.isProtected(
                    pid: 4243,
                    bundleID: "com.google.Chrome",
                    processName: "Chrome"
                )
            )
        )

        try store.insertSnapshots([
            ProcessSnapshot(
                pid: 44, uid: 501, bundleID: "com.example.app", processName: "Example",
                memoryFootprintMB: 512, cpuPercent: 3, isForeground: false, idleSeconds: 120
            )
        ])
        try store.insertActivation(AppActivation(bundleID: "com.example.app", processName: "Example"))
        check("activation persist", store.loadActivations(since: Date().addingTimeInterval(-60)).count == 1)

        try store.addToBlacklist(bundleID: "com.example.app", reason: "user")
        check("blacklist persist", store.loadBlacklist().contains("com.example.app"))

        let warningHost = HostMemory(
            pageSize: 4096, physicalBytes: 16_000_000_000, freeBytes: 1_000_000_000,
            activeBytes: 4_000_000_000, inactiveBytes: 2_000_000_000, wiredBytes: 2_000_000_000,
            compressedBytes: 1_000_000_000, speculativeBytes: 0, purgeableBytes: 0,
            internalBytes: 8_000_000_000, externalBytes: 1_000_000_000,
            swapTotalBytes: 2_000_000_000, swapUsedBytes: 400_000_000,
            swapins: 1_000_000, swapouts: 1_000_000
        )
        check("cumulative swapouts do not force critical", warningHost.inferredPressure(sourceLevel: .normal) == .warning)
        let calmHost = HostMemory(
            pageSize: 4096, physicalBytes: 16_000_000_000, freeBytes: 8_000_000_000,
            activeBytes: 2_000_000_000, inactiveBytes: 1_000_000_000, wiredBytes: 1_000_000_000,
            compressedBytes: 200_000_000, speculativeBytes: 0, purgeableBytes: 0,
            internalBytes: 4_000_000_000, externalBytes: 1_000_000_000,
            swapTotalBytes: 0, swapUsedBytes: 0, swapins: 10, swapouts: 10
        )
        check("no swap is normal pressure", calmHost.inferredPressure(sourceLevel: .normal) == .normal)

        let host = SystemMonitor().sampleHost()
        check("host physical memory", host.physicalBytes > 0 && host.pageSize > 0)
        let processes = SystemMonitor().sampleProcesses()
        check("process sample nonempty", processes.contains(where: { $0.pid > 0 && !$0.name.isEmpty }))

        let cpuFromTicks = HostCPU.fromTicks(
            previousUser: 100, previousSystem: 40, previousIdle: 860, previousNice: 0,
            currentUser: 130, currentSystem: 50, currentIdle: 920, currentNice: 0
        )
        check("cpu percent from ticks", abs(cpuFromTicks.usagePercent - 40) < 0.01)
        check("cpu user percent from ticks", abs(cpuFromTicks.userPercent - 30) < 0.01)

        let monitor = SystemMonitor()
        let cpu = monitor.sampleCPU()
        check("live cpu percent in range", cpu.usagePercent >= 0 && cpu.usagePercent <= 100)
        let gpu = monitor.sampleGPU()
        if gpu.available {
            check("live gpu sample available", true)
            check("live gpu percent in range", gpu.usagePercent >= 0 && gpu.usagePercent <= 100)
        } else {
            print("skip live gpu sample (no IOAccelerator on this host)")
            check("live gpu unavailable is valid", gpu.usagePercent == 0)
        }
        check("gpu median of one", abs(SystemMonitor.median([42]) - 42) < 0.0001)
        check("gpu median rejects spike", abs(SystemMonitor.median([8, 9, 100, 10, 11]) - 10) < 0.0001)
        check("gpu intel name", HostGPU(usagePercent: 12, memoryUsedBytes: 1, memoryTotalBytes: 2, name: "IntelAccelerator", available: true).displayName == "Intel GPU")

        let gpuMonitor = SystemMonitor()
        let t0 = Date()
        _ = gpuMonitor.sampleGPU(now: t0, force: true)
        let afterFirst = gpuMonitor.gpuHardwareSampleCount
        _ = gpuMonitor.sampleGPU(now: t0.addingTimeInterval(1), force: false)
        let afterCached = gpuMonitor.gpuHardwareSampleCount
        _ = gpuMonitor.sampleGPU(now: t0.addingTimeInterval(SystemMonitor.gpuSampleIntervalSeconds + 1), force: false)
        let afterInterval = gpuMonitor.gpuHardwareSampleCount
        check("gpu first sample hits hardware", afterFirst >= 1)
        check("gpu reuses sample within interval", afterCached == afterFirst)
        check("gpu resamples after interval", afterInterval == afterFirst + 1)

        check("accessory apps appear in workspace picker", WorkspaceAppEligibility.shouldList(
            bundleID: "com.orbstack.orbstack",
            name: "OrbStack",
            path: "/Applications/OrbStack.app",
            pid: 4242,
            activationPolicy: 1,
            isProtected: false
        ))
        check("regular apps appear in workspace picker", WorkspaceAppEligibility.shouldList(
            bundleID: "com.google.Chrome",
            name: "Chrome",
            path: "/Applications/Google Chrome.app",
            pid: 4243,
            activationPolicy: 0,
            isProtected: false
        ))
        check("chrome renderer hidden from picker", !WorkspaceAppEligibility.shouldList(
            bundleID: "com.google.Chrome.helper.renderer",
            name: "Google Chrome Helper (Renderer)",
            path: "/Applications/Google Chrome.app",
            pid: 99,
            activationPolicy: 1,
            isProtected: false
        ))
        check("prohibited apps stay hidden", !WorkspaceAppEligibility.shouldList(
            bundleID: "com.apple.loginwindow",
            name: "loginwindow",
            path: "",
            pid: 88,
            activationPolicy: 2,
            isProtected: false
        ))
        check("protected apps stay hidden", !WorkspaceAppEligibility.shouldList(
            bundleID: "com.apple.dock",
            name: "Dock",
            path: "",
            pid: 200,
            activationPolicy: 0,
            isProtected: true
        ))

        let listedApps = RunningAppCatalog.collect(currentUID: getuid())
        check("workspace catalog nonempty", !listedApps.isEmpty)
        let listedIDs = Set(listedApps.map(\.bundleID))
        let eligibleAccessory = NSWorkspace.shared.runningApplications.filter { app in
            WorkspaceAppEligibility.shouldList(
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? "",
                path: app.bundleURL?.path ?? "",
                pid: app.processIdentifier,
                activationPolicy: Int(app.activationPolicy.rawValue),
                isProtected: ProtectedProcessPolicy.isProtected(
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier,
                    processName: app.localizedName ?? ""
                )
            ) && app.activationPolicy == .accessory
        }
        if !eligibleAccessory.isEmpty {
            check(
                "live accessory apps listed",
                eligibleAccessory.contains { listedIDs.contains($0.bundleIdentifier ?? "") }
            )
        }

        let retiredFreeze = ActionExecutor().execute(
            action: .freeze,
            snapshot: ProcessSnapshot(
                pid: 42,
                uid: UInt32(getuid()),
                bundleID: "com.example.app",
                processName: "Example",
                memoryFootprintMB: 1,
                cpuPercent: 0,
                isForeground: false,
                idleSeconds: 120
            )
        )
        check("freeze action is retired", !retiredFreeze.ok && retiredFreeze.message.contains("停用冻结"))

        try store.replaceFrozen([
            FrozenProcess(
                pid: 42,
                bundleID: "com.example.app",
                processName: "Example",
                action: .freeze,
                startUnix: 100
            )
        ])
        let loadedFrozen = store.loadFrozen()
        check("frozen persist roundtrip", loadedFrozen.contains(where: { $0.pid == 42 && $0.startUnix == 100 }))

        let skippedKeepAlive = ActionExecutor().restorePersisted([
            FrozenProcess(pid: 1_000_001, bundleID: "dev.kdrag0n.MacVirt.vmgr", processName: "OrbStack Helper", action: .freeze)
        ])
        check("restore does not re-freeze orbstack vmgr", skippedKeepAlive.isEmpty)
        let skippedWindowed = ActionExecutor()
        skippedWindowed.isUnsafeToFreeze = { _, _ in true }
        let skippedWindowedRestored = skippedWindowed.restorePersisted([
            FrozenProcess(pid: 1_000_002, bundleID: "com.apple.Notes", processName: "Notes", action: .freeze)
        ])
        check("restore does not re-freeze windowed app", skippedWindowedRestored.isEmpty)
        let skippedUnknownGen = ActionExecutor()
        skippedUnknownGen.isUnsafeToFreeze = { _, _ in false }
        let skippedUnknown = skippedUnknownGen.restorePersisted([
            FrozenProcess(
                pid: 1_000_004,
                bundleID: "com.example.old",
                processName: "Old",
                action: .freeze,
                startUnix: 0
            )
        ])
        check("restore skips unknown generation", skippedUnknown.isEmpty)

        let throttleSleep = Process()
        throttleSleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        throttleSleep.arguments = ["8"]
        try throttleSleep.run()
        let throttlePID = Int32(throttleSleep.processIdentifier)
        errno = 0
        let originalNice = getpriority(PRIO_PROCESS, UInt32(bitPattern: throttlePID))
        let throttleExecutor = ActionExecutor()
        throttleExecutor.isUnsafeToFreeze = { _, _ in false }
        let throttleResult = throttleExecutor.execute(
            action: .throttle,
            snapshot: ProcessSnapshot(
                pid: throttlePID,
                uid: UInt32(getuid()),
                bundleID: nil,
                processName: "sleep",
                memoryFootprintMB: 1,
                cpuPercent: 0,
                isForeground: false,
                idleSeconds: 120
            )
        )
        check("throttle sleep succeeds", throttleResult.ok && throttleExecutor.isThrottled(pid: throttlePID))
        check("throttle ledger keeps original nice", throttleExecutor.originalNice(pid: throttlePID) == originalNice)
        let unthrottleResult = throttleExecutor.unthrottle(pid: throttlePID)
        errno = 0
        let restoredNice = getpriority(PRIO_PROCESS, UInt32(bitPattern: throttlePID))
        if unthrottleResult.ok {
            check("unthrottle restores original nice", restoredNice == originalNice && !throttleExecutor.isThrottled(pid: throttlePID))
        } else {
            check(
                "unthrottle keeps ledger when kernel refuses to raise nice",
                throttleExecutor.isThrottled(pid: throttlePID)
                    && throttleExecutor.originalNice(pid: throttlePID) == originalNice
            )
        }
        throttleSleep.terminate()
        throttleSleep.waitUntilExit()

        var storedSettings = AppSettings()
        storedSettings.authorizationLevel = .sceneSwitch
        storedSettings.hasCompletedOnboarding = true
        try store.saveSettings(storedSettings)
        check("level1 settings persist", store.loadSettings().authorizationLevel == .sceneSwitch)

        let decodedLegacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data("""
            {"weights":{"idle":30,"memory":25,"restartability":15,"workspace":80,"foreground":999,"idleCapMinutes":120,"memoryCapMB":8192,"noneBelow":30,"throttleBelow":60,"freezeBelow":85},"matchingWindowMinutes":12,"matchingThreshold":0.2,"sampleIntervalSeconds":3,"hasCompletedOnboarding":true,"showOnlyActionable":false}
            """.utf8)
        )
        check("legacy settings default to level0", decodedLegacy.authorizationLevel == .suggestOnly && decodedLegacy.matchingWindowMinutes == 12)
        check("legacy jaccard threshold migrates to evidence", abs(decodedLegacy.matchingThreshold - 0.6) < 0.0001)
        check(
            "legacy scoring caps migrate",
            abs(decodedLegacy.weights.idleCapMinutes - 45) < 0.1
                && abs(decodedLegacy.weights.memoryCapMB - 2048) < 0.1
                && decodedLegacy.scoringRevision == 1
                && abs(decodedLegacy.weights.offWorkspace - 28) < 0.1
        )
        let decodedAuto = try JSONDecoder().decode(
            AppSettings.self,
            from: Data("""
            {"authorizationLevel":2,"weights":{"idle":30,"memory":25,"restartability":15,"workspace":80,"foreground":999,"idleCapMinutes":120,"memoryCapMB":8192,"noneBelow":30,"throttleBelow":60,"freezeBelow":85},"matchingWindowMinutes":10,"matchingThreshold":0.2,"sampleIntervalSeconds":3,"hasCompletedOnboarding":true,"showOnlyActionable":false}
            """.utf8)
        )
        check("level2 settings coerce to level0", decodedAuto.authorizationLevel == .suggestOnly)
        check("level1 available", AuthorizationLevel.sceneSwitch.isAvailable)
        check("level2 unavailable", !AuthorizationLevel.fullyAutomatic.isAvailable)

        failures.append(contentsOf: try JevChecks.run())

        if failures.isEmpty {
            print("\nAll checks passed.")
            return
        }
        print("\n\(failures.count) check(s) failed:")
        for name in failures { print(" - \(name)") }
        exit(1)
    }
}
