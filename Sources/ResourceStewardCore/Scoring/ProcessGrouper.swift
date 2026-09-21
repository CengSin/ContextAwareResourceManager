import Foundation


public struct AppProcessHint: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    public var bundlePath: String
    public var executablePath: String
    public var isRegularApp: Bool
    public var isAccessory: Bool

    public init(
        pid: Int32,
        bundleID: String?,
        name: String,
        bundlePath: String = "",
        executablePath: String = "",
        isRegularApp: Bool = true,
        isAccessory: Bool = false
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.isRegularApp = isRegularApp
        self.isAccessory = isAccessory
    }

    public var familyKey: String {
        ProcessFamily.familyKey(bundleID: bundleID, pid: pid)
    }
}


public enum ProcessGrouper: Sendable {
    private struct PreparedHint: Sendable {
        let key: String
        let bundlePrefix: String?
        let executablePath: String
    }

    public static func keys(
        snapshots: [ProcessSnapshot],
        hints: [AppProcessHint] = []
    ) -> [Int32: String] {
        var pidToKey: [Int32: String] = [:]

        for hint in hints where hint.pid > 0 {
            pidToKey[hint.pid] = hint.familyKey
        }

        let preparedHints: [PreparedHint] = hints.map { hint in
            let key = pidToKey[hint.pid] ?? hint.familyKey
            let cleanBundle = hint.bundlePath.isEmpty ? nil : (hint.bundlePath as NSString).standardizingPath
            let bundlePrefix = cleanBundle.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
            let cleanExec = hint.executablePath.isEmpty ? "" : (hint.executablePath as NSString).standardizingPath
            return PreparedHint(
                key: key,
                bundlePrefix: bundlePrefix,
                executablePath: cleanExec
            )
        }

        var bundleIndex: [String: Int] = [:]
        var familyIndex: [String: Int] = [:]
        var executableIndex: [String: Int] = [:]
        var directoryIndex: [String: Int] = [:]
        for (index, hint) in hints.enumerated() {
            if let bundleID = hint.bundleID {
                let key = comparisonKey(bundleID)
                if bundleIndex[key] == nil { bundleIndex[key] = index }
            }
            let family = comparisonKey(preparedHints[index].key)
            if familyIndex[family] == nil { familyIndex[family] = index }
            if let prefix = preparedHints[index].bundlePrefix, directoryIndex[prefix] == nil {
                directoryIndex[prefix] = index
            }
            let executable = preparedHints[index].executablePath
            if !executable.isEmpty, executableIndex[executable] == nil { executableIndex[executable] = index }
        }

        for snapshot in snapshots {
            if pidToKey[snapshot.pid] != nil { continue }
            if let key = matchHint(
                snapshot, preparedHints: preparedHints, bundleIndex: bundleIndex,
                familyIndex: familyIndex, executableIndex: executableIndex, directoryIndex: directoryIndex
            ) {
                pidToKey[snapshot.pid] = key
            }
        }

        var changed = true
        while changed {
            changed = false
            for snapshot in snapshots {
                if pidToKey[snapshot.pid] != nil { continue }
                guard snapshot.parentPID > 0, let parentKey = pidToKey[snapshot.parentPID] else { continue }
                pidToKey[snapshot.pid] = parentKey
                changed = true
            }
        }

        for snapshot in snapshots {
            if pidToKey[snapshot.pid] == nil {
                pidToKey[snapshot.pid] = ProcessFamily.familyKey(bundleID: snapshot.bundleID, pid: snapshot.pid)
            }
        }

        changed = true
        while changed {
            changed = false
            for snapshot in snapshots {
                guard snapshot.parentPID > 0, let parentKey = pidToKey[snapshot.parentPID] else { continue }
                let mine = pidToKey[snapshot.pid]
                if mine == parentKey { continue }
                if let mine, !mine.hasPrefix("pid:") { continue }
                pidToKey[snapshot.pid] = parentKey
                changed = true
            }
        }
        return pidToKey
    }

    public static func pathIsInside(_ path: String, directory: String) -> Bool {
        if path.isEmpty || directory.isEmpty { return false }
        let cleanPath = (path as NSString).standardizingPath
        let cleanDir = (directory as NSString).standardizingPath
        if cleanPath == cleanDir { return false }
        let prefix = cleanDir.hasSuffix("/") ? cleanDir : cleanDir + "/"
        return cleanPath.hasPrefix(prefix)
    }

    private static func comparisonKey(_ value: String) -> String {
        value.folding(options: .caseInsensitive, locale: nil)
    }

    private static func matchHint(
        _ snapshot: ProcessSnapshot,
        preparedHints: [PreparedHint],
        bundleIndex: [String: Int],
        familyIndex: [String: Int],
        executableIndex: [String: Int],
        directoryIndex: [String: Int]
    ) -> String? {
        var first = preparedHints.count
        if let bundleID = snapshot.bundleID, let index = bundleIndex[comparisonKey(bundleID)] {
            first = index
        }
        if let root = ProcessFamily.rootBundleID(from: snapshot.bundleID), let index = familyIndex[comparisonKey(root)] {
            first = min(first, index)
        }
        let path = snapshot.path.isEmpty ? "" : (snapshot.path as NSString).standardizingPath
        if !path.isEmpty {
            if let index = executableIndex[path] { first = min(first, index) }
            for boundary in path.utf8.indices where path.utf8[boundary] == 47 {
                let prefix = String(decoding: path.utf8[...boundary], as: UTF8.self)
                if let index = directoryIndex[prefix] {
                    first = min(first, index)
                }
            }
        }
        return first < preparedHints.count ? preparedHints[first].key : nil
    }
}
