import Foundation

/// Scene matching by distinctive evidence, not Jaccard.
///
/// Jaccard divides by the size of the scene's core-app list, so a work scene with
/// many tools loses to a small entertainment scene as soon as a shared app
/// (Chrome) is in the foreground. Evidence only scores apps the user is actually
/// using; unused core apps do not count against the scene. Shared apps are weak
/// (`1/df`); exclusive apps such as a JetBrains IDE are strong (`1.0`).
public enum WorkspaceMatcher: Sendable {
    public static let defaultMinEvidence: Double = 0.6
    public static let defaultMinMargin: Double = 0.35
    public static let recencyHalfLifeMinutes: Double = 8
    public static let stayBonus: Double = 0.3

    public static func recency(
        minutesAgo: Double,
        halfLifeMinutes: Double = recencyHalfLifeMinutes
    ) -> Double {
        if minutesAgo <= 0 { return 1 }
        if halfLifeMinutes <= 0 { return 1 }
        return pow(0.5, minutesAgo / halfLifeMinutes)
    }

    public static func documentFrequency(workspaces: [Workspace]) -> [String: Int] {
        var df: [String: Int] = [:]
        for workspace in workspaces {
            for bundleID in workspace.coreAppBundleIDs where !bundleID.isEmpty {
                df[bundleID, default: 0] += 1
            }
        }
        return df
    }

    public static func evidence(
        workspace: Workspace,
        latestActivations: [String: Date],
        documentFrequency: [String: Int],
        now: Date
    ) -> Double {
        var score = 0.0
        for (bundleID, timestamp) in latestActivations {
            guard workspace.coreAppBundleIDs.contains(bundleID) else { continue }
            let df = documentFrequency[bundleID, default: 0]
            guard df > 0 else { continue }
            let minutesAgo = max(0, now.timeIntervalSince(timestamp) / 60)
            score += (1.0 / Double(df)) * recency(minutesAgo: minutesAgo)
        }
        return score
    }

    public static func exclusiveHitCount(
        workspace: Workspace,
        active: Set<String>,
        documentFrequency: [String: Int]
    ) -> Int {
        workspace.coreAppBundleIDs.intersection(active).reduce(0) { count, bundleID in
            documentFrequency[bundleID, default: 0] == 1 ? count + 1 : count
        }
    }

    public static func match(
        workspaces: [Workspace],
        activations: [AppActivation],
        now: Date = Date(),
        windowMinutes: Double = 10,
        threshold: Double = defaultMinEvidence,
        minMargin: Double = defaultMinMargin,
        stickyWorkspaceID: UUID? = nil
    ) -> WorkspaceMatch {
        let windowStart = now.addingTimeInterval(-windowMinutes * 60)
        var latest: [String: Date] = [:]
        for activation in activations {
            guard activation.timestamp >= windowStart, !activation.bundleID.isEmpty else { continue }
            let bundleID = ProcessFamily.rootBundleID(from: activation.bundleID) ?? activation.bundleID
            if let existing = latest[bundleID], existing >= activation.timestamp {
                continue
            }
            latest[bundleID] = activation.timestamp
        }
        let active = Set(latest.keys)

        guard !workspaces.isEmpty, !active.isEmpty else {
            return WorkspaceMatch(workspace: nil, similarity: 0, activeBundleIDs: active)
        }

        let df = documentFrequency(workspaces: workspaces)
        struct Ranked {
            let workspace: Workspace
            let evidence: Double
            let exclusiveHits: Int
        }
        let ranked: [Ranked] = workspaces.map { workspace in
            Ranked(
                workspace: workspace,
                evidence: evidence(
                    workspace: workspace,
                    latestActivations: latest,
                    documentFrequency: df,
                    now: now
                ),
                exclusiveHits: exclusiveHitCount(
                    workspace: workspace,
                    active: active,
                    documentFrequency: df
                )
            )
        }
        var scores: [UUID: Double] = [:]
        for item in ranked {
            scores[item.workspace.id] = item.evidence
        }

        let ordered = ranked.sorted { lhs, rhs in
            if lhs.evidence != rhs.evidence { return lhs.evidence > rhs.evidence }
            if lhs.exclusiveHits != rhs.exclusiveHits { return lhs.exclusiveHits > rhs.exclusiveHits }
            return lhs.workspace.lastActiveAt > rhs.workspace.lastActiveAt
        }

        let best = ordered.first
        let sticky = stickyWorkspaceID.flatMap { id in ordered.first { $0.workspace.id == id } }
        let challenger = ordered.first { $0.workspace.id != stickyWorkspaceID }

        let chosen: Ranked?
        if let sticky, sticky.evidence > 0 {
            let shouldSwitch: Bool = {
                guard let challenger else { return false }
                return challenger.evidence > sticky.evidence + stayBonus
                    && challenger.exclusiveHits >= sticky.exclusiveHits
            }()
            chosen = shouldSwitch ? challenger : sticky
        } else {
            chosen = best
        }

        guard let chosen, chosen.evidence > 0 else {
            return WorkspaceMatch(
                workspace: nil,
                similarity: best?.evidence ?? 0,
                activeBundleIDs: active,
                scoresByWorkspaceID: scores
            )
        }

        let stayingOnSticky = stickyWorkspaceID == chosen.workspace.id
        if !stayingOnSticky, chosen.exclusiveHits == 0 {
            if chosen.evidence < threshold {
                return WorkspaceMatch(
                    workspace: nil,
                    similarity: chosen.evidence,
                    activeBundleIDs: active,
                    scoresByWorkspaceID: scores
                )
            }
            let second = ordered.first { $0.workspace.id != chosen.workspace.id }?.evidence ?? 0
            if chosen.evidence - second < minMargin {
                return WorkspaceMatch(
                    workspace: nil,
                    similarity: chosen.evidence,
                    activeBundleIDs: active,
                    scoresByWorkspaceID: scores
                )
            }
        }

        return WorkspaceMatch(
            workspace: chosen.workspace,
            similarity: chosen.evidence,
            activeBundleIDs: active,
            scoresByWorkspaceID: scores
        )
    }
}
