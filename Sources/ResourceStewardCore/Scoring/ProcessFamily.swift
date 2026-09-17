import Foundation

/// Chromium / Electron style apps split into a main process plus Helper / Renderer / GPU
/// children with their own bundle IDs. Those children must not be scored or acted on
/// independently: they inherit the parent's foreground / idle / workspace identity.
public enum ProcessFamily: Sendable {
    private static let hostedCompanions: [String: String] = [
        "org.mozilla.plugincontainer": "org.mozilla.firefox",
        "org.mozilla.firefox.plugincontainer": "org.mozilla.firefox",
        "com.tencent.xinWeChat.WeChatHelper": "com.tencent.xinWeChat"
    ]

    /// Sibling bundles that are not named `*.helper.*` but still belong to the parent app.
    /// OrbStack's VM (`dev.kdrag0n.MacVirt.vmgr`) is the process that actually runs containers.
    private static let familyPrefixes: [(prefix: String, root: String)] = [
        ("dev.kdrag0n.MacVirt.", "dev.kdrag0n.MacVirt"),
        ("com.docker.", "com.docker.docker"),
        ("com.tencent.xinWeChat.", "com.tencent.xinWeChat"),
        ("com.tencent.flue.", "com.tencent.xinWeChat")
    ]

    /// Parent bundle ID. `com.google.Chrome.helper.renderer` → `com.google.Chrome`.
    public static func rootBundleID(from bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return bundleID }
        if let mapped = hostedCompanions[bundleID] {
            return mapped
        }
        let lowered = bundleID.lowercased()
        for pair in familyPrefixes {
            if lowered.hasPrefix(pair.prefix.lowercased()),
               lowered != pair.root.lowercased() {
                return pair.root
            }
        }
        if let range = bundleID.range(of: ".electron-helper", options: .caseInsensitive) {
            let root = String(bundleID[..<range.lowerBound])
            return root.isEmpty ? bundleID : root
        }
        if let range = bundleID.range(of: ".helper", options: .caseInsensitive) {
            let root = String(bundleID[..<range.lowerBound])
            return root.isEmpty ? bundleID : root
        }
        return bundleID
    }

    public static func isCompanion(bundleID: String?, processName: String) -> Bool {
        if let bundleID, let root = rootBundleID(from: bundleID), root != bundleID {
            return true
        }
        if bundleID == nil {
            let name = processName.lowercased()
            return name.contains("helper")
                || name.contains("renderer")
                || name.contains("plugin-container")
                || name.contains("plugin container")
        }
        return false
    }

    public static func familyKey(bundleID: String?, pid: Int32) -> String {
        if let root = rootBundleID(from: bundleID), !root.isEmpty {
            return root
        }
        return "pid:\(pid)"
    }

    /// Keys used to look up last-foreground time so a Renderer inherits Chrome's idle.
    public static func identityKeys(bundleID: String?, processName: String) -> [String] {
        var keys: [String] = []
        func append(_ value: String?) {
            guard let value, !value.isEmpty, !keys.contains(value) else { return }
            keys.append(value)
        }
        append(bundleID)
        append(rootBundleID(from: bundleID))
        append(processName)
        return keys
    }

    public static func roleLabel(bundleID: String?, processName: String) -> String? {
        let blob = ((bundleID ?? "") + " " + processName).lowercased()
        if blob.contains("renderer") { return "Renderer" }
        if blob.contains("gpu") { return "GPU" }
        if blob.contains("plugin") { return "Plugin" }
        if blob.contains("alerts") { return "Alerts" }
        if isCompanion(bundleID: bundleID, processName: processName) { return "Helper" }
        return nil
    }

    /// Dock / Spotlight / Cmd-Tab opening an app should resume every frozen member of that family.
    public static func matchesUserOpen(
        frozenBundleID: String,
        frozenName: String,
        openedBundleID: String,
        openedName: String
    ) -> Bool {
        let frozenRoot = rootBundleID(from: frozenBundleID.isEmpty ? nil : frozenBundleID) ?? frozenBundleID
        let openedRoot = rootBundleID(from: openedBundleID.isEmpty ? nil : openedBundleID) ?? openedBundleID
        if !openedRoot.isEmpty, frozenRoot.caseInsensitiveCompare(openedRoot) == .orderedSame {
            return true
        }
        if !openedBundleID.isEmpty, frozenBundleID.caseInsensitiveCompare(openedBundleID) == .orderedSame {
            return true
        }
        if !openedName.isEmpty, frozenName.caseInsensitiveCompare(openedName) == .orderedSame {
            return true
        }
        return false
    }

    public static func isIndependentCompanionAction(snapshots: [ProcessSnapshot]) -> Bool {
        guard !snapshots.isEmpty else { return false }
        return snapshots.allSatisfy {
            isCompanion(bundleID: $0.bundleID, processName: $0.processName)
        }
    }
}
