import AppKit
import Foundation


public enum InstalledAppCatalog: Sendable {
    public static func scan(
        extraRoots: [URL] = []
    ) -> [InstalledAppRecord] {
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        roots.append(contentsOf: extraRoots)

        var byID: [String: InstalledAppRecord] = [:]
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items where url.pathExtension.lowercased() == "app" {
                guard let record = record(fromAppURL: url), isThirdParty(bundleID: record.bundleID) else { continue }
                byID[record.bundleID] = record
            }
        }
        return byID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func isThirdParty(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        if id.isEmpty { return false }
        if id == "cc.resourcesteward.app" { return false }
        if id.hasPrefix("com.apple.") { return false }
        return true
    }

    public static func record(fromAppURL url: URL) -> InstalledAppRecord? {
        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier
            ?? stringValue(info: url.appendingPathComponent("Contents/Info.plist"), key: "CFBundleIdentifier")
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledAppRecord(bundleID: bundleID, name: name, path: url.path)
    }

}

public struct InstalledAppRecord: Sendable, Equatable, Identifiable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    public var path: String

    public init(bundleID: String, name: String, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

private extension InstalledAppCatalog {
    static func stringValue(info url: URL, key: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist[key] as? String
    }
}
