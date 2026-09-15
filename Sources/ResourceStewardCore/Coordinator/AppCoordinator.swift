import AppKit
import Combine
import Darwin
import Foundation

@MainActor
public final class AppCoordinator: ObservableObject {
    @Published public private(set) var hostMemory: HostMemory = .empty
    @Published public private(set) var hostCPU: HostCPU = .empty
    @Published public private(set) var hostGPU: HostGPU = .unavailable
    @Published public private(set) var pressure: MemoryPressureLevel = .normal
    @Published public private(set) var processes: [ProcessViewModel] = []
    @Published public private(set) var processGroups: [ProcessGroupViewModel] = []
    @Published public private(set) var workspaces: [Workspace] = []
    @Published public var settings: AppSettings = .default
    @Published public private(set) var match: WorkspaceMatch = WorkspaceMatch(workspace: nil, similarity: 0, activeBundleIDs: [])
    @Published public private(set) var frozen: [FrozenProcess] = []
    @Published public private(set) var lastMessage: String?
    @Published public private(set) var lastMessageIsError = false
    @Published public private(set) var runningApps: [RunningAppInfo] = []
    @Published public private(set) var estimatedReleaseMB: Double = 0
    @Published public private(set) var isRunning = false
    @Published public private(set) var forecasts: [WorkspaceForecast] = []
    @Published public private(set) var forecastSampleCount: Int = 0
    @Published public private(set) var forecastScope: MarkovTimeScope = .allDay
    @Published public var selectedTab: PanelTab = .processes
    @Published public var pendingAction: PendingAction?

    public let store: LocalStore
    public let executor = ActionExecutor()

    private let monitor = SystemMonitor()
    private let pressureMonitor = MemoryPressureMonitor()
    private var collector: ContextCollector!
    private var timer: Timer?
    private var previousCPU: [Int32: (timeNs: UInt64, sampledAt: Date)] = [:]
    private var blacklist: Set<String> = []
    private var lastPersistAt = Date.distantPast
    private var lastPruneAt = Date.distantPast
    private var lastFrequencyUpdate: Date = .distantPast
    private var sceneState = SceneSwitchState()
    private var transitionCache: [WorkspaceTransition] = []

    public init(store: LocalStore) {
        self.store = store
        self.settings = store.loadSettings()
        self.workspaces = store.loadWorkspaces()
        self.blacklist = store.loadBlacklist()
        collector = ContextCollector { [weak self] activation in
            Task { @MainActor in
                self?.handleActivation(activation)
            }
        }
    }

