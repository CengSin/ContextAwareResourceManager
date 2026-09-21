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
        let bundleID: String?
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
                bundleID: hint.bundleID,
                bundlePrefix: bundlePrefix,
                executablePath: cleanExec
            )
        }

        for snapshot in snapshots {
            if pidToKey[snapshot.pid] != nil { continue }
            if let key = matchHint(snapshot, preparedHints: preparedHints) {
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

    private static func matchHint(
        _ snapshot: ProcessSnapshot,
        preparedHints: [PreparedHint]
    ) -> String? {
        let snapshotRoot = ProcessFamily.rootBundleID(from: snapshot.bundleID)
        let snapPath = snapshot.path.isEmpty ? "" : (snapshot.path as NSString).standardizingPath

        for hint in preparedHints {
            if let bundleID = snapshot.bundleID, let hintID = hint.bundleID,
               bundleID.caseInsensitiveCompare(hintID) == .orderedSame {
                return hint.key
            }
            if let snapshotRoot, snapshotRoot.caseInsensitiveCompare(hint.key) == .orderedSame {
                return hint.key
            }
            if let prefix = hint.bundlePrefix, !snapPath.isEmpty {
                if snapPath.hasPrefix(prefix) {
                    return hint.key
                }
            }
            if !hint.executablePath.isEmpty, !snapPath.isEmpty {
                if snapPath == hint.executablePath {
                    return hint.key
                }
            }
        }
        return nil
    }
}
