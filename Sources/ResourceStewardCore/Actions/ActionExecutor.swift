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
    private let lock = NSLock()
    private var frozen: [Int32: FrozenProcess] = [:]
    private var throttled: Set<Int32> = []
    private let currentUID = getuid()
    public var extraKeepAliveBundleIDs: Set<String> = []

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
        return throttled.contains(pid)
    }

    public func appliedAction(pid: Int32) -> SuggestedAction? {
        lock.lock()
        defer { lock.unlock() }
        if frozen[pid] != nil { return .freeze }
        if throttled.contains(pid) { return .throttle }
        return nil
    }

    public func prune(livePIDs: Set<Int32>) {
        lock.lock()
        frozen = frozen.filter { livePIDs.contains($0.key) }
        throttled = throttled.filter { livePIDs.contains($0) }
        lock.unlock()
    }

    public func execute(action: SuggestedAction, snapshots: [ProcessSnapshot], groupBundleID: String?) -> ActionResult {
        if action != .none, ProcessFamily.isIndependentCompanionAction(snapshots: snapshots) {
            return ActionResult(
                ok: false,
                message: "不会单独处理 Helper / Renderer。它们必须随主应用一起处理，否则开链接等功能会失效。",
                action: action,
                pid: snapshots.first?.pid ?? 0
            )
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

    public func thaw(pid: Int32) -> ActionResult {
        let result = sendSignal(pid: pid, signal: SIGCONT)
        if result.ok {
            lock.lock()
            frozen.removeValue(forKey: pid)
            lock.unlock()
            return ActionResult(ok: true, message: "已恢复进程 \(pid)", action: .freeze, pid: pid)
        }
        return ActionResult(ok: false, message: result.message, action: .freeze, pid: pid)
    }

    public func unthrottle(pid: Int32) -> ActionResult {
        let rc = setpriority(PRIO_PROCESS, UInt32(bitPattern: pid), 0)
        if rc != 0 {
            return ActionResult(ok: false, message: "恢复优先级失败：\(posixError())", action: .throttle, pid: pid)
        }
        lock.lock()
        throttled.remove(pid)
        lock.unlock()
        return ActionResult(ok: true, message: "已恢复进程 \(pid) 的 CPU 优先级", action: .throttle, pid: pid)
    }

    public func thawAll() {
        let pids = frozenProcesses.map(\.pid)
        for pid in pids {
            _ = thaw(pid: pid)
        }
        for pid in throttled {
            _ = setpriority(PRIO_PROCESS, UInt32(bitPattern: pid), 0)
        }
        lock.lock()
        throttled.removeAll()
        lock.unlock()
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
            ) {
                _ = kill(item.pid, SIGCONT)
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
        let rc = setpriority(PRIO_PROCESS, UInt32(bitPattern: snapshot.pid), 15)
        if rc != 0 {
            return ActionResult(ok: false, message: "降低优先级失败：\(posixError())", action: .throttle, pid: snapshot.pid)
        }
        lock.lock()
        throttled.insert(snapshot.pid)
        lock.unlock()
        return ActionResult(ok: true, message: "已降低 \(snapshot.processName) 的 CPU 优先级", action: .throttle, pid: snapshot.pid)
    }

    private func freeze(_ snapshot: ProcessSnapshot) -> ActionResult {
        if isFrozen(pid: snapshot.pid) {
            return ActionResult(ok: true, message: "\(snapshot.processName) 已处于冻结状态", action: .freeze, pid: snapshot.pid)
        }
        if let denied = denyIfUnsafe(snapshot) { return denied }
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
            action: .freeze
        )
        lock.unlock()
        return ActionResult(ok: true, message: "已冻结 \(snapshot.processName)。内存通常仍被占用，直到系统稍后自然回收。", action: .freeze, pid: snapshot.pid)
    }

    private func quit(_ snapshot: ProcessSnapshot) -> ActionResult {
        quitGroup(snapshots: [snapshot], bundleID: snapshot.bundleID)
    }

    private func quitGroup(snapshots: [ProcessSnapshot], bundleID: String?) -> ActionResult {
        if let first = snapshots.first, let denied = denyIfUnsafe(first) { return denied }
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

    private func posixError() -> String {
        String(cString: strerror(errno))
    }
}