    public convenience init() throws {
        try self.init(store: LocalStore())
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        NSApp.setActivationPolicy(.accessory)
        pressureMonitor.start()
        collector.start()
        thawLeftoverFreezes()
        transitionCache = store.loadWorkspaceTransitions()
        refresh()
        let interval = max(2, settings.sampleIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    public func stop() {
        executor.thawAll()
        frozen = []
        try? store.replaceFrozen([])
        timer?.invalidate()
        timer = nil
        collector.stop()
        pressureMonitor.stop()
        isRunning = false
    }

    public func refresh() {
        let host = monitor.sampleHost()
        let cpu = monitor.sampleCPU()
        let gpu = monitor.sampleGPU()
        let raw = monitor.sampleProcesses()
        let now = Date()
        let uid = getuid()

        var snapshots: [ProcessSnapshot] = []
        snapshots.reserveCapacity(raw.count)

        for sample in raw {
            let running = NSRunningApplication(processIdentifier: sample.pid)
            let bundleID = running?.bundleIdentifier ?? BundleIdentity.bundleID(fromPath: sample.path)
            let name = running?.localizedName ?? sample.name
            let path = running?.bundleURL?.path ?? BundleIdentity.appPath(fromExecutable: sample.path) ?? sample.path
            let cpu = cpuPercent(pid: sample.pid, cpuTimeNs: sample.cpuTimeNs, now: now)
            let snapshot = ProcessSnapshot(
                timestamp: now,
                pid: sample.pid,
                uid: sample.uid,
                bundleID: bundleID,
                processName: name,
                path: path,
                memoryFootprintMB: sample.memoryFootprintMB,
                cpuPercent: cpu,
                isForeground: collector.isForeground(bundleID: bundleID, processName: name),
                isAccessory: running?.activationPolicy == .accessory,
                idleSeconds: collector.idleSeconds(
                    for: bundleID,
                    processName: name,
                    startUnix: TimeInterval(sample.startUnix),
                    now: now
                ),
                startUnix: TimeInterval(sample.startUnix)
            )
            snapshots.append(snapshot)
            previousCPU[sample.pid] = (sample.cpuTimeNs, now)
        }

        executor.prune(livePIDs: Set(snapshots.map(\.pid)))
        persistFrozen()

        let windowStart = now.addingTimeInterval(-settings.matchingWindowMinutes * 60)
        var activations = store.loadActivations(since: windowStart)
        if activations.isEmpty, let fg = collector.lastForegroundBundleID {
            activations = [AppActivation(bundleID: fg, processName: collector.lastForegroundName ?? fg)]
        }
        let match = WorkspaceMatcher.match(
            workspaces: workspaces,
            activations: activations,
            now: now,
            windowMinutes: settings.matchingWindowMinutes,
            threshold: settings.matchingThreshold
        )

        if let current = match.workspace, now.timeIntervalSince(lastFrequencyUpdate) > 30 {
            updateObservedFrequency(workspace: current, active: match.activeBundleIDs)
            lastFrequencyUpdate = now
        }

        let records = ReclaimScorer.scoreAll(
            snapshots: snapshots,
            workspace: match.workspace,
            weights: settings.weights,
            blacklist: blacklist
        )
        let recordByPid = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })

        let models: [ProcessViewModel] = snapshots.compactMap { snapshot in
            guard let record = recordByPid[snapshot.pid] else { return nil }
            return ProcessViewModel(
                snapshot: snapshot,
                score: record,
                appPath: snapshot.path,
                appliedAction: executor.appliedAction(pid: snapshot.pid)
            )
        }

        hostMemory = host
        hostCPU = cpu
        hostGPU = gpu
        pressure = host.inferredPressure(sourceLevel: pressureMonitor.level)
        let grouped = Self.listed(
            Self.grouped(models).filter { group in
                if group.isForeground { return true }
                return group.members.contains {
                    $0.snapshot.memoryFootprintMB >= 8 || $0.score.score >= 20 || $0.snapshot.isForeground
                }
            }
        )
        processes = grouped.flatMap(\.members)
        processGroups = grouped
        self.match = match
        runningApps = RunningAppCatalog.mergingProcessSnapshots(
            existing: RunningAppCatalog.collect(currentUID: uid),
            snapshots: snapshots,
            currentUID: uid
        )
        handleSceneSwitch(match: match, groups: processGroups, now: now)
        processes = processes.map { model in
            ProcessViewModel(
                snapshot: model.snapshot,
                score: model.score,
                appPath: model.appPath,
                appliedAction: executor.appliedAction(pid: model.snapshot.pid)
            )
        }
        processGroups = Self.listed(Self.grouped(processes))
        frozen = executor.frozenProcesses
        persistFrozen()
        updateForecasts(from: match, now: now)
        estimatedReleaseMB = processGroups
            .filter { $0.effectiveSuggestion != .none }
            .reduce(0) { $0 + $1.totalMemoryMB }

        persistIfNeeded(snapshots: snapshots, now: now)
    }

    public var visibleGroups: [ProcessGroupViewModel] {
        let groups = processGroups
        if settings.showOnlyActionable {
            return groups.filter { $0.effectiveSuggestion != .none }
        }
        return groups
    }

