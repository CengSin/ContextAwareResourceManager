import AppKit
import Foundation

public enum WorkspaceAppEligibility: Sendable {
    /// NSApplication.ActivationPolicy: regular=0, accessory=1, prohibited=2.
    public static func shouldList(
        bundleID: String?,
        name: String,
        path: String,
        pid: Int32,
        activationPolicy: Int?,
        isProtected: Bool
    ) -> Bool {
        if isProtected { return false }
        if pid == ProcessInfo.processInfo.processIdentifier { return false }
        guard let bundleID, !bundleID.isEmpty else { return false }
        if bundleID == "cc.resourcesteward.app" { return false }
        if name == "ResourceSteward" { return false }
        if ProcessFamily.isCompanion(bundleID: bundleID, processName: name) { return false }
        if let activationPolicy, activationPolicy == 2 { return false }
        if let activationPolicy, activationPolicy == 0 || activationPolicy == 1 {
            return true
        }
        return path.contains(".app") || bundleID.contains(".")
    }
}

public enum RunningAppCatalog {
    public static func collect(currentUID _: uid_t) -> [RunningAppInfo] {
        var apps: [String: RunningAppInfo] = [:]

        for app in NSWorkspace.shared.runningApplications {
            let bundleID = app.bundleIdentifier
            let name = app.localizedName ?? app.executableURL?.lastPathComponent ?? bundleID ?? "unknown"
            let path = app.bundleURL?.path ?? app.executableURL?.path ?? ""
            let pid = app.processIdentifier
            let policy = Int(app.activationPolicy.rawValue)
            let protected = ProtectedProcessPolicy.isProtected(
                pid: pid,
                bundleID: bundleID,
                processName: name,
                path: path
            )
            guard WorkspaceAppEligibility.shouldList(
                bundleID: bundleID,
                name: name,
                path: path,
                pid: pid,
                activationPolicy: policy,
                isProtected: protected
            ), let bundleID else { continue }

            apps[bundleID] = RunningAppInfo(
                bundleID: bundleID,
                name: name,
                path: path,
                isBackground: app.activationPolicy != .regular || app.isHidden
            )
        }

        return apps.values.sorted { lhs, rhs in
            if lhs.isBackground != rhs.isBackground {
                return !lhs.isBackground && rhs.isBackground
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func mergingProcessSnapshots(
        existing: [RunningAppInfo],
        snapshots: [ProcessSnapshot],
        currentUID: uid_t
    ) -> [RunningAppInfo] {
        var apps = Dictionary(uniqueKeysWithValues: existing.map { ($0.bundleID, $0) })
        for snapshot in snapshots {
            guard snapshot.uid == currentUID else { continue }
            let bundleID = snapshot.bundleID
            let protected = ProtectedProcessPolicy.isProtected(
                pid: snapshot.pid,
                bundleID: bundleID,
                processName: snapshot.processName,
                path: snapshot.path
            )
            guard WorkspaceAppEligibility.shouldList(
                bundleID: bundleID,
                name: snapshot.processName,
                path: snapshot.path,
                pid: snapshot.pid,
                activationPolicy: nil,
                isProtected: protected
            ), let bundleID else { continue }
            if apps[bundleID] == nil {
                apps[bundleID] = RunningAppInfo(
                    bundleID: bundleID,
                    name: snapshot.processName,
                    path: snapshot.path,
                    isBackground: true
                )
            }
        }
        return apps.values.sorted { lhs, rhs in
            if lhs.isBackground != rhs.isBackground {
                return !lhs.isBackground && rhs.isBackground
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
