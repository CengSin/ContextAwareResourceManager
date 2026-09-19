import AppKit
import Darwin
import Foundation
import ProcBridge

public struct ActionResult: Sendable, Equatable {
    public let ok: Bool
    public let message: String
    public let action: SuggestedAction
    public let pid: Int32

    public init(ok: Bool, message: String, action: SuggestedAction, pid: Int32) {
        self.ok = ok
        self.message = message
        self.action = action
        self.pid = pid
    }
}

public final class ActionExecutor: @unchecked Sendable {
    private struct ThrottleRecord: Sendable {
        var pid: Int32
        var startUnix: TimeInterval
        var originalNice: Int32
        var bundleID: String
        var processName: String

        var generation: ProcessGeneration {
            ProcessGeneration(pid: pid, startUnix: startUnix)
        }
    }

    private let lock = NSLock()
    private var frozen: [Int32: FrozenProcess] = [:]
    private var throttled: [Int32: ThrottleRecord] = [:]
    private let currentUID = getuid()
    /// Test seam. `nil` means ask the kernel.
    public var lookupGeneration: ((Int32) -> ProcessGeneration?)?
    public var extraKeepAliveBundleIDs: Set<String> = []
    /// Tick-scoped window-owner PID set from `AppCoordinator.refresh`.
    /// When `reuseWindowOwnerPIDs` is true, freeze-safety uses this value as-is
    /// (`nil` still means fail-closed) and does not call `CGWindowListCopyWindowInfo` again.
    public var windowOwnerPIDs: Set<Int32>?
    public var reuseWindowOwnerPIDs = false
    private var isUnsafeToFreezeOverride: ((Int32, String?) -> Bool)?

    public var isUnsafeToFreeze: (Int32, String?) -> Bool {
        get {
            if let isUnsafeToFreezeOverride {
                return isUnsafeToFreezeOverride
            }
            return { [weak self] pid, bundleID in
                guard let self else {
                    return WindowedProcessPolicy.isUnsafeToFreeze(pid: pid, bundleID: bundleID)
                }
                let owners: Set<Int32>?
                if self.reuseWindowOwnerPIDs {
                    owners = self.windowOwnerPIDs
                } else {
                    owners = WindowedProcessPolicy.currentOwnerPIDs()
                }
                return WindowedProcessPolicy.isUnsafeToFreeze(
                    pid: pid,
                    bundleID: bundleID,
                    ownerPIDs: owners
                )
            }
        }
        set { isUnsafeToFreezeOverride = newValue }
    }

    public init() {}

    public var frozenProcesses: [FrozenProcess] {
        lock.lock()
        defer { lock.unlock() }
        return frozen.values.sorted { $0.frozenAt > $1.frozenAt }
    }

    public func isFrozen(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return frozen[pid] != nil
    }

    public func isThrottled(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return throttled[pid] != nil
    }