    public func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        persistSettings()
    }

    public func persistSettings() {
        if !settings.authorizationLevel.isAvailable {
            settings.authorizationLevel = .suggestOnly
        }
        try? store.saveSettings(settings)
        if let timer, abs(timer.timeInterval - settings.sampleIntervalSeconds) > 0.4 {
            timer.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: max(2, settings.sampleIntervalSeconds), repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }
    }

    public func saveWorkspace(_ workspace: Workspace) {
        try? store.saveWorkspace(workspace)
        workspaces = store.loadWorkspaces()
        refresh()
    }

    public func deleteWorkspace(_ workspace: Workspace) {
        try? store.deleteWorkspace(id: workspace.id)
        workspaces = store.loadWorkspaces()
        refresh()
    }

    public func request(_ action: SuggestedAction, for group: ProcessGroupViewModel) {
        pendingAction = PendingAction(group: group, action: action)
    }

    public func confirmPending() {
        guard let pending = pendingAction else { return }
        pendingAction = nil
        let result = executor.execute(
            action: pending.action,
            snapshots: pending.group.members.map(\.snapshot),
            groupBundleID: pending.group.key.hasPrefix("pid:") ? pending.group.primary.snapshot.bundleID : pending.group.key
        )
        lastMessage = result.message
        lastMessageIsError = !result.ok
        try? store.insertFeedback(
            UserFeedback(
                bundleID: pending.group.score.bundleID,
                scoreAtDecisionTime: pending.group.score.score,
                userAction: result.ok ? UserFeedbackAction.accepted.rawValue : UserFeedbackAction.rejected.rawValue
            )
        )
        frozen = executor.frozenProcesses
        persistFrozen()
        refresh()
    }

    public func cancelPending() {
        if let pending = pendingAction {
            try? store.insertFeedback(
                UserFeedback(
                    bundleID: pending.group.score.bundleID,
                    scoreAtDecisionTime: pending.group.score.score,
                    userAction: UserFeedbackAction.rejected.rawValue
                )
            )
        }
        pendingAction = nil
    }

    public func thaw(pid: Int32) {
        let result = executor.thaw(pid: pid)
        lastMessage = result.message
        lastMessageIsError = !result.ok
        frozen = executor.frozenProcesses
        persistFrozen()
        refresh()
    }

    public func restorePriority(for group: ProcessGroupViewModel) {
        var ok = 0
        var last = ActionResult(ok: false, message: "没有可恢复的进程", action: .throttle, pid: 0)
        for member in group.members {
            last = executor.unthrottle(pid: member.snapshot.pid)
            if last.ok { ok += 1 }
        }
        if ok > 0 {
            lastMessage = "已恢复 \(group.displayName) 的 \(ok) 个进程的 CPU 优先级。"
            lastMessageIsError = false
        } else {
            lastMessage = last.message
            lastMessageIsError = true
        }
        refresh()
    }

    public func ignoreAndBlacklist(_ group: ProcessGroupViewModel) {
        let banned = ProcessFamily.rootBundleID(from: group.primary.snapshot.bundleID)
            ?? group.score.bundleID
        try? store.addToBlacklist(bundleID: banned, reason: "user")
        blacklist = store.loadBlacklist()
        try? store.insertFeedback(
            UserFeedback(
                bundleID: banned,
                scoreAtDecisionTime: group.score.score,
                userAction: UserFeedbackAction.manualOverride.rawValue
            )
        )
        refresh()
    }

    public static func grouped(_ models: [ProcessViewModel]) -> [ProcessGroupViewModel] {
        var buckets: [String: [ProcessViewModel]] = [:]
        for model in models {
            let key = ProcessFamily.familyKey(bundleID: model.snapshot.bundleID, pid: model.snapshot.pid)
            buckets[key, default: []].append(model)
        }
        return buckets
            .map { ProcessGroupViewModel(key: $0.key, members: $0.value) }
            .sorted(by: Self.displayOrder)
    }

    /// Score-sorted, but large / foreground / already-handled apps are never dropped.
    /// Otherwise a busy Chrome family (score 0 while in use) falls out of the top 80.
    public static func listed(_ groups: [ProcessGroupViewModel], limit: Int = 80) -> [ProcessGroupViewModel] {
        if groups.count <= limit { return groups }
        var keys = Set<String>()
        var picked: [ProcessGroupViewModel] = []
        func take(_ group: ProcessGroupViewModel) {
            guard picked.count < limit, keys.insert(group.key).inserted else { return }
            picked.append(group)
        }
        for group in groups where group.appliedAction != nil { take(group) }
        for group in groups where group.isForeground { take(group) }
        let byMemory = groups.sorted { $0.totalMemoryMB > $1.totalMemoryMB }
        for group in byMemory.prefix(20) { take(group) }
        for group in groups { take(group) }
        return picked.sorted(by: Self.displayOrder)
    }

    public static func displayOrder(_ lhs: ProcessGroupViewModel, _ rhs: ProcessGroupViewModel) -> Bool {
        if lhs.score.score != rhs.score.score {
            return lhs.score.score > rhs.score.score
        }
        return lhs.totalMemoryMB > rhs.totalMemoryMB
    }

    public func resetWeights() {
        settings.weights = .default
        persistSettings()
        refresh()
    }

    /// Crash / force-quit cannot SIGCONT. Resume anything still listed from last session.
    private func thawLeftoverFreezes() {
        let leftover = store.loadFrozen()
        guard !leftover.isEmpty else { return }
        var resumed = 0
        for item in leftover {
            if executor.thaw(pid: item.pid).ok {
                resumed += 1
            }
        }
        try? store.replaceFrozen([])
        frozen = []
        if resumed > 0 {
            lastMessage = "上次未正常退出，已自动恢复 \(resumed) 个冻结进程。"
            lastMessageIsError = false
        }
    }

    private func persistFrozen() {
        try? store.replaceFrozen(executor.frozenProcesses)
    }

    private func handleActivation(_ activation: AppActivation) {
        try? store.insertActivation(activation)
        if let index = workspaces.firstIndex(where: { $0.coreAppBundleIDs.contains(activation.bundleID) }) {
            workspaces[index].lastActiveAt = activation.timestamp
            try? store.saveWorkspace(workspaces[index])
        }
    }

    private func cpuPercent(pid: Int32, cpuTimeNs: UInt64, now: Date) -> Double {
        guard let previous = previousCPU[pid] else { return 0 }
        let dt = now.timeIntervalSince(previous.sampledAt)
        guard dt > 0.2, cpuTimeNs >= previous.timeNs else { return 0 }
        let dCPU = Double(cpuTimeNs - previous.timeNs) / 1_000_000_000.0
        return max(0, (dCPU / dt) * 100)
    }

    private func persistIfNeeded(snapshots: [ProcessSnapshot], now: Date) {
        if now.timeIntervalSince(lastPersistAt) >= 15 {
            let notable = snapshots.filter { $0.memoryFootprintMB >= 20 || $0.isForeground || $0.cpuPercent >= 15 }
            try? store.insertSnapshots(notable)
            lastPersistAt = now
        }
        if now.timeIntervalSince(lastPruneAt) >= 3600 {
            try? store.pruneOlderThan(days: 14)
            lastPruneAt = now
        }
    }

    private func updateObservedFrequency(workspace: Workspace, active: Set<String>) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        var freq = workspaces[index].observedAppFrequency
        for bundleID in active {
            freq[bundleID, default: 0] += 1
        }
        workspaces[index].observedAppFrequency = freq
        workspaces[index].lastActiveAt = Date()
        try? store.saveWorkspace(workspaces[index])
    }

    private func handleSceneSwitch(match: WorkspaceMatch, groups: [ProcessGroupViewModel], now: Date) {
        let targets = groups.map(SceneSwitchTarget.init(group:))
        let (newState, plan) = SceneSwitchPolicy.evaluate(
            state: sceneState,
            authorization: settings.authorizationLevel,
            current: match,
            targets: targets,
            frozen: executor.frozenProcesses,
            now: now
        )
        sceneState = newState

        if plan.shouldRecordTransition {
            try? store.insertWorkspaceTransition(
                from: plan.fromWorkspaceID,
                to: plan.toWorkspaceID,
                at: now
            )
            transitionCache = store.loadWorkspaceTransitions()
        }

        guard plan.didAutoProcess else { return }

        var freezeCount = 0
        var throttleCount = 0
        var thawCount = 0
        for item in plan.thaw {
            if executor.thaw(pid: item.pid).ok {
                thawCount += 1
            }
        }
        let groupByKey = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0) })
        for planned in plan.actions {
            guard let group = groupByKey[planned.groupKey] else { continue }
            let result = executor.execute(
                action: planned.action,
                snapshots: group.members.map(\.snapshot),
                groupBundleID: group.key.hasPrefix("pid:") ? group.primary.snapshot.bundleID : group.key
            )
            if result.ok {
                switch planned.action {
                case .freeze: freezeCount += 1
                case .throttle: throttleCount += 1
                default: break
                }
                try? store.insertFeedback(
                    UserFeedback(
                        bundleID: planned.bundleID,
                        scoreAtDecisionTime: group.score.score,
                        userAction: UserFeedbackAction.autoSceneSwitch.rawValue
                    )
                )
            }
        }
        let text = SceneSwitchPolicy.summary(
            workspaceName: match.displayName,
            freezeCount: freezeCount,
            throttleCount: throttleCount,
            thawCount: thawCount
        )
        if !text.isEmpty {
            lastMessage = text
            lastMessageIsError = false
        }
    }

    private func updateForecasts(from match: WorkspaceMatch, now: Date) {
        let forecast = WorkspaceMarkov.forecast(
            from: match.workspaceID,
            at: now,
            transitions: transitionCache,
            workspaceIDs: workspaces.map(\.id)
        )
        forecastSampleCount = forecast.sampleCount
        forecastScope = forecast.scope
        forecasts = forecast.predictions.map { prediction in
            WorkspaceForecast(
                workspaceID: prediction.workspaceID,
                name: prediction.workspaceID.flatMap { id in
                    workspaces.first(where: { $0.id == id })?.name
                } ?? "未分类",
                probability: prediction.probability,
                sampleCount: prediction.count,
                scope: forecast.scope
            )
        }
    }
}

public enum PanelTab: String, CaseIterable, Identifiable, Sendable {
    case processes
    case workspaces
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .processes: return "进程"
        case .workspaces: return "场景"
        case .settings: return "设置"
        }
    }
}

public struct PendingAction: Identifiable, Equatable {
    public var id: String { group.id + "-" + action.rawValue }
    public let group: ProcessGroupViewModel
    public let action: SuggestedAction
}
