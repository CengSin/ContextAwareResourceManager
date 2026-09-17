import Foundation

public enum ReclaimScorer: Sendable {
    public static func normalize(_ value: Double, cap: Double) -> Double {
        guard cap > 0 else { return 0 }
        return min(max(value, 0), cap) / cap
    }

    public static func suggestedAction(for score: Double, weights: ScoreWeights = .default) -> SuggestedAction {
        if score < weights.noneBelow { return .none }
        if score < weights.throttleBelow { return .throttle }
        if score < weights.freezeBelow { return .freeze }
        return .quit
    }

    public static func score(
        snapshot: ProcessSnapshot,
        workspace: Workspace?,
        weights: ScoreWeights = .default,
        blacklist: Set<String> = [],
        favorites: Set<String> = [],
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> ReclaimScoreRecord {
        let bundleID = snapshot.bundleID ?? ""
        let familyID = ProcessFamily.rootBundleID(from: snapshot.bundleID) ?? bundleID
        let protected = ProtectedProcessPolicy.isProtected(
            pid: snapshot.pid,
            bundleID: snapshot.bundleID,
            processName: snapshot.processName,
            path: snapshot.path,
            selfPID: selfPID
        )
        let blacklisted = blacklist.contains(bundleID)
            || blacklist.contains(familyID)
            || blacklist.contains(snapshot.processName)
        let favorited = KeepAlivePolicy.isUserListed(bundleID: snapshot.bundleID, extras: favorites)
            || KeepAlivePolicy.isUserListed(bundleID: familyID, extras: favorites)
        let inWorkspace: Bool = {
            guard let workspace else { return false }
            if !bundleID.isEmpty, workspace.coreAppBundleIDs.contains(bundleID) {
                return true
            }
            if !familyID.isEmpty, workspace.coreAppBundleIDs.contains(familyID) {
                return true
            }
            return false
        }()

        let idleN = normalize(snapshot.idleMinutes, cap: weights.idleCapMinutes)
        let memN = normalize(snapshot.memoryFootprintMB, cap: weights.memoryCapMB)
        let restart = RestartabilityTable.bonus(
            bundleID: familyID.isEmpty ? snapshot.bundleID : familyID,
            processName: snapshot.processName
        )

        // Spec: score is normalized to 0-100. Positive terms are scaled by (w1+w2+w3)
        // so the 85 quit threshold is reachable; penalties are then subtracted.
        let maxPositive = weights.positiveSum
        let idleContribution = weights.idle * idleN / maxPositive * 100
        let memoryContribution = weights.memory * memN / maxPositive * 100
        let restartContribution = weights.restartability * restart / maxPositive * 100
        let workspacePenalty = inWorkspace ? weights.workspace : 0
        let foregroundPenalty = snapshot.isForeground ? weights.foreground : 0
        let offWorkspaceContribution = (workspace != nil && !inWorkspace) ? weights.offWorkspace : 0

        let raw = idleContribution + memoryContribution + restartContribution + offWorkspaceContribution - workspacePenalty - foregroundPenalty
        var score = min(100, max(0, raw))
        var action = suggestedAction(for: score, weights: weights)

        if protected || blacklisted || favorited || snapshot.isForeground {
            score = 0
            action = .none
        }

        if inWorkspace && action == .quit {
            action = .none
        }

        if action != .none,
           !UserFacingAppPolicy.isSuggestable(
               bundleID: snapshot.bundleID,
               processName: snapshot.processName,
               path: snapshot.path,
               isAccessory: snapshot.isAccessory,
               isRegularApp: snapshot.isRegularApp
           ) {
            action = .none
        }

        return ReclaimScoreRecord(
            pid: snapshot.pid,
            bundleID: bundleID.isEmpty ? snapshot.processName : bundleID,
            processName: snapshot.processName,
            score: score,
            components: ScoreComponents(
                idleContribution: idleContribution,
                memorySizeContribution: memoryContribution,
                restartabilityContribution: restartContribution,
                workspacePenalty: workspacePenalty,
                foregroundPenalty: foregroundPenalty,
                offWorkspaceContribution: offWorkspaceContribution
            ),
            suggestedAction: action,
            estimatedReleaseMB: snapshot.memoryFootprintMB,
            isProtected: protected || blacklisted || favorited,
            isInCurrentWorkspace: inWorkspace
        )
    }

    public static func scoreAll(
        snapshots: [ProcessSnapshot],
        workspace: Workspace?,
        weights: ScoreWeights = .default,
        blacklist: Set<String> = [],
        favorites: Set<String> = [],
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [ReclaimScoreRecord] {
        snapshots
            .map { score(snapshot: $0, workspace: workspace, weights: weights, blacklist: blacklist, favorites: favorites, selfPID: selfPID) }
            .sorted { $0.score > $1.score }
    }

    public static func estimatedReleaseMB(from records: [ReclaimScoreRecord]) -> Double {
        records
            .filter { $0.suggestedAction != .none }
            .reduce(0) { $0 + $1.estimatedReleaseMB }
    }
}
