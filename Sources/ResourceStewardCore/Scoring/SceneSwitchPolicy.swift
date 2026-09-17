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
    public let isRegularApp: Bool
    public let ownsWindows: Bool
    public let idleSeconds: TimeInterval
    public let path: String

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
        isAccessory: Bool = false,
        isRegularApp: Bool = true,
        ownsWindows: Bool = false,
        idleSeconds: TimeInterval = 0,
        path: String = ""
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
        self.isRegularApp = isRegularApp
        self.ownsWindows = ownsWindows
        self.idleSeconds = idleSeconds
        self.path = path
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
            isAccessory: group.isAccessory,
            isRegularApp: group.isRegularApp,
            ownsWindows: group.ownsWindows,
            idleSeconds: group.idleSeconds,
            path: group.appPath ?? group.primary.snapshot.path
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
    /// Don't freeze an app the user just left. Two minutes is long enough to
    /// survive Cmd-Tab glances, short enough to feel like the steward is working.
    public static let defaultMinIdleSeconds: TimeInterval = 120
    public static let defaultDwellCooldownSeconds: TimeInterval = 90
    public static let defaultMaxActionsPerTick: Int = 6

    /// Level 1 never auto-quits: freeze instead so unsaved windows are not dismissed.
    /// Throttle (nice) is skipped: it is almost invisible on idle apps and was
    /// previously applied to system daemons, which made the product look idle.
    public static func autoAction(for suggested: SuggestedAction) -> SuggestedAction? {
        switch suggested {
        case .none, .throttle: return nil
        case .freeze, .quit: return .freeze
        }
    }

    public static func isAutoCandidate(
        _ target: SceneSwitchTarget,
        minIdleSeconds: TimeInterval = defaultMinIdleSeconds
    ) -> Bool {
        guard !target.isForeground,
              !target.isProtected,
              !target.isAccessory,
              !target.ownsWindows,
              !target.isInCurrentWorkspace,
              target.idleSeconds >= minIdleSeconds,
              !CategoryBanPolicy.bansAutoAction(
                  bundleID: target.bundleID,
                  processName: target.processName,
                  path: target.path
              ),
              UserFacingAppPolicy.isAutoEligible(
                  bundleID: target.bundleID,
                  processName: target.processName,
                  path: target.path,
                  isAccessory: target.isAccessory,
                  isRegularApp: target.isRegularApp
              ),
              let action = autoAction(for: target.suggestedAction)
        else { return false }
        if action == .freeze && target.alreadyFrozen { return false }
        if action == .throttle && target.alreadyThrottled { return false }
        return true
    }

    public static func evaluate(
        state: SceneSwitchState,
        authorization: AuthorizationLevel,
        current: WorkspaceMatch,
        targets: [SceneSwitchTarget],
        frozen: [FrozenProcess],
        now: Date,
        debounceSeconds: TimeInterval = defaultDebounceSeconds,
        minIdleSeconds: TimeInterval = defaultMinIdleSeconds
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
            if item.bundleID.isEmpty { return false }
            if core.contains(item.bundleID) { return true }
            if let root = ProcessFamily.rootBundleID(from: item.bundleID), core.contains(root) {
                return true
            }
            return false
        }
        let actions = plannedActions(from: targets, minIdleSeconds: minIdleSeconds)

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

    /// Level 1 only auto-handles real apps (reverse-DNS bundle IDs).
    /// `python`, `fontd`, `suggestd` and other nameless daemons are not workspace apps.
    public static func isAppBundle(_ bundleID: String) -> Bool {
        bundleID.contains(".")
    }

    /// While the user stays in a classified scene, keep freezing idle off-scene apps.
    /// Scene-switch-only auto-handling never fires during a long coding session.
    public static func dwellActions(
        state: SceneSwitchState,
        authorization: AuthorizationLevel,
        current: WorkspaceMatch,
        targets: [SceneSwitchTarget],
        lastActionAt: [String: Date],
        now: Date,
        minIdleSeconds: TimeInterval = defaultMinIdleSeconds,
        cooldownSeconds: TimeInterval = defaultDwellCooldownSeconds,
        maxActions: Int = defaultMaxActionsPerTick
    ) -> [PlannedSceneAction] {
        guard authorization == .sceneSwitch else { return [] }
        guard state.sessionReady, !state.isDebouncing else { return [] }
        guard let currentID = current.workspace?.id, currentID == state.committedWorkspaceID else {
            return []
        }
        let planned = plannedActions(from: targets, minIdleSeconds: minIdleSeconds).filter { item in
            if let last = lastActionAt[item.groupKey], now.timeIntervalSince(last) < cooldownSeconds {
                return false
            }
            return true
        }
        if planned.count <= maxActions { return planned }
        return Array(planned.prefix(maxActions))
    }

    public static func plannedActions(
        from targets: [SceneSwitchTarget],
        minIdleSeconds: TimeInterval = defaultMinIdleSeconds
    ) -> [PlannedSceneAction] {
        targets.compactMap { target -> PlannedSceneAction? in
            guard isAutoCandidate(target, minIdleSeconds: minIdleSeconds),
                  let action = autoAction(for: target.suggestedAction)
            else { return nil }
            return PlannedSceneAction(
                groupKey: target.groupKey,
                bundleID: target.bundleID,
                processName: target.processName,
                action: action,
                originalSuggestion: target.suggestedAction
            )
        }
    }

    public static func statusText(
        authorization: AuthorizationLevel,
        match: WorkspaceMatch,
        isDebouncing: Bool,
        frozenCount: Int,
        pendingFreezeCount: Int
    ) -> String {
        if authorization != .sceneSwitch {
            return "仅建议，点「应用建议」才会处理"
        }
        if match.isUnclassified {
            return "未分类，半自动暂停"
        }
        if isDebouncing {
            return "场景切换确认中…"
        }
        if frozenCount > 0 {
            return "「\(match.displayName)」· 已冻结 \(frozenCount) 个"
        }
        if pendingFreezeCount > 0 {
            return "「\(match.displayName)」· \(pendingFreezeCount) 个离场景应用空闲后将冻结"
        }
        return "「\(match.displayName)」停留中 · 暂无达到冻结条件的离场景应用"
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
