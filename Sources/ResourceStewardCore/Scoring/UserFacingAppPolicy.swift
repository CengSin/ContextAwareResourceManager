import Foundation

/// Distinguishes Dock-visible user apps from daemons, widgets, and menu-bar accessories.
///
/// Level 1 previously treated any reverse-DNS bundle ID as an app, so `chronod`,
/// Control Strip, and widget extensions were auto-throttled. Those actions never
/// change what the user feels, and they crowd "只看建议".
public enum UserFacingAppPolicy: Sendable {
    public static let appleUserBundleIDs: Set<String> = [
        "com.apple.safari",
        "com.apple.music",
        "com.apple.tv",
        "com.apple.notes",
        "com.apple.mail",
        "com.apple.preview",
        "com.apple.textedit",
        "com.apple.photos",
        "com.apple.facetime",
        "com.apple.mobilesms",
        "com.apple.ical",
        "com.apple.reminders",
        "com.apple.maps",
        "com.apple.podcasts",
        "com.apple.news",
        "com.apple.freeform",
        "com.apple.weather",
        "com.apple.stocks",
        "com.apple.shortcuts",
        "com.apple.home",
        "com.apple.terminal",
        "com.apple.dt.xcode",
        "com.apple.iphonesimulator",
        "com.apple.dt.instruments",
        "com.apple.activitymonitor",
        "com.apple.console",
        "com.apple.calculator",
        "com.apple.dictionary",
        "com.apple.quicktimeplayerx",
        "com.apple.ibooks",
        "com.apple.iwork.pages",
        "com.apple.iwork.numbers",
        "com.apple.iwork.keynote",
        "com.apple.fontbook",
        "com.apple.automator",
        "com.apple.screen-sharing"
    ]

    public static func isSuggestable(
        bundleID: String?,
        processName: String,
        path: String = "",
        isAccessory: Bool = false,
        isRegularApp: Bool = true
    ) -> Bool {
        if isAccessory { return false }
        if ProcessFamily.isCompanion(bundleID: bundleID, processName: processName) {
            return false
        }
        if isWidgetOrExtension(bundleID: bundleID, processName: processName) {
            return false
        }
        let id = (bundleID ?? "").lowercased()
        if id.hasPrefix("com.apple.") {
            return isAllowedAppleApp(id)
        }
        if id.isEmpty {
            return false
        }
        if !isRegularApp { return false }
        if !path.isEmpty, !path.lowercased().contains(".app") { return false }
        return true
    }

    public static func isAutoEligible(
        bundleID: String?,
        processName: String,
        path: String = "",
        isAccessory: Bool = false,
        isRegularApp: Bool = true
    ) -> Bool {
        let id = bundleID ?? ""
        guard id.contains(".") else { return false }
        guard isRegularApp, !isAccessory else { return false }
        guard isSuggestable(
            bundleID: bundleID,
            processName: processName,
            path: path,
            isAccessory: isAccessory,
            isRegularApp: isRegularApp
        ) else { return false }
        if id.lowercased() == "com.apple.finder" { return false }
        return true
    }

    public static func isAllowedAppleApp(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        if appleUserBundleIDs.contains(id) { return true }
        if id.hasPrefix("com.apple.iwork.") { return true }
        if id.hasPrefix("com.apple.dt.xcode") { return true }
        return false
    }

    public static func isWidgetOrExtension(bundleID: String?, processName: String) -> Bool {
        let blob = ((bundleID ?? "") + " " + processName).lowercased()
        return blob.contains("widgetextension")
            || blob.contains("widgetapplication")
            || blob.contains("widget extension")
            || blob.contains(".appex")
            || blob.contains("pluginkit")
            || blob.contains(".xpc")
            || blob.contains("safebrowsing")
    }
}
