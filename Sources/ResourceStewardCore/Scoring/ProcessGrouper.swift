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
    public static func keys(
        snapshots: [ProcessSnapshot],
        hints: [AppProcessHint] = []
    ) -> [Int32: String] {
        var pidToKey: [Int32: String] = [:]

        for hint in hints where hint.pid > 0 {
            pidToKey[hint.pid] = hint.familyKey
        }

        for snapshot in snapshots {
            if pidToKey[snapshot.pid] != nil { continue }
            if let key = matchHint(snapshot, hints: hints, pidToKey: pidToKey) {
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
        let cleanPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let cleanDir = URL(fileURLWithPath: directory).standardizedFileURL.path
        if cleanPath == cleanDir { return false }
        return cleanPath.hasPrefix(cleanDir.hasSuffix("/") ? cleanDir : cleanDir + "/")
    }

    private static func matchHint(
        _ snapshot: ProcessSnapshot,
        hints: [AppProcessHint],
        pidToKey: [Int32: String]
    ) -> String? {
        let snapshotRoot = ProcessFamily.rootBundleID(from: snapshot.bundleID)
        for hint in hints {
            let key = pidToKey[hint.pid] ?? hint.familyKey
            if let bundleID = snapshot.bundleID, let hintID = hint.bundleID,
               bundleID.caseInsensitiveCompare(hintID) == .orderedSame {
                return key
            }
            if let snapshotRoot, snapshotRoot.caseInsensitiveCompare(key) == .orderedSame {
                return key
            }
            if pathIsInside(snapshot.path, directory: hint.bundlePath) {
                return key
            }
            if !hint.executablePath.isEmpty {
                let snapPath = URL(fileURLWithPath: snapshot.path).standardizedFileURL.path
                let hintPath = URL(fileURLWithPath: hint.executablePath).standardizedFileURL.path
                if snapPath == hintPath {
                    return key
                }
            }
        }
        return nil
    }
}
