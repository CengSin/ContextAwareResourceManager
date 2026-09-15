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
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> ReclaimScoreRecord {
        let bundleID = snapshot.bundleID ?? ""
        let protected = ProtectedProcessPolicy.isProtected(
            pid: snapshot.pid,
            bundleID: snapshot.bundleID,
            processName: snapshot.processName,
            selfPID: selfPID
        )
        let blacklisted = blacklist.contains(bundleID) || blacklist.contains(snapshot.processName)
        let inWorkspace: Bool = {
            guard let workspace else { return false }
            if let id = snapshot.bundleID, workspace.coreAppBundleIDs.contains(id) {
                return true
            }
            return false
        }()

        let idleN = normalize(snapshot.idleMinutes, cap: weights.idleCapMinutes)
        let memN = normalize(snapshot.memoryFootprintMB, cap: weights.memoryCapMB)
        let restart = RestartabilityTable.bonus(bundleID: snapshot.bundleID, processName: snapshot.processName)

        // Spec: score is normalized to 0-100. Positive terms are scaled by (w1+w2+w3)
        // so the 85 quit threshold is reachable; penalties are then subtracted.
        let maxPositive = weights.positiveSum
        let idleContribution = weights.idle * idleN / maxPositive * 100
        let memoryContribution = weights.memory * memN / maxPositive * 100
        let restartContribution = weights.restartability * restart / maxPositive * 100
        let workspacePenalty = inWorkspace ? weights.workspace : 0
        let foregroundPenalty = snapshot.isForeground ? weights.foreground : 0

        let raw = idleContribution + memoryContribution + restartContribution - workspacePenalty - foregroundPenalty
        var score = min(100, max(0, raw))
        var action = suggestedAction(for: score, weights: weights)

        if protected || blacklisted || snapshot.isForeground {
            score = 0
            action = .none
        }

        if inWorkspace && action == .quit {
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
                foregroundPenalty: foregroundPenalty
            ),
            suggestedAction: action,
            estimatedReleaseMB: snapshot.memoryFootprintMB,
            isProtected: protected || blacklisted,
            isInCurrentWorkspace: inWorkspace
        )
    }

    public static func scoreAll(
        snapshots: [ProcessSnapshot],
        workspace: Workspace?,
        weights: ScoreWeights = .default,
        blacklist: Set<String> = [],
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [ReclaimScoreRecord] {
        snapshots
            .map { score(snapshot: $0, workspace: workspace, weights: weights, blacklist: blacklist, selfPID: selfPID) }
            .sorted { $0.score > $1.score }
    }

    public static func estimatedReleaseMB(from records: [ReclaimScoreRecord]) -> Double {
        records
            .filter { $0.suggestedAction != .none }
            .reduce(0) { $0 + $1.estimatedReleaseMB }
    }
}
