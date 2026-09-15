import Foundation

/// Chromium / Electron style apps split into a main process plus Helper / Renderer / GPU
/// children with their own bundle IDs. Those children must not be scored or acted on
/// independently: they inherit the parent's foreground / idle / workspace identity.
public enum ProcessFamily: Sendable {
    private static let hostedCompanions: [String: String] = [
        "org.mozilla.plugincontainer": "org.mozilla.firefox",
        "org.mozilla.firefox.plugincontainer": "org.mozilla.firefox"
    ]

    /// Parent bundle ID. `com.google.Chrome.helper.renderer` → `com.google.Chrome`.
    public static func rootBundleID(from bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return bundleID }
        if let mapped = hostedCompanions[bundleID] {
            return mapped
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

    public static func isIndependentCompanionAction(snapshots: [ProcessSnapshot]) -> Bool {
        guard !snapshots.isEmpty else { return false }
        return snapshots.allSatisfy {
            isCompanion(bundleID: $0.bundleID, processName: $0.processName)
        }
    }
}
