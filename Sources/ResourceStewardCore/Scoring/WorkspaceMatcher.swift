import Foundation

public enum WorkspaceMatcher: Sendable {
    /// Jaccard similarity: |A ∩ B| / |A ∪ B|. Empty union yields 0.
    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 0 }
        let union = a.union(b)
        if union.isEmpty { return 0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }

    public static func match(
        workspaces: [Workspace],
        activations: [AppActivation],
        now: Date = Date(),
        windowMinutes: Double = 10,
        threshold: Double = 0.2
    ) -> WorkspaceMatch {
        let windowStart = now.addingTimeInterval(-windowMinutes * 60)
        let active = Set(
            activations
                .filter { $0.timestamp >= windowStart && !$0.bundleID.isEmpty }
                .map(\.bundleID)
        )

        guard !workspaces.isEmpty, !active.isEmpty else {
            return WorkspaceMatch(workspace: nil, similarity: 0, activeBundleIDs: active)
        }

        var scores: [UUID: Double] = [:]
        var best: Workspace?
        var bestScore = -1.0

        for workspace in workspaces {
            let score = jaccard(active, workspace.coreAppBundleIDs)
            scores[workspace.id] = score
            if score > bestScore {
                bestScore = score
                best = workspace
            }
        }

        if bestScore < threshold {
            return WorkspaceMatch(
                workspace: nil,
                similarity: max(bestScore, 0),
                activeBundleIDs: active,
                scoresByWorkspaceID: scores
            )
        }

        return WorkspaceMatch(
            workspace: best,
            similarity: bestScore,
            activeBundleIDs: active,
            scoresByWorkspaceID: scores
        )
    }
}
