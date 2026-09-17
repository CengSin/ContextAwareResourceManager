import AppKit
import CoreGraphics
import Foundation

/// A CG window that may participate in WindowServer on-glass transactions.
///
/// SIGSTOP of a process that owns such a window can stall the compositor:
/// WindowServer waits for a surface that never arrives, then userspace watchdog
/// kills WindowServer and the GUI session restarts.
public struct WindowSurface: Sendable, Equatable {
    public let ownerPID: Int32
    public let layer: Int
    public let width: Double
    public let height: Double
    public let alpha: Double

    public init(ownerPID: Int32, layer: Int, width: Double, height: Double, alpha: Double = 1) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.width = width
        self.height = height
        self.alpha = alpha
    }

    /// Menu bar and above (layer >= 24) are not app document surfaces.
    public var participatesInCompositor: Bool {
        alpha > 0.01 && width >= 2 && height >= 2 && layer < 24
    }
}

public enum WindowedProcessPolicy: Sendable {
    public static func ownerPIDs(from windows: [WindowSurface]) -> Set<Int32> {
        Set(windows.filter(\.participatesInCompositor).map(\.ownerPID))
    }

    /// If the live window list cannot be trusted, treat regular AppKit apps as windowed.
    public static func snapshotOwnsWindows(
        pid: Int32,
        isRegularApp: Bool,
        ownerPIDs: Set<Int32>?
    ) -> Bool {
        guard let ownerPIDs else { return isRegularApp }
        return ownerPIDs.contains(pid)
    }

    public static func isUnsafeToFreeze(pid: Int32, bundleID: String?) -> Bool {
        isUnsafeToFreeze(pid: pid, bundleID: bundleID, ownerPIDs: currentOwnerPIDs())
    }

    /// `ownerPIDs == nil` means the window list is missing or incomplete: fail closed.
    public static func isUnsafeToFreeze(pid: Int32, bundleID: String?, ownerPIDs: Set<Int32>?) -> Bool {
        guard let ownerPIDs else { return true }
        if ownerPIDs.contains(pid) { return true }
        guard let bundleID, !bundleID.isEmpty else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { ownerPIDs.contains($0.processIdentifier) }
    }

    /// `nil` means the list is missing or incomplete — callers must fail closed.
    public static func currentOwnerPIDs() -> Set<Int32>? {
        let options = CGWindowListOption(arrayLiteral: .optionAll, .excludeDesktopElements)
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              !raw.isEmpty
        else { return nil }

        let pids = ownerPIDs(from: raw.compactMap(parse))
        if let front = NSWorkspace.shared.frontmostApplication,
           front.activationPolicy == .regular,
           front.processIdentifier > 0,
           !pids.contains(front.processIdentifier)
        {
            return nil
        }
        return pids
    }

    public static func parse(_ dict: [String: Any]) -> WindowSurface? {
        let pidValue = dict[kCGWindowOwnerPID as String] ?? dict["kCGWindowOwnerPID"]
        let pid: Int32
        if let n = pidValue as? Int32 {
            pid = n
        } else if let n = pidValue as? Int {
            pid = Int32(n)
        } else if let n = pidValue as? NSNumber {
            pid = n.int32Value
        } else {
            return nil
        }

        let layerValue = dict[kCGWindowLayer as String] ?? dict["kCGWindowLayer"]
        let layer = (layerValue as? Int) ?? (layerValue as? NSNumber)?.intValue ?? 0
        let alphaValue = dict[kCGWindowAlpha as String] ?? dict["kCGWindowAlpha"]
        let alpha = (alphaValue as? Double) ?? (alphaValue as? NSNumber)?.doubleValue ?? 1

        var width = 0.0
        var height = 0.0
        if let bounds = dict[kCGWindowBounds as String] as? [String: Any]
            ?? dict["kCGWindowBounds"] as? [String: Any]
        {
            width = doubleValue(bounds["Width"] ?? bounds["width"])
            height = doubleValue(bounds["Height"] ?? bounds["height"])
        }
        return WindowSurface(ownerPID: pid, layer: layer, width: width, height: height, alpha: alpha)
    }

    private static func doubleValue(_ raw: Any?) -> Double {
        if let d = raw as? Double { return d }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let i = raw as? Int { return Double(i) }
        return 0
    }
}