    public func originalNice(pid: Int32) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return throttled[pid]?.originalNice
    }

    public func appliedAction(pid: Int32) -> SuggestedAction? {
        lock.lock()
        defer { lock.unlock() }
        if frozen[pid] != nil { return .freeze }
        if throttled[pid] != nil { return .throttle }
        return nil
    }

    public func prune(livePIDs: Set<Int32>) {
        lock.lock()
        frozen = frozen.filter { livePIDs.contains($0.key) }
        throttled = throttled.filter { livePIDs.contains($0.key) }
        lock.unlock()
    }

    public func prune(snapshots: [ProcessSnapshot]) {
        let live = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0.generation) })
        lock.lock()
        frozen = frozen.filter { pid, item in
            guard let current = live[pid] else { return false }
            if !item.generation.isKnown { return true }
            return item.generation.sameGeneration(current)
        }
        throttled = throttled.filter { pid, item in
            guard let current = live[pid] else { return false }
            if !item.generation.isKnown { return true }
            return item.generation.sameGeneration(current)
        }
        lock.unlock()
    }

    public func execute(action: SuggestedAction, snapshots: [ProcessSnapshot], groupBundleID: String?) -> ActionResult {
        if action == .freeze {
            return ActionResult(
                ok: false,
                message: "已停用冻结，避免卡住屏幕。",
                action: .freeze,
                pid: snapshots.first?.pid ?? 0
            )
        }
        if action != .none, ProcessFamily.isIndependentCompanionAction(snapshots: snapshots) {
            return ActionResult(
                ok: false,
                message: "不会单独处理 Helper / Renderer。它们必须随主应用一起处理，否则开链接等功能会失效。",
                action: action,
                pid: snapshots.first?.pid ?? 0
            )
        }
        if let denied = denyIfCategoryBanned(action: action, snapshots: snapshots) {
            return denied
        }
        if action == .quit {
            return quitGroup(snapshots: snapshots, bundleID: groupBundleID)
        }
        var okCount = 0
        var last = ActionResult(ok: false, message: "没有可处理的进程", action: action, pid: snapshots.first?.pid ?? 0)
        for snapshot in snapshots {
            last = apply(action: action, snapshot: snapshot)
            if last.ok { okCount += 1 }
        }
        if okCount == 0 { return last }
        let name = snapshots.first?.processName ?? "进程"
        let message: String
        switch action {
        case .freeze:
            message = "已冻结 \(name) 的 \(okCount) 个进程。内存通常仍被占用，直到系统稍后自然回收。"
        case .throttle:
            message = "已降低 \(name) 的 \(okCount) 个进程的 CPU 优先级。"
        default:
            message = last.message
        }
        return ActionResult(ok: true, message: message, action: action, pid: last.pid)
    }

    public func execute(action: SuggestedAction, snapshot: ProcessSnapshot) -> ActionResult {
        execute(action: action, snapshots: [snapshot], groupBundleID: snapshot.bundleID)
    }

    private func apply(action: SuggestedAction, snapshot: ProcessSnapshot) -> ActionResult {
        switch action {
        case .none:
            return ActionResult(ok: true, message: "无需处理", action: action, pid: snapshot.pid)
        case .throttle:
            return throttle(snapshot)
        case .freeze:
            return freeze(snapshot)
        case .quit:
            return quit(snapshot)
        }
    }

    public func thawMatchingActivation(bundleID: String, processName: String) -> Int {
        let targets = frozenProcesses.filter {
            ProcessFamily.matchesUserOpen(
                frozenBundleID: $0.bundleID,
                frozenName: $0.processName,
                openedBundleID: bundleID,
                openedName: processName
            )
        }
        var count = 0
        for item in targets {
            if thaw(pid: item.pid).ok {
                count += 1
            }
        }
        return count
    }

    public func thaw(pid: Int32) -> ActionResult {
        lock.lock()
        let item = frozen[pid]
        lock.unlock()
        if let item, let mismatch = generationMismatch(expected: item.generation, pid: pid) {
            lock.lock()
            frozen.removeValue(forKey: pid)
            lock.unlock()
            return ActionResult(ok: false, message: mismatch, action: .freeze, pid: pid)
        }
        let result = sendSignal(pid: pid, signal: SIGCONT)
        if result.ok || isGone(result.message) {
            lock.lock()
            frozen.removeValue(forKey: pid)
            lock.unlock()
            if result.ok {
                return ActionResult(ok: true, message: "已恢复进程 \(pid)", action: .freeze, pid: pid)
            }
            return ActionResult(ok: false, message: result.message, action: .freeze, pid: pid)
        }
        return ActionResult(ok: false, message: result.message, action: .freeze, pid: pid)
    }

    public func unthrottle(pid: Int32) -> ActionResult {
        lock.lock()
        let record = throttled[pid]
        lock.unlock()
        guard let record else {
            return ActionResult(ok: false, message: "该进程不在本工具的降速账本里。", action: .throttle, pid: pid)
        }
        if let mismatch = generationMismatch(expected: record.generation, pid: pid) {
            lock.lock()
            throttled.removeValue(forKey: pid)
            lock.unlock()
            return ActionResult(ok: false, message: mismatch, action: .throttle, pid: pid)
        }
        if !setNice(pid: pid, value: record.originalNice) {
            return ActionResult(ok: false, message: "恢复优先级失败：\(posixError())", action: .throttle, pid: pid)
        }
        lock.lock()
        throttled.removeValue(forKey: pid)
        lock.unlock()
        return ActionResult(ok: true, message: "已恢复进程 \(pid) 的 CPU 优先级", action: .throttle, pid: pid)
    }

    public func thawAll() {
        let pids = frozenProcesses.map(\.pid)
        for pid in pids {
            _ = thaw(pid: pid)
        }
        lock.lock()
        let throttlePIDs = Array(throttled.keys)
        lock.unlock()
        for pid in throttlePIDs {
            _ = unthrottle(pid: pid)
        }
    }

    /// Re-adopts previously frozen PIDs after relaunch. Does not resume them.
    /// Still-running processes are SIGSTOP'd again; already-stopped ones are just tracked.
    public func restorePersisted(_ saved: [FrozenProcess]) -> [FrozenProcess] {
        var kept: [FrozenProcess] = []
        for item in saved {
            if KeepAlivePolicy.shouldStayAlive(
                bundleID: item.bundleID,
                processName: item.processName,
                extras: extraKeepAliveBundleIDs
            ) || isUnsafeToFreeze(item.pid, item.bundleID.isEmpty ? nil : item.bundleID)
                || !CategoryBanPolicy.allows(
                    .freeze,
                    bundleID: item.bundleID.isEmpty ? nil : item.bundleID,
                    processName: item.processName
                ) {
                _ = kill(item.pid, SIGCONT)
                continue
            }
            if item.generation.isKnown,
               let live = currentGeneration(pid: item.pid),
               !item.generation.sameGeneration(live) {
                continue
            }
            if !item.generation.isKnown {
                continue
            }
            let status = rs_process_status(item.pid)
            if status < 0 {
                continue
            }
            if status != 4 {
                if kill(item.pid, SIGSTOP) != 0 {
                    continue
                }
                usleep(80_000)
                if rs_process_status(item.pid) != 4 {
                    _ = kill(item.pid, SIGCONT)
                    continue
                }
            }
            lock.lock()
            frozen[item.pid] = item
            lock.unlock()
            kept.append(item)
        }
        return kept
    }

    private func throttle(_ snapshot: ProcessSnapshot) -> ActionResult {
        if let denied = denyIfUnsafe(snapshot) { return denied }
        if let mismatch = generationMismatch(expected: snapshot.generation, pid: snapshot.pid) {
            return ActionResult(ok: false, message: mismatch, action: .throttle, pid: snapshot.pid)
        }
        if isThrottled(pid: snapshot.pid) {
            return ActionResult(ok: true, message: "\(snapshot.processName) 已降低过 CPU 优先级", action: .throttle, pid: snapshot.pid)
        }
        guard let originalNice = currentNice(pid: snapshot.pid) else {
            return ActionResult(ok: false, message: "读取 \(snapshot.processName) 的优先级失败：\(posixError())", action: .throttle, pid: snapshot.pid)
        }
        if originalNice >= 15 {
            lock.lock()
            throttled[snapshot.pid] = ThrottleRecord(
                pid: snapshot.pid,
                startUnix: recordedStartUnix(snapshot),
                originalNice: originalNice,
                bundleID: snapshot.bundleID ?? "",
                processName: snapshot.processName
            )
            lock.unlock()
            return ActionResult(ok: true, message: "\(snapshot.processName) 已处于较低优先级", action: .throttle, pid: snapshot.pid)
        }
        if !setNice(pid: snapshot.pid, value: 15) {
            return ActionResult(ok: false, message: "降低优先级失败：\(posixError())", action: .throttle, pid: snapshot.pid)
        }
        lock.lock()
        throttled[snapshot.pid] = ThrottleRecord(
            pid: snapshot.pid,
            startUnix: recordedStartUnix(snapshot),
            originalNice: originalNice,
            bundleID: snapshot.bundleID ?? "",
            processName: snapshot.processName
        )
        lock.unlock()
        return ActionResult(ok: true, message: "已降低 \(snapshot.processName) 的 CPU 优先级", action: .throttle, pid: snapshot.pid)
    }

    private func freeze(_ snapshot: ProcessSnapshot) -> ActionResult {
        if isFrozen(pid: snapshot.pid) {
            return ActionResult(ok: true, message: "\(snapshot.processName) 已处于冻结状态", action: .freeze, pid: snapshot.pid)
        }
        if isUnsafeToFreeze(snapshot.pid, snapshot.bundleID) {
            return ActionResult(
                ok: false,
                message: "\(snapshot.processName) 有窗口，冻结会卡住屏幕，已拒绝。",
                action: .freeze,
                pid: snapshot.pid
            )
        }
        if let denied = denyIfUnsafe(snapshot) { return denied }
        if let mismatch = generationMismatch(expected: snapshot.generation, pid: snapshot.pid) {
            return ActionResult(ok: false, message: mismatch, action: .freeze, pid: snapshot.pid)
        }
        let signal = sendSignal(pid: snapshot.pid, signal: SIGSTOP)
        if !signal.ok {
            return ActionResult(ok: false, message: signal.message, action: .freeze, pid: snapshot.pid)
        }
        usleep(80_000)
        if rs_process_status(snapshot.pid) != 4 {
            _ = sendSignal(pid: snapshot.pid, signal: SIGCONT)
            return ActionResult(
                ok: false,
                message: "已向 \(snapshot.processName) 发送暂停信号，但进程仍在运行（该 App 可能忽略 SIGSTOP）。",
                action: .freeze,
                pid: snapshot.pid
            )
        }
        lock.lock()
        frozen[snapshot.pid] = FrozenProcess(
            pid: snapshot.pid,
            bundleID: snapshot.bundleID ?? "",
            processName: snapshot.processName,
            action: .freeze,
            startUnix: recordedStartUnix(snapshot)
        )
        lock.unlock()
        return ActionResult(ok: true, message: "已冻结 \(snapshot.processName)。内存通常仍被占用，直到系统稍后自然回收。", action: .freeze, pid: snapshot.pid)
    }

    private func quit(_ snapshot: ProcessSnapshot) -> ActionResult {
        quitGroup(snapshots: [snapshot], bundleID: snapshot.bundleID)
    }

    private func quitGroup(snapshots: [ProcessSnapshot], bundleID: String?) -> ActionResult {
        if let first = snapshots.first, let denied = denyIfUnsafe(first) { return denied }
        if let first = snapshots.first,
           let mismatch = generationMismatch(expected: first.generation, pid: first.pid) {
            return ActionResult(ok: false, message: mismatch, action: .quit, pid: first.pid)
        }
        let pid = snapshots.first?.pid ?? 0
        let name = snapshots.first?.processName ?? "应用"
        var ids: [String] = []
        if let bundleID, !bundleID.isEmpty {
            ids.append(bundleID)
            if let root = ProcessFamily.rootBundleID(from: bundleID), root != bundleID {
                ids.append(root)
            }
            if bundleID.lowercased().contains(".helper") {
                ids.append(contentsOf: helperParentIDs(bundleID))
            }
        }
        for id in ids {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            let target = apps.first(where: { $0.activationPolicy == .regular }) ?? apps.first
            if let target, target.terminate() {
                return ActionResult(ok: true, message: "已请求 \(target.localizedName ?? name) 退出。若有未保存内容，应用会自行提示。", action: .quit, pid: pid)
            }
        }
        if let app = NSRunningApplication(processIdentifier: pid), app.terminate() {
            return ActionResult(ok: true, message: "已请求 \(name) 退出。若有未保存内容，应用会自行提示。", action: .quit, pid: pid)
        }
        return ActionResult(ok: false, message: "无法通过系统接口请求退出该进程（可能不是标准 App）。未执行强制结束。", action: .quit, pid: pid)
    }

    private func helperParentIDs(_ bundleID: String) -> [String] {
        var id = bundleID
        var results: [String] = []
        while let range = id.range(of: ".helper", options: [.caseInsensitive, .backwards]) {
            id = String(id[..<range.lowerBound])
            if !id.isEmpty { results.append(id) }
        }
        return results
    }

    private func denyIfCategoryBanned(action: SuggestedAction, snapshots: [ProcessSnapshot]) -> ActionResult? {
        guard action == .throttle || action == .freeze else { return nil }
        for snapshot in snapshots {
            guard let category = CategoryBanPolicy.match(
                bundleID: snapshot.bundleID,
                processName: snapshot.processName,
                path: snapshot.path
            ) else { continue }
            if CategoryBanPolicy.allows(action, in: category) { continue }
            return ActionResult(
                ok: false,
                message: CategoryBanPolicy.refusalMessage(
                    processName: snapshot.processName,
                    category: category,
                    action: action
                ),
                action: action,
                pid: snapshot.pid
            )
        }
        return nil
    }

    private func denyIfUnsafe(_ snapshot: ProcessSnapshot) -> ActionResult? {
        if ProtectedProcessPolicy.isProtected(
            pid: snapshot.pid,
            bundleID: snapshot.bundleID,
            processName: snapshot.processName,
            path: snapshot.path
        ) {
            return ActionResult(ok: false, message: "该进程受保护，不会执行处理。", action: .none, pid: snapshot.pid)
        }
        if KeepAlivePolicy.isUserListed(bundleID: snapshot.bundleID, extras: extraKeepAliveBundleIDs) {
            return ActionResult(ok: false, message: "这是常用应用，不会降低优先级、冻结或退出。", action: .none, pid: snapshot.pid)
        }
        if snapshot.uid != currentUID {
            return ActionResult(ok: false, message: "只能处理当前用户的进程。", action: .none, pid: snapshot.pid)
        }
        if snapshot.isForeground {
            return ActionResult(ok: false, message: "不会处理后台以外的前台应用。", action: .none, pid: snapshot.pid)
        }
        return nil
    }

    private func sendSignal(pid: Int32, signal: Int32) -> (ok: Bool, message: String) {
        if kill(pid, signal) == 0 {
            return (true, "ok")
        }
        return (false, "向进程 \(pid) 发送信号失败：\(posixError())")
    }

    private func currentGeneration(pid: Int32) -> ProcessGeneration? {
        if let lookupGeneration {
            return lookupGeneration(pid)
        }
        return SystemMonitor.processGeneration(pid: pid)
    }

    private func recordedStartUnix(_ snapshot: ProcessSnapshot) -> TimeInterval {
        if snapshot.startUnix > 0 { return snapshot.startUnix }
        return currentGeneration(pid: snapshot.pid)?.startUnix ?? 0
    }

    private func generationMismatch(expected: ProcessGeneration, pid: Int32) -> String? {
        guard expected.isKnown else { return nil }
        guard let live = currentGeneration(pid: pid) else {
            return "进程 \(pid) 已退出，跳过操作以免误伤复用的 PID。"
        }
        if expected.sameGeneration(live) { return nil }
        return "进程 \(pid) 的启动时间已变，可能是 PID 复用，已拒绝操作。"
    }

    private func currentNice(pid: Int32) -> Int32? {
        errno = 0
        let value = getpriority(PRIO_PROCESS, UInt32(bitPattern: pid))
        if value == -1, errno != 0 {
            return nil
        }
        return value
    }

    /// Raising priority (lowering nice) usually needs privileges. Verify the kernel value.
    private func setNice(pid: Int32, value: Int32) -> Bool {
        errno = 0
        if setpriority(PRIO_PROCESS, UInt32(bitPattern: pid), value) == 0,
           niceMatches(pid: pid, value: value) {
            return true
        }
        if value <= 0, runTaskPolicy("-B", pid: pid), niceMatches(pid: pid, value: value) {
            return true
        }
        if value >= 20, runTaskPolicy("-b", pid: pid), niceMatches(pid: pid, value: value) {
            return true
        }
        return false
    }

    private func niceMatches(pid: Int32, value: Int32) -> Bool {
        guard let current = currentNice(pid: pid) else { return false }
        if value <= 0 { return current <= 0 }
        if value >= 15 { return current >= 15 }
        return abs(current - value) <= 1
    }

    private func runTaskPolicy(_ flag: String, pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        process.arguments = [flag, "-p", "\(pid)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func isGone(_ message: String) -> Bool {
        message.contains("No such process") || message.contains("没有那个进程")
    }

    private func posixError() -> String {
        String(cString: strerror(errno))
    }
}
