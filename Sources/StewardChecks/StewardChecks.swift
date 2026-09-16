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

        check("recency now is one", abs(WorkspaceMatcher.recency(minutesAgo: 0) - 1) < 0.0001)
        check("recency half life is half", abs(WorkspaceMatcher.recency(minutesAgo: 8) - 0.5) < 0.0001)

        let now = Date()
        let office = Workspace(
            name: "办公",
            coreAppBundleIDs: [
                "com.jetbrains.WebStorm",
                "com.jetbrains.intellij",
                "com.jetbrains.pycharm",
                "com.jetbrains.goland",
                "com.google.Chrome",
                "com.tinyspeck.slackmacgap",
                "com.googlecode.iterm2",
                "com.figma.Desktop",
                "com.docker.docker",
                "md.obsidian"
            ]
        )
        let fun = Workspace(
            name: "娱乐",
            coreAppBundleIDs: ["com.tencent.xinWeChat", "com.google.Chrome"]
        )
        func activation(_ bundle: String, name: String, minutesAgo: Double = 0) -> AppActivation {
            AppActivation(
                timestamp: now.addingTimeInterval(-minutesAgo * 60),
                bundleID: bundle,
                processName: name
            )
        }

        let low = WorkspaceMatcher.match(
            workspaces: [office],
            activations: [
                activation("com.apple.Music", name: "Music"),
                activation("com.apple.Maps", name: "Maps")
            ],
            now: now
        )
        check("unclassified when nothing matches", low.isUnclassified && low.displayName == "未分类")

        let high = WorkspaceMatcher.match(
            workspaces: [office, fun],
            activations: [
                activation("com.jetbrains.WebStorm", name: "WebStorm"),
                activation("com.googlecode.iterm2", name: "iTerm")
            ],
            now: now
        )
        check("picks office from jetbrains ide", high.workspace?.name == "办公" && high.similarity >= 1)

        check("empty workspaces unclassified", WorkspaceMatcher.match(
            workspaces: [],
            activations: [activation("com.apple.Safari", name: "Safari")],
            now: now
        ).isUnclassified)

        let stale = WorkspaceMatcher.match(
            workspaces: [office],
            activations: [activation("com.jetbrains.WebStorm", name: "WebStorm", minutesAgo: 60)],
            now: now,
            windowMinutes: 10
        )
        check("stale activations ignored", stale.isUnclassified && stale.activeBundleIDs.isEmpty)

        let codingSubset = WorkspaceMatcher.match(
            workspaces: [office, fun],
            activations: [
                activation("com.jetbrains.WebStorm", name: "WebStorm"),
                activation("com.google.Chrome", name: "Google Chrome")
            ],
            now: now
        )
        check(
            "few office apps still beat entertainment",
            codingSubset.workspace?.name == "办公" && (codingSubset.scoresByWorkspaceID[office.id] ?? 0) > (codingSubset.scoresByWorkspaceID[fun.id] ?? 0)
        )

        let chromeOnly = WorkspaceMatcher.match(
            workspaces: [office, fun],
            activations: [activation("com.google.Chrome", name: "Google Chrome")],
            now: now
        )
        check("chrome alone does not become entertainment", chromeOnly.isUnclassified)

        let wechatOnly = WorkspaceMatcher.match(
            workspaces: [office, fun],
            activations: [activation("com.tencent.xinWeChat", name: "WeChat")],
            now: now
        )
        check("wechat exclusive picks entertainment", wechatOnly.workspace?.name == "娱乐")

        let wechatChrome = WorkspaceMatcher.match(
            workspaces: [office, fun],
            activations: [
                activation("com.tencent.xinWeChat", name: "WeChat"),
                activation("com.google.Chrome", name: "Google Chrome")
            ],
            now: now
        )
        check("wechat plus chrome picks entertainment", wechatChrome.workspace?.name == "娱乐")

        let ideOnly = WorkspaceMatcher.match(
            workspaces: [office, fun],
            activations: [activation("com.jetbrains.intellij", name: "IntelliJ IDEA")],
            now: now
        )
        check("intellij alone still office despite large core list", ideOnly.workspace?.name == "办公")

        let webstormHelper = WorkspaceMatcher.match(
            workspaces: [office, fun],
            activations: [activation("com.jetbrains.WebStorm.helper.renderer", name: "WebStorm Helper")],
            now: now
        )
        check("jetbrains helper roots to ide", webstormHelper.workspace?.name == "办公")

        let stickyChrome = WorkspaceMatcher.match(
            workspaces: [office, fun],
            activations: [activation("com.google.Chrome", name: "Google Chrome")],
            now: now,
            stickyWorkspaceID: office.id
        )
        check("sticky office keeps chrome-only as office", stickyChrome.workspace?.name == "办公")

        let switchToFun = WorkspaceMatcher.match(
            workspaces: [office, fun],
            activations: [
                activation("com.jetbrains.WebStorm", name: "WebStorm", minutesAgo: 8),
                activation("com.tencent.xinWeChat", name: "WeChat"),
                activation("com.google.Chrome", name: "Google Chrome")
            ],
            now: now,
            stickyWorkspaceID: office.id
        )
        check("strong entertainment evidence leaves office", switchToFun.workspace?.name == "娱乐")

        let briefWechat = WorkspaceMatcher.match(
            workspaces: [office, fun],
            activations: [
                activation("com.jetbrains.WebStorm", name: "WebStorm"),
                activation("com.tencent.xinWeChat", name: "WeChat")
            ],
            now: now,
            stickyWorkspaceID: office.id
        )
        check("brief wechat does not leave office", briefWechat.workspace?.name == "办公")

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
        check("workspace core not suggested", inWorkspace.score == 0 && inWorkspace.suggestedAction == .none && inWorkspace.isInCurrentWorkspace)

        let chrome = ReclaimScorer.score(
            snapshot: ProcessSnapshot(
                pid: 77, uid: 501, bundleID: "com.google.Chrome", processName: "Google Chrome",
                memoryFootprintMB: 8192, cpuPercent: 0, isForeground: false, idleSeconds: 120 * 60
            ),
            workspace: nil
        )
        check("idle heavy chrome reaches quit", chrome.score >= 85 && chrome.suggestedAction == .quit)

        check("threshold none", ReclaimScorer.suggestedAction(for: 10) == .none)
        check("threshold throttle", ReclaimScorer.suggestedAction(for: 30) == .throttle)
        check("threshold freeze", ReclaimScorer.suggestedAction(for: 60) == .freeze)
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

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["8"]
        try sleeper.run()
        let sleepPID = Int32(sleeper.processIdentifier)
        let freezeSnapshot = ProcessSnapshot(
            pid: sleepPID,
            uid: UInt32(getuid()),
            bundleID: nil,
            processName: "sleep",
            memoryFootprintMB: 1,
            cpuPercent: 0,
            isForeground: false,
            idleSeconds: 120
        )
        let executor = ActionExecutor()
        let freezeResult = executor.execute(action: .freeze, snapshot: freezeSnapshot)
        check("freeze sleep succeeds", freezeResult.ok)
        check("frozen pid is tracked", executor.isFrozen(pid: sleepPID))
        check("frozen sleep is SSTOP", SystemMonitor().processStatus(pid: sleepPID) == 4)

        try store.replaceFrozen(executor.frozenProcesses)
        let loadedFrozen = store.loadFrozen()
        check("frozen persist roundtrip", loadedFrozen.contains(where: { $0.pid == sleepPID }))

        let restoredExecutor = ActionExecutor()
        let restored = restoredExecutor.restorePersisted(store.loadFrozen())
        check("restore keeps process stopped", SystemMonitor().processStatus(pid: sleepPID) == 4)
        check("restore tracks pid", restoredExecutor.isFrozen(pid: sleepPID) && restored.contains(where: { $0.pid == sleepPID }))

        let skippedKeepAlive = ActionExecutor().restorePersisted([
            FrozenProcess(pid: 1_000_001, bundleID: "dev.kdrag0n.MacVirt.vmgr", processName: "OrbStack Helper", action: .freeze)
        ])
        check("restore does not re-freeze orbstack vmgr", skippedKeepAlive.isEmpty)

        _ = executor.thaw(pid: sleepPID)
        let reapplied = restoredExecutor.restorePersisted(store.loadFrozen())
        check("restore re-freezes after resume", SystemMonitor().processStatus(pid: sleepPID) == 4 && reapplied.contains(where: { $0.pid == sleepPID }))

        let thawResult = restoredExecutor.thaw(pid: sleepPID)
        check("thaw sleep succeeds", thawResult.ok)

        let sleeperOpen = Process()
        sleeperOpen.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeperOpen.arguments = ["8"]
        try sleeperOpen.run()
        let openPID = Int32(sleeperOpen.processIdentifier)
        let openExecutor = ActionExecutor()
        check(
            "freeze for dock-thaw",
            openExecutor.execute(
                action: .freeze,
                snapshot: ProcessSnapshot(
                    pid: openPID,
                    uid: UInt32(getuid()),
                    bundleID: "com.example.frozen",
                    processName: "Example",
                    memoryFootprintMB: 1,
                    cpuPercent: 0,
                    isForeground: false,
                    idleSeconds: 120
                )
            ).ok
        )
        check("unrelated activation leaves freeze", openExecutor.thawMatchingActivation(bundleID: "com.apple.Safari", processName: "Safari") == 0)
        check("still frozen after unrelated open", SystemMonitor().processStatus(pid: openPID) == 4)
        check("dock thaw resumes matching freeze", openExecutor.thawMatchingActivation(bundleID: "com.example.frozen", processName: "Example") == 1)
        check("dock thaw process running", SystemMonitor().processStatus(pid: openPID) != 4)
        sleeperOpen.terminate()

        let sleeper2 = Process()
        sleeper2.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper2.arguments = ["8"]
        try sleeper2.run()
        let sleepPID2 = Int32(sleeper2.processIdentifier)
        let freezeSnapshot2 = ProcessSnapshot(
            pid: sleepPID2,
            uid: UInt32(getuid()),
            bundleID: nil,
            processName: "sleep",
            memoryFootprintMB: 1,
            cpuPercent: 0,
            isForeground: false,
            idleSeconds: 120
        )
        let quitExecutor = ActionExecutor()
        check("quit-path freeze", quitExecutor.execute(action: .freeze, snapshot: freezeSnapshot2).ok)
        check("quit-path frozen", SystemMonitor().processStatus(pid: sleepPID2) == 4)
        quitExecutor.thawAll()
        check("thawAll on quit resumes", SystemMonitor().processStatus(pid: sleepPID2) != 4)
        check("thawAll clears freeze list", quitExecutor.frozenProcesses.isEmpty)
        sleeper2.terminate()
        sleeper2.waitUntilExit()

        sleeper.terminate()
        sleeper.waitUntilExit()

        failures.append(contentsOf: try V2Checks.run())

        if failures.isEmpty {
            print("\nAll checks passed.")
            return
        }
        print("\n\(failures.count) check(s) failed:")
        for name in failures { print(" - \(name)") }
        exit(1)
    }
}
