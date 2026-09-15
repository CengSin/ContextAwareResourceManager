import Foundation

public enum SceneSwitchOutcome: String, Sendable, Equatable {
    case sessionStart
    case unchanged
    case debouncing
    case committedUnclassified
    case committedRecordOnly
    case committedWithAuto
}

public struct SceneSwitchState: Sendable, Equatable {
    public var sessionReady: Bool
    public var committedWorkspaceID: UUID?
    public var isDebouncing: Bool
    public var candidateWorkspaceID: UUID?
    public var candidateSince: Date?

    public init(
        sessionReady: Bool = false,
        committedWorkspaceID: UUID? = nil,
        isDebouncing: Bool = false,
        candidateWorkspaceID: UUID? = nil,
        candidateSince: Date? = nil
    ) {
        self.sessionReady = sessionReady
        self.committedWorkspaceID = committedWorkspaceID
        self.isDebouncing = isDebouncing
        self.candidateWorkspaceID = candidateWorkspaceID
        self.candidateSince = candidateSince
    }
}

public struct SceneSwitchTarget: Sendable, Equatable {
    public let groupKey: String
    public let bundleID: String
    public let processName: String
    public let suggestedAction: SuggestedAction
    public let isForeground: Bool
    public let isProtected: Bool
    public let isInCurrentWorkspace: Bool
    public let alreadyFrozen: Bool
    public let alreadyThrottled: Bool
    public let isAccessory: Bool

    public init(
        groupKey: String,
        bundleID: String,
        processName: String,
        suggestedAction: SuggestedAction,
        isForeground: Bool,
        isProtected: Bool,
        isInCurrentWorkspace: Bool,
        alreadyFrozen: Bool,
        alreadyThrottled: Bool,
        isAccessory: Bool = false
    ) {
        self.groupKey = groupKey
        self.bundleID = bundleID
        self.processName = processName
        self.suggestedAction = suggestedAction
        self.isForeground = isForeground
        self.isProtected = isProtected
        self.isInCurrentWorkspace = isInCurrentWorkspace
        self.alreadyFrozen = alreadyFrozen
        self.alreadyThrottled = alreadyThrottled
        self.isAccessory = isAccessory
    }

    public init(group: ProcessGroupViewModel) {
        self.init(
            groupKey: group.key,
            bundleID: group.primary.snapshot.bundleID ?? group.score.bundleID,
            processName: group.displayName,
            suggestedAction: group.score.suggestedAction,
            isForeground: group.isForeground,
            isProtected: group.isProtected,
            isInCurrentWorkspace: group.score.isInCurrentWorkspace,
            alreadyFrozen: group.appliedAction == .freeze,
            alreadyThrottled: group.appliedAction == .throttle,
            isAccessory: group.isAccessory
        )
    }
}

public struct PlannedSceneAction: Sendable, Equatable {
    public let groupKey: String
    public let bundleID: String
    public let processName: String
    public let action: SuggestedAction
    public let originalSuggestion: SuggestedAction

    public init(
        groupKey: String,
        bundleID: String,
        processName: String,
        action: SuggestedAction,
        originalSuggestion: SuggestedAction
    ) {
        self.groupKey = groupKey
        self.bundleID = bundleID
        self.processName = processName
        self.action = action
        self.originalSuggestion = originalSuggestion
    }
}

public struct SceneSwitchPlan: Sendable, Equatable {
    public let outcome: SceneSwitchOutcome
    public let fromWorkspaceID: UUID?
    public let toWorkspaceID: UUID?
    public let shouldRecordTransition: Bool
    public let thaw: [FrozenProcess]
    public let actions: [PlannedSceneAction]
    public let summary: String

    public var didAutoProcess: Bool {
        outcome == .committedWithAuto && (!actions.isEmpty || !thaw.isEmpty)
    }

    public init(
        outcome: SceneSwitchOutcome,
        fromWorkspaceID: UUID? = nil,
        toWorkspaceID: UUID? = nil,
        shouldRecordTransition: Bool = false,
        thaw: [FrozenProcess] = [],
        actions: [PlannedSceneAction] = [],
        summary: String = ""
    ) {
        self.outcome = outcome
        self.fromWorkspaceID = fromWorkspaceID
        self.toWorkspaceID = toWorkspaceID
        self.shouldRecordTransition = shouldRecordTransition
        self.thaw = thaw
        self.actions = actions
        self.summary = summary
    }
}

public enum SceneSwitchPolicy: Sendable {
    public static let defaultDebounceSeconds: TimeInterval = 15

    /// Level 1 never auto-quits: freeze instead so unsaved windows are not dismissed.
    public static func autoAction(for suggested: SuggestedAction) -> SuggestedAction? {
        switch suggested {
        case .none: return nil
        case .throttle: return .throttle
        case .freeze, .quit: return .freeze
        }
    }

