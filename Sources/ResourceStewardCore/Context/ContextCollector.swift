import AppKit
import Foundation

public final class ContextCollector: @unchecked Sendable {
    public private(set) var lastForegroundAt: [String: Date] = [:]
    public private(set) var lastForegroundBundleID: String?
    public private(set) var lastForegroundName: String?

    private var observations: [NSObjectProtocol] = []
    private let lock = NSLock()
    private let onActivation: @Sendable (AppActivation) -> Void

    public init(onActivation: @escaping @Sendable (AppActivation) -> Void) {
        self.onActivation = onActivation
    }

    public func start() {
        stop()
        captureCurrent()
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let name = app?.localizedName ?? app?.executableURL?.lastPathComponent
            self?.record(bundleID: bundleID, name: name)
        }
        observations.append(token)
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in observations {
            center.removeObserver(token)
        }
        observations.removeAll()
    }

    public func idleSeconds(for bundleID: String?, processName: String, startUnix: TimeInterval, now: Date = Date()) -> TimeInterval {
        lock.lock()
        let lastByBundle = bundleID.flatMap { lastForegroundAt[$0] }
        let lastByName = lastForegroundAt[processName]
        lock.unlock()
        if let lastByBundle {
            return max(0, now.timeIntervalSince(lastByBundle))
        }
        if let lastByName {
            return max(0, now.timeIntervalSince(lastByName))
        }
        if startUnix > 0 {
            return max(0, now.timeIntervalSince1970 - startUnix)
        }
        return 0
    }

    public func isForeground(bundleID: String?, processName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let bundleID, bundleID == lastForegroundBundleID {
            return true
        }
        return processName == lastForegroundName
    }

    private func captureCurrent() {
        let app = NSWorkspace.shared.frontmostApplication
        record(bundleID: app?.bundleIdentifier, name: app?.localizedName ?? app?.executableURL?.lastPathComponent)
    }

    private func record(bundleID: String?, name: String?) {
        let resolvedName = name ?? "unknown"
        let now = Date()
        lock.lock()
        if let bundleID, !bundleID.isEmpty {
            lastForegroundAt[bundleID] = now
            lastForegroundBundleID = bundleID
        } else {
            lastForegroundAt[resolvedName] = now
            lastForegroundBundleID = nil
        }
        lastForegroundName = resolvedName
        lock.unlock()
        if let bundleID, !bundleID.isEmpty {
            onActivation(AppActivation(timestamp: now, bundleID: bundleID, processName: resolvedName))
        }
    }
}

public enum BundleIdentity: Sendable {
    public static func bundleID(fromPath path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if url.pathExtension == "app" {
                return Bundle(url: url)?.bundleIdentifier
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    public static func appPath(fromExecutable path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if url.pathExtension == "app" {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return path
    }
}
