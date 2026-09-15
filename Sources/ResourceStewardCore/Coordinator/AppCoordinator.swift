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
        restorePersistedFreezes()
        refresh()
        let interval = max(2, settings.sampleIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    public func stop() {
        persistFrozen()
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
            if snapshot.memoryFootprintMB < 8 && record.score < 20 && !snapshot.isForeground {
                return nil
            }
            return ProcessViewModel(
                snapshot: snapshot,
                score: record,
                appPath: snapshot.path,
                appliedAction: executor.appliedAction(pid: snapshot.pid)
            )
        }
        .sorted {
            if $0.score.score != $1.score.score {
                return $0.score.score > $1.score.score
            }
            return $0.snapshot.memoryFootprintMB > $1.snapshot.memoryFootprintMB
        }

        hostMemory = host
        hostCPU = cpu
        hostGPU = gpu
        pressure = host.inferredPressure(sourceLevel: pressureMonitor.level)
        processes = Array(models.prefix(80))
        processGroups = Self.grouped(processes)
        self.match = match
        runningApps = RunningAppCatalog.mergingProcessSnapshots(
            existing: RunningAppCatalog.collect(currentUID: uid),
            snapshots: snapshots,
            currentUID: uid
        )
        frozen = executor.frozenProcesses
        estimatedReleaseMB = processGroups
            .filter { $0.effectiveSuggestion != .none }
            .reduce(0) { $0 + ($1.members.map(\.snapshot.memoryFootprintMB).max() ?? 0) }

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

    public func ignoreAndBlacklist(_ group: ProcessGroupViewModel) {
        try? store.addToBlacklist(bundleID: group.score.bundleID, reason: "user")
        blacklist = store.loadBlacklist()
        try? store.insertFeedback(
            UserFeedback(
                bundleID: group.score.bundleID,
                scoreAtDecisionTime: group.score.score,
                userAction: UserFeedbackAction.manualOverride.rawValue
            )
        )
        refresh()
    }

    static func grouped(_ models: [ProcessViewModel]) -> [ProcessGroupViewModel] {
        var buckets: [String: [ProcessViewModel]] = [:]
        for model in models {
            let key = model.snapshot.bundleID ?? "pid:\(model.snapshot.pid)"
            buckets[key, default: []].append(model)
        }
        return buckets
            .map { ProcessGroupViewModel(key: $0.key, members: $0.value) }
            .sorted {
                if $0.score.score != $1.score.score {
                    return $0.score.score > $1.score.score
                }
                return $0.totalMemoryMB > $1.totalMemoryMB
            }
    }

    public func resetWeights() {
        settings.weights = .default
        persistSettings()
        refresh()
    }

    private func restorePersistedFreezes() {
        let restored = executor.restorePersisted(store.loadFrozen())
        try? store.replaceFrozen(restored)
        frozen = restored
        if !restored.isEmpty {
            lastMessage = "已恢复 \(restored.count) 个上次冻结的进程（退出管家不会自动解冻）。"
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