    public static func evaluate(
        state: SceneSwitchState,
        authorization: AuthorizationLevel,
        current: WorkspaceMatch,
        targets: [SceneSwitchTarget],
        frozen: [FrozenProcess],
        now: Date,
        debounceSeconds: TimeInterval = defaultDebounceSeconds
    ) -> (state: SceneSwitchState, plan: SceneSwitchPlan) {
        let currentID = current.workspace?.id
        var next = state

        if !state.sessionReady {
            next.sessionReady = true
            next.committedWorkspaceID = currentID
            next.isDebouncing = false
            next.candidateWorkspaceID = nil
            next.candidateSince = nil
            return (
                next,
                SceneSwitchPlan(outcome: .sessionStart, fromWorkspaceID: nil, toWorkspaceID: currentID)
            )
        }

        if currentID == state.committedWorkspaceID {
            next.isDebouncing = false
            next.candidateWorkspaceID = nil
            next.candidateSince = nil
            return (
                next,
                SceneSwitchPlan(
                    outcome: .unchanged,
                    fromWorkspaceID: currentID,
                    toWorkspaceID: currentID
                )
            )
        }

        if debounceSeconds > 0 {
            let sameCandidate = state.isDebouncing && state.candidateWorkspaceID == currentID
            if !sameCandidate {
                next.isDebouncing = true
                next.candidateWorkspaceID = currentID
                next.candidateSince = now
                return (
                    next,
                    SceneSwitchPlan(
                        outcome: .debouncing,
                        fromWorkspaceID: state.committedWorkspaceID,
                        toWorkspaceID: currentID
                    )
                )
            }
            let since = state.candidateSince ?? now
            if now.timeIntervalSince(since) < debounceSeconds {
                return (
                    next,
                    SceneSwitchPlan(
                        outcome: .debouncing,
                        fromWorkspaceID: state.committedWorkspaceID,
                        toWorkspaceID: currentID
                    )
                )
            }
        }

        let fromID = state.committedWorkspaceID
        next.committedWorkspaceID = currentID
        next.isDebouncing = false
        next.candidateWorkspaceID = nil
        next.candidateSince = nil

        let shouldRecord = WorkspaceMarkov.shouldRecord(from: fromID, to: currentID)

        if current.isUnclassified {
            return (
                next,
                SceneSwitchPlan(
                    outcome: .committedUnclassified,
                    fromWorkspaceID: fromID,
                    toWorkspaceID: currentID,
                    shouldRecordTransition: shouldRecord
                )
            )
        }

        guard authorization == .sceneSwitch else {
            return (
                next,
                SceneSwitchPlan(
                    outcome: .committedRecordOnly,
                    fromWorkspaceID: fromID,
                    toWorkspaceID: currentID,
                    shouldRecordTransition: shouldRecord
                )
            )
        }

        let core = current.workspace?.coreAppBundleIDs ?? []
        let thaw = frozen.filter { item in
            !item.bundleID.isEmpty && core.contains(item.bundleID)
        }
        let actions = targets.compactMap { target -> PlannedSceneAction? in
            guard !target.isForeground,
                  !target.isProtected,
                  !target.isAccessory,
                  !target.isInCurrentWorkspace,
                  let action = autoAction(for: target.suggestedAction)
            else { return nil }
            if action == .freeze && target.alreadyFrozen { return nil }
            if action == .throttle && target.alreadyThrottled { return nil }
            return PlannedSceneAction(
                groupKey: target.groupKey,
                bundleID: target.bundleID,
                processName: target.processName,
                action: action,
                originalSuggestion: target.suggestedAction
            )
        }

        let freezeCount = actions.filter { $0.action == .freeze }.count
        let throttleCount = actions.filter { $0.action == .throttle }.count
        return (
            next,
            SceneSwitchPlan(
                outcome: .committedWithAuto,
                fromWorkspaceID: fromID,
                toWorkspaceID: currentID,
                shouldRecordTransition: shouldRecord,
                thaw: thaw,
                actions: actions,
                summary: summary(
                    workspaceName: current.displayName,
                    freezeCount: freezeCount,
                    throttleCount: throttleCount,
                    thawCount: thaw.count
                )
            )
        )
    }

    public static func summary(
        workspaceName: String,
        freezeCount: Int,
        throttleCount: Int,
        thawCount: Int
    ) -> String {
        var parts: [String] = []
        if freezeCount > 0 { parts.append("冻结 \(freezeCount) 个离场景应用") }
        if throttleCount > 0 { parts.append("降低 \(throttleCount) 个优先级") }
        if thawCount > 0 { parts.append("恢复 \(thawCount) 个场景内应用") }
        if parts.isEmpty { return "" }
        return "已按「\(workspaceName)」场景自动" + parts.joined(separator: "，") + "。"
    }
}
