import Foundation

/// Static restartability bonus in 0...1. Higher means safer to quit/freeze.
/// Default is 0.5 per spec.
public enum RestartabilityTable: Sendable {
    public static let `default`: Double = 0.5

    private static let byBundleID: [String: Double] = [
        "com.google.Chrome": 0.85,
        "com.google.Chrome.helper": 0.9,
        "com.apple.Safari": 0.7,
        "org.mozilla.firefox": 0.8,
        "com.microsoft.edgemac": 0.85,
        "com.brave.Browser": 0.85,
        "company.thebrowser.Browser": 0.8,
        "com.apple.Music": 0.9,
        "com.spotify.client": 0.9,
        "com.colliderli.iina": 0.95,
        "org.videolan.vlc": 0.95,
        "com.apple.TV": 0.9,
        "com.tencent.xinWeChat": 0.65,
        "com.tencent.qq": 0.7,
        "com.tinyspeck.slackmacgap": 0.7,
        "com.hnc.Discord": 0.75,
        "net.whatsapp.WhatsApp": 0.7,
        "ru.keepcoder.Telegram": 0.7,
        "com.apple.MobileSMS": 0.6,
        "com.microsoft.VSCode": 0.2,
        "com.apple.dt.Xcode": 0.15,
        "com.jetbrains.intellij": 0.15,
        "com.jetbrains.WebStorm": 0.15,
        "com.todesktop.230313mzl4w4u92": 0.2, // Cursor
        "dev.warp.Warp-Stable": 0.35,
        "com.googlecode.iterm2": 0.35,
        "com.apple.Terminal": 0.35,
        "com.apple.finder": 0.25,
        "com.apple.Notes": 0.2,
        "com.apple.iWork.Pages": 0.15,
        "com.apple.iWork.Numbers": 0.15,
        "com.apple.iWork.Keynote": 0.15,
        "com.microsoft.Word": 0.15,
        "com.microsoft.Excel": 0.15,
        "com.microsoft.Powerpoint": 0.15,
        "com.figma.Desktop": 0.25,
        "com.bohemiancoding.sketch3": 0.2,
        "com.apple.mail": 0.35,
        "com.apple.Preview": 0.55,
        "com.docker.docker": 0.3,
        "com.electron.dockerdesktop": 0.3
    ]

    private static let byNameFragment: [(String, Double)] = [
        ("chrome helper", 0.9),
        ("google chrome", 0.85),
        ("safari", 0.7),
        ("firefox", 0.8),
        ("spotify", 0.9),
        ("music", 0.85),
        ("wechat", 0.65),
        ("weixin", 0.65),
        ("slack", 0.7),
        ("discord", 0.75),
        ("code", 0.25),
        ("xcode", 0.15),
        ("idea", 0.15),
        ("webstorm", 0.15),
        ("cursor", 0.2),
        ("docker", 0.3),
        ("node", 0.55),
        ("python", 0.45)
    ]

    public static func bonus(bundleID: String?, processName: String) -> Double {
        if let bundleID, let value = byBundleID[bundleID] {
            return value
        }
        if let bundleID {
            for (key, value) in byBundleID where bundleID.hasPrefix(key) {
                return value
            }
        }
        let lowered = processName.lowercased()
        for (fragment, value) in byNameFragment where lowered.contains(fragment) {
            return value
        }
        return `default`
    }
}

public enum ProtectedProcessPolicy: Sendable {
    public static let names: Set<String> = [
        "kernel_task",
        "launchd",
        "WindowServer",
        "loginwindow",
        "Dock",
        "SystemUIServer",
        "ControlCenter",
        "NotificationCenter",
        "cfprefsd",
        "UserEventAgent",
        "runningboardd",
        "logd",
        "configd",
        "securityd",
        "syspolicyd",
        "coreservicesd",
        "launchservicesd",
        "ResourceSteward"
    ]

    public static let bundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "cc.resourcesteward.app"
    ]

    public static func isProtected(
        pid: Int32,
        bundleID: String?,
        processName: String,
        path: String = "",
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        if pid <= 1 || pid == selfPID {
            return true
        }
        if names.contains(processName) {
            return true
        }
        if let bundleID, bundleIDs.contains(bundleID) {
            return true
        }
        if KeepAlivePolicy.isKeepAlive(bundleID: bundleID, processName: processName, path: path) {
            return true
        }
        return false
    }
}
