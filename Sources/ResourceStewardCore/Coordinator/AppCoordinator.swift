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
    @Published public var settings: AppSettings = .default
    @Published public private(set) var frozen: [FrozenProcess] = []
    @Published public private(set) var lastMessage: String?
    @Published public private(set) var lastMessageIsError = false
    @Published public private(set) var runningApps: [RunningAppInfo] = []
    @Published public private(set) var estimatedReleaseMB: Double = 0
    @Published public private(set) var isRunning = false
    @Published public var pendingAction: PendingAction?
    @Published public var pendingBatch: PendingDecisionBatch?
    @Published public private(set) var lastAutoNotice: AutoReclaimNotice?
    @Published public private(set) var autoStatusText: String = ""

    public let store: LocalStore
    public let executor = ActionExecutor()
    public let jevAdvisor = JevReclaimAdvisor()

    private let monitor = SystemMonitor()
    private let pressureMonitor = MemoryPressureMonitor()
    private var collector: ContextCollector!
    private var timer: Timer?
    private var blacklist: Set<String> = []
    private var refreshInFlight = false
    private var refreshQueued = false
    private var lastPersistAt = Date.distantPast
    private var lastPruneAt = Date.distantPast
    private var actionCooldown = ActionAttemptCooldown()
    private var lastPersistedFrozenSignature: Set<String> = []
    private var dismissedBatchSignature = ""

    public init(store: LocalStore) {
        self.store = store
        self.settings = store.loadSettings()
        self.blacklist = store.loadBlacklist()
        self.jevAdvisor.updateEnabled(self.settings.jevReclaimEnabled)
        self.jevAdvisor.updateBaseURL(self.settings.jevBaseURL)
        self.jevAdvisor.updateModel(self.settings.jevModel)
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
        persistSettings()
        jevAdvisor.setOnBatchResolved { [weak self] in
            Task { @MainActor in
                self?.applyResolvedBatch()
            }
        }
        refresh()
        let interval = max(2, settings.sampleIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    public func stop() {
        jevAdvisor.invalidateBatch()
        let failures = executor.thawAll()
        if !failures.isEmpty {
            lastMessage = failures.map(\.message).joined(separator: "；")
            lastMessageIsError = true
            JevLog.error("shutdown_restore_failed count=\(failures.count)")
        }
        pendingBatch = nil
        pendingAction = nil
        frozen = []
        lastPersistedFrozenSignature = []
        try? store.replaceFrozen([])
        timer?.invalidate()
        timer = nil
        jevAdvisor.setOnBatchResolved(nil)
        collector.stop()
        pressureMonitor.stop()
        isRunning = false
    }

    public func refresh() {
        thawFrontmostIfFrozen()
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        let hints = RunningAppCatalog.processHints()
        let listedApps = RunningAppCatalog.collect(currentUID: getuid())
        let uid = getuid()
        let favorites = settings.favoriteBundleIDs
        let blacklist = blacklist
        let weights = settings.weights
        let pressureLevel = pressureMonitor.level
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostPID = frontmost?.processIdentifier
        let frontmostIsRegular = frontmost?.activationPolicy == .regular
        let monitor = monitor
        guard let collector else {
            refreshInFlight = false
            return
        }
        let executor = executor

        Task.detached(priority: .userInitiated) { [weak self] in
            let tick = Self.buildTick(
                monitor: monitor,
                collector: collector,
                executor: executor,
                hints: hints,
                listedApps: listedApps,
                uid: uid,
                favorites: favorites,
                blacklist: blacklist,
                weights: weights,
                pressureLevel: pressureLevel,
                frontmostPID: frontmostPID,
                frontmostIsRegular: frontmostIsRegular
            )
            await self?.applyTick(tick)
        }
    }

    private struct SampledTick: Sendable {
        var host: HostMemory
        var cpu: HostCPU
        var gpu: HostGPU
        var pressure: MemoryPressureLevel
        var snapshots: [ProcessSnapshot]
        var windowOwnerPIDs: Set<Int32>?
        var groups: [ProcessGroupViewModel]
        var runningApps: [RunningAppInfo]
        var now: Date
    }

    nonisolated private static func buildTick(
        monitor: SystemMonitor,
        collector: ContextCollector,
        executor: ActionExecutor,
        hints: [AppProcessHint],
        listedApps: [RunningAppInfo],
        uid: uid_t,
        favorites: Set<String>,
        blacklist: Set<String>,
        weights: ScoreWeights,
        pressureLevel: MemoryPressureLevel,
        frontmostPID: Int32?,
        frontmostIsRegular: Bool
    ) -> SampledTick {
        let host = monitor.sampleHost()
        let cpu = monitor.sampleCPU()
        let gpu = monitor.sampleGPU()
        let raw = monitor.sampleProcesses()
        let now = Date()
        let windowOwnerPIDs = WindowedProcessPolicy.currentOwnerPIDs(
            frontmostPID: frontmostPID,
            frontmostIsRegular: frontmostIsRegular
        )
        let hintByPID = Dictionary(uniqueKeysWithValues: hints.map { ($0.pid, $0) })

        var snapshots: [ProcessSnapshot] = []
        snapshots.reserveCapacity(raw.count)
        var livePIDs = Set<Int32>()
        livePIDs.reserveCapacity(raw.count)

        for sample in raw {
            livePIDs.insert(sample.pid)
            let hint = hintByPID[sample.pid]
            let bundleID = hint?.bundleID ?? BundleIdentity.bundleID(fromPath: sample.path)
            let name = (hint?.name.isEmpty == false ? hint?.name : nil) ?? sample.name
            let path = (hint?.bundlePath.isEmpty == false ? hint?.bundlePath : nil)
                ?? BundleIdentity.appPath(fromExecutable: sample.path)
                ?? sample.path
            let isRegularApp = hint?.isRegularApp ?? path.lowercased().contains(".app")
            let isAccessory = hint?.isAccessory ?? false
            snapshots.append(
                ProcessSnapshot(
                    timestamp: now,
                    pid: sample.pid,
                    uid: sample.uid,
                    bundleID: bundleID,
                    processName: name,
                    path: path,
                    memoryFootprintMB: sample.memoryFootprintMB,
                    cpuPercent: monitor.cpuPercent(pid: sample.pid, cpuTimeNs: sample.cpuTimeNs, now: now),
                    isForeground: collector.isForeground(bundleID: bundleID, processName: name),
                    isAccessory: isAccessory,
                    isRegularApp: isRegularApp,
                    ownsWindows: WindowedProcessPolicy.snapshotOwnsWindows(
                        pid: sample.pid,
                        isRegularApp: isRegularApp,
                        ownerPIDs: windowOwnerPIDs
                    ),
                    idleSeconds: collector.idleSeconds(
                        for: bundleID,
                        processName: name,
                        startUnix: sample.startTimeInterval,
                        now: now
                    ),
                    startUnix: sample.startTimeInterval,
                    parentPID: sample.parentPID
                )
            )
        }
        monitor.pruneProcessCPU(livePIDs: livePIDs)

        let records = ReclaimScorer.scoreAll(
            snapshots: snapshots,
            workspace: nil,
            weights: weights,
            blacklist: blacklist,
            favorites: favorites
        )
        let recordByPid = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
        let models: [ProcessViewModel] = snapshots.compactMap { snapshot in
            guard let record = recordByPid[snapshot.pid] else { return nil }
            return ProcessViewModel(
                snapshot: snapshot,
                score: record.with(suggestedAction: .none),
                appPath: snapshot.path,
                appliedAction: executor.appliedAction(pid: snapshot.pid)
            )
        }
        let grouped = listed(
            grouped(models, hints: hints).filter { group in
                if group.isForeground { return true }
                return group.members.contains {
                    $0.snapshot.memoryFootprintMB >= 8 || $0.score.score >= 20 || $0.snapshot.isForeground
                }
            }
        )
        return SampledTick(
            host: host,
            cpu: cpu,
            gpu: gpu,
            pressure: host.inferredPressure(sourceLevel: pressureLevel),
            snapshots: snapshots,
            windowOwnerPIDs: windowOwnerPIDs,
            groups: grouped,
            runningApps: RunningAppCatalog.mergingProcessSnapshots(
                existing: listedApps,
                snapshots: snapshots,
                currentUID: uid
            ),
            now: now
        )
    }

    private func applyTick(_ tick: SampledTick) {
        guard isRunning else { refreshInFlight = false; return }
        executor.windowOwnerPIDs = tick.windowOwnerPIDs
        executor.reuseWindowOwnerPIDs = true
        defer { executor.reuseWindowOwnerPIDs = false }
        executor.extraKeepAliveBundleIDs = settings.favoriteBundleIDs
        executor.prune(snapshots: tick.snapshots)
        thawKeepAliveIfFrozen()
        thawWindowedIfFrozen(ownerPIDs: tick.windowOwnerPIDs)

        let load = JevLoadState(
            memory_pressure: tick.pressure.rawValue,
            cpu_percent: tick.cpu.usagePercent,
            memory_used_ratio: tick.host.physicalBytes == 0
                ? 0
                : Double(tick.host.usedBytes) / Double(tick.host.physicalBytes),
            swap_used_mb: Double(tick.host.swapUsedBytes) / 1_048_576,
            foreground_bundle_id: collector.lastForegroundBundleID ?? "",
            foreground_name: collector.lastForegroundName ?? ""
        )
        let grayApps = JevGrayZone.apps(
            groups: tick.groups,
            favorites: settings.favoriteBundleIDs,
            windowOwnerPIDs: tick.windowOwnerPIDs
        )
        let batch = jevAdvisor.syncBatch(load: load, apps: grayApps)
        var grouped = overlayBatchActions(groups: tick.groups, actions: batch.actions)

        hostMemory = tick.host
        hostCPU = tick.cpu
        hostGPU = tick.gpu
        pressure = tick.pressure
        runningApps = tick.runningApps
        applyBatchDecisions(groups: grouped, batch: batch, now: tick.now)
        grouped = grouped.map { group in
            ProcessGroupViewModel(
                key: group.key,
                members: group.members.map { model in
                    ProcessViewModel(
                        snapshot: model.snapshot,
                        score: model.score,
                        appPath: model.appPath,
                        appliedAction: executor.appliedAction(pid: model.snapshot.pid)
                    )
                }
            )
        }
        grouped = Self.listed(grouped)
        if processGroups != grouped {
            processGroups = grouped
            processes = grouped.flatMap(\.members)
        }
        frozen = executor.frozenProcesses
        persistFrozen()
        let release = grouped
            .filter { $0.effectiveSuggestion == .quit }
            .reduce(0) { $0 + $1.totalMemoryMB }
        if abs(estimatedReleaseMB - release) > 0.5 {
            estimatedReleaseMB = release
        }
        autoStatusText = batchStatusText(batch: batch)
        persistIfNeeded(snapshots: tick.snapshots, now: tick.now)

        refreshInFlight = false
        if refreshQueued {
            refreshQueued = false
            refresh()
        }
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
        jevAdvisor.updateEnabled(settings.jevReclaimEnabled)
        jevAdvisor.updateBaseURL(settings.jevBaseURL)
        jevAdvisor.updateModel(settings.jevModel)
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

    public func request(_ action: SuggestedAction, for group: ProcessGroupViewModel) {
        pendingAction = PendingAction(group: group, action: action)
    }

    public func confirmPending() {
        guard let pending = pendingAction else { return }
        pendingAction = nil
        executor.extraKeepAliveBundleIDs = settings.favoriteBundleIDs
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

    public func confirmPendingBatch() {
        guard let batch = pendingBatch else { return }
        pendingBatch = nil
        guard jevAdvisor.isActive else { return }
        let live = jevAdvisor.latestBatch()
        let current = actionableItems(from: processGroups, actions: live.actions)
        let approved = Set(batch.items.map(decisionIdentity))
        var okCount = 0
        executor.extraKeepAliveBundleIDs = settings.favoriteBundleIDs
        for item in current where approved.contains(decisionIdentity(item)) {
            let result = executor.execute(
                action: item.action,
                snapshots: item.group.members.map(\.snapshot),
                groupBundleID: item.group.key.hasPrefix("pid:") ? item.group.primary.snapshot.bundleID : item.group.key
            )
            actionCooldown.record(item.group.key, at: Date())
            if result.ok {
                okCount += 1
                try? store.insertFeedback(
                    UserFeedback(
                        bundleID: item.group.score.bundleID,
                        scoreAtDecisionTime: item.group.score.score,
                        userAction: UserFeedbackAction.accepted.rawValue
                    )
                )
            }
        }
        lastMessage = okCount > 0 ? "已按建议处理 \(okCount) 个应用。" : "没有成功执行的建议。"
        lastMessageIsError = okCount == 0
        frozen = executor.frozenProcesses
        persistFrozen()
        refresh()
    }

    public func cancelPendingBatch() {
        if let batch = pendingBatch {
            dismissedBatchSignature = batch.id
        }
        pendingBatch = nil
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

    public func isFavorite(_ group: ProcessGroupViewModel) -> Bool {
        KeepAlivePolicy.isUserListed(bundleID: group.primary.snapshot.bundleID, extras: settings.favoriteBundleIDs)
            || KeepAlivePolicy.isUserListed(bundleID: group.key, extras: settings.favoriteBundleIDs)
    }

    public func isFavorite(bundleID: String) -> Bool {
        KeepAlivePolicy.isUserListed(bundleID: bundleID, extras: settings.favoriteBundleIDs)
    }

    public func toggleFavorite(_ group: ProcessGroupViewModel) {
        let bundleID = ProcessFamily.rootBundleID(from: group.primary.snapshot.bundleID)
            ?? group.primary.snapshot.bundleID
            ?? group.key
        guard !bundleID.isEmpty, !bundleID.hasPrefix("pid:") else { return }
        if isFavorite(bundleID: bundleID) {
            removeFavorite(bundleID: bundleID)
        } else {
            addFavorite(bundleID: bundleID, name: group.displayName, path: group.appPath ?? "")
        }
    }

    public func addFavorite(bundleID: String, name: String, path: String) {
        let root = ProcessFamily.rootBundleID(from: bundleID) ?? bundleID
        guard !root.isEmpty, !root.hasPrefix("pid:") else { return }
        if KeepAlivePolicy.isKeepAlive(bundleID: root, processName: name, path: path) {
            return
        }
        if settings.favoriteApps.contains(where: { $0.bundleID == root }) { return }
        let display = runningApps.first(where: { $0.bundleID == root })?.name ?? name
        let resolvedPath = runningApps.first(where: { $0.bundleID == root })?.path ?? path
        settings.favoriteApps.append(FavoriteApp(bundleID: root, name: display, path: resolvedPath))
        persistSettings()
        thawFavoriteIfFrozen(bundleID: root)
        refresh()
    }

    public func removeFavorite(bundleID: String) {
        let root = ProcessFamily.rootBundleID(from: bundleID) ?? bundleID
        settings.favoriteApps.removeAll { $0.bundleID == root || $0.bundleID == bundleID }
        persistSettings()
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

    nonisolated public static func grouped(
        _ models: [ProcessViewModel],
        hints: [AppProcessHint] = []
    ) -> [ProcessGroupViewModel] {
        let keys = ProcessGrouper.keys(snapshots: models.map(\.snapshot), hints: hints)
        var buckets: [String: [ProcessViewModel]] = [:]
        for model in models {
            let key = keys[model.snapshot.pid]
                ?? ProcessFamily.familyKey(bundleID: model.snapshot.bundleID, pid: model.snapshot.pid)
            buckets[key, default: []].append(model)
        }
        return buckets
            .map { ProcessGroupViewModel(key: $0.key, members: $0.value) }
            .sorted(by: Self.displayOrder)
    }

    /// Score-sorted, but large / foreground / already-handled apps are never dropped.
    /// Otherwise a busy Chrome family (score 0 while in use) falls out of the top 80.
    nonisolated public static func listed(_ groups: [ProcessGroupViewModel], limit: Int = 80) -> [ProcessGroupViewModel] {
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

    nonisolated public static func displayOrder(_ lhs: ProcessGroupViewModel, _ rhs: ProcessGroupViewModel) -> Bool {
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
        lastPersistedFrozenSignature = []
        frozen = []
        if resumed > 0 {
            lastMessage = "上次未正常退出，已自动恢复 \(resumed) 个冻结进程。"
            lastMessageIsError = false
        }
    }

    private func persistFrozen() {
        let items = executor.frozenProcesses
        let signature = FrozenPersistPolicy.signature(items)
        guard FrozenPersistPolicy.shouldReplace(
            previous: lastPersistedFrozenSignature,
            current: items
        ) else { return }
        lastPersistedFrozenSignature = signature
        try? store.replaceFrozen(items)
    }

    /// SIGSTOP of an AppKit app with windows can hang WindowServer. Resume any that
    /// an older build froze, and drop them from the freeze list.
    private func thawWindowedIfFrozen(ownerPIDs: Set<Int32>? = nil) {
        let stuck = executor.frozenProcesses.filter { item in
            let bundleID = item.bundleID.isEmpty ? nil : item.bundleID
            if executor.reuseWindowOwnerPIDs || ownerPIDs != nil {
                // Use the tick's owner set — never re-fetch CGWindowList per frozen pid.
                return WindowedProcessPolicy.isUnsafeToFreeze(
                    pid: item.pid,
                    bundleID: bundleID,
                    ownerPIDs: ownerPIDs ?? executor.windowOwnerPIDs
                )
            }
            return executor.isUnsafeToFreeze(item.pid, bundleID)
        }
        for item in stuck {
            _ = executor.thaw(pid: item.pid)
        }
        if !stuck.isEmpty {
            lastMessage = "已恢复 \(stuck.count) 个带窗口的应用，避免卡住屏幕。"
            lastMessageIsError = false
        }
    }

    /// Container / VPN keep-alive processes must never stay SIGSTOP'd, even if an older
    /// build froze them. Resume and drop them from the freeze list on every sample.
    private func thawKeepAliveIfFrozen() {
        let extras = settings.favoriteBundleIDs
        let stuck = executor.frozenProcesses.filter {
            KeepAlivePolicy.shouldStayAlive(
                bundleID: $0.bundleID,
                processName: $0.processName,
                extras: extras
            )
        }
        for item in stuck {
            _ = executor.thaw(pid: item.pid)
        }
    }

    private func thawFavoriteIfFrozen(bundleID: String) {
        for item in executor.frozenProcesses where KeepAlivePolicy.isUserListed(bundleID: item.bundleID, extras: [bundleID]) {
            _ = executor.thaw(pid: item.pid)
        }
    }

    private func handleActivation(_ activation: AppActivation) {
        try? store.insertActivation(activation)
        jevAdvisor.invalidateBatch()
        pendingBatch = nil
        _ = thawOnUserOpen(bundleID: activation.bundleID, processName: activation.processName)
        refresh()
    }

    /// Dock, Spotlight, or Cmd-Tab of a frozen app is an explicit "I need this now".
    @discardableResult
    private func thawOnUserOpen(bundleID: String, processName: String) -> Int {
        let count = executor.thawMatchingActivation(bundleID: bundleID, processName: processName)
        if count > 0 {
            frozen = executor.frozenProcesses
            persistFrozen()
            lastMessage = "你打开了「\(processName.isEmpty ? bundleID : processName)」，已自动恢复 \(count) 个冻结进程。"
            lastMessageIsError = false
        }
        return count
    }

    private func thawFrontmostIfFrozen() {
        guard !executor.frozenProcesses.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier ?? ""
        let name = front?.localizedName ?? front?.executableURL?.lastPathComponent ?? ""
        guard !bundleID.isEmpty || !name.isEmpty else { return }
        _ = thawOnUserOpen(bundleID: bundleID, processName: name)
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

    private func overlayBatchActions(
        groups: [ProcessGroupViewModel],
        actions: [String: SuggestedAction]
    ) -> [ProcessGroupViewModel] {
        guard !actions.isEmpty else { return groups }
        return groups.map { group in
            ProcessGroupViewModel(
                key: group.key,
                members: overlayBatchActions(models: group.members, actions: actions)
            )
        }
    }

    private func overlayBatchActions(
        models: [ProcessViewModel],
        actions: [String: SuggestedAction]
    ) -> [ProcessViewModel] {
        guard !actions.isEmpty else { return models }
        return models.map { model in
            let bundle = model.snapshot.bundleID ?? model.score.bundleID
            let root = ProcessFamily.rootBundleID(from: bundle) ?? bundle
            guard let action = (actions[bundle] ?? actions[root])?.withoutFreeze() else { return model }
            return ProcessViewModel(
                snapshot: model.snapshot,
                score: model.score.with(suggestedAction: action),
                appPath: model.appPath,
                appliedAction: model.appliedAction
            )
        }
    }

    private func applyResolvedBatch() {
        guard isRunning else { return }
        // Resample load, foreground and generations before consuming a response.
        refresh()
    }

    private func decisionIdentity(_ item: PendingDecisionItem) -> String {
        let generations = item.group.members.map { "\($0.snapshot.pid):\($0.snapshot.startUnix)" }.sorted().joined(separator: ",")
        return "\(item.group.key):\(item.action.rawValue):\(generations)"
    }

    private func applyBatchDecisions(
        groups: [ProcessGroupViewModel],
        batch: JevBatchSnapshot,
        now: Date
    ) {
        guard jevAdvisor.isActive, !batch.pending else {
            pendingBatch = nil
            return
        }
        let items = actionableItems(from: groups, actions: batch.actions)
        guard !items.isEmpty else { pendingBatch = nil; return }
        let signature = items.map(decisionIdentity).sorted().joined(separator: "|")
        if settings.authorizationLevel == .sceneSwitch {
            if pendingBatch != nil {
                pendingBatch = nil
            }
            if pendingAction == nil {
                executeAutoItems(items, now: now)
            }
        } else if pendingAction == nil, signature != dismissedBatchSignature, pendingBatch?.id != signature {
            pendingBatch = PendingDecisionBatch(id: signature, items: items)
            JevLog.info(
                "confirm_pending_set items=\(items.map { "\($0.group.key)=\($0.action.rawValue)" }.joined(separator: ","))"
            )
        }
    }

    private func actionableItems(
        from groups: [ProcessGroupViewModel],
        actions: [String: SuggestedAction]
    ) -> [PendingDecisionItem] {
        var items: [PendingDecisionItem] = []
        for group in groups {
            let bundle = group.primary.snapshot.bundleID ?? group.score.bundleID
            let root = ProcessFamily.rootBundleID(from: bundle) ?? bundle
            let action = (actions[bundle] ?? actions[root] ?? .none).withoutFreeze()
            guard action.isActable else { continue }
            let candidate = JevHardGate.Candidate(group: group, favorites: settings.favoriteBundleIDs)
            guard JevHardGate.isGrayZone(candidate) else { continue }
            if action == .throttle, group.members.allSatisfy({ $0.appliedAction == .throttle }) { continue }
            if settings.authorizationLevel == .sceneSwitch, action == .quit, group.idleSeconds < 30 {
                continue
            }
            guard actionCooldown.allows(group.key, at: Date()) else { continue }
            items.append(PendingDecisionItem(group: group, action: action))
            if items.count >= 6 { break }
        }
        return items
    }

    private func executeAutoItems(
        _ items: [PendingDecisionItem],
        now: Date
    ) {
        var throttleCount = 0
        var quitCount = 0
        var names: [String] = []
        for item in items {
            let result = executor.execute(
                action: item.action,
                snapshots: item.group.members.map(\.snapshot),
                groupBundleID: item.group.key.hasPrefix("pid:") ? item.group.primary.snapshot.bundleID : item.group.key
            )
            actionCooldown.record(item.group.key, at: now)
            if result.ok {
                names.append(item.group.displayName)
                switch item.action {
                case .throttle: throttleCount += 1
                case .quit: quitCount += 1
                default: break
                }
                try? store.insertFeedback(
                    UserFeedback(
                        bundleID: item.group.score.bundleID,
                        scoreAtDecisionTime: item.group.score.score,
                        userAction: UserFeedbackAction.autoIdleReclaim.rawValue
                    )
                )
            }
        }
        var parts: [String] = []
        if throttleCount > 0 { parts.append("降低 \(throttleCount) 个优先级") }
        if quitCount > 0 { parts.append("请求退出 \(quitCount) 个应用") }
        if !parts.isEmpty {
            let notice = AutoReclaimNotice(throttleCount: throttleCount, quitCount: quitCount, names: names)
            lastAutoNotice = notice
            lastMessage = notice.body
            lastMessageIsError = false
        }
    }

    private func batchStatusText(batch: JevBatchSnapshot) -> String {
        if !jevAdvisor.isActive {
            return "配置 Jev API Key 并启用后，才会按负载给出建议"
        }
        if batch.pending {
            return "正在根据当前负载询问 Jev…"
        }
        let actable = processGroups.filter { $0.effectiveSuggestion.isActable }.count
        if settings.authorizationLevel == .sceneSwitch {
            if actable > 0 {
                return "半自动 · \(actable) 个灰区应用待处理"
            }
            return "半自动 · 按负载保留当前灰区应用"
        }
        if pendingBatch != nil {
            return "仅建议 · 请在确认窗口中决定是否执行"
        }
        if actable > 0 {
            return "仅建议 · \(actable) 个灰区应用可处理"
        }
        return "仅建议 · 暂无需要处理的灰区应用"
    }

}

public enum PanelTab: String, CaseIterable, Identifiable, Sendable {
    case processes
    case favorites
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .processes: return "进程"
        case .favorites: return "常用"
        case .settings: return "设置"
        }
    }
}

public struct PendingAction: Identifiable, Equatable {
    public var id: String { group.id + "-" + action.rawValue }
    public let group: ProcessGroupViewModel
    public let action: SuggestedAction
}

public struct PendingDecisionItem: Identifiable, Equatable {
    public var id: String { group.id + "-" + action.rawValue }
    public let group: ProcessGroupViewModel
    public let action: SuggestedAction
}

public struct PendingDecisionBatch: Identifiable, Equatable {
    public let id: String
    public let items: [PendingDecisionItem]
}
