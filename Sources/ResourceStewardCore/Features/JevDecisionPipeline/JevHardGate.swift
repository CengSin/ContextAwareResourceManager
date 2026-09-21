import Foundation



public enum JevHardGate: Sendable {
    public struct Candidate: Sendable, Equatable {
        public var pid: Int32
        public var bundleID: String
        public var processName: String
        public var path: String
        public var isForeground: Bool
        public var isAccessory: Bool
        public var isRegularApp: Bool
        public var ownsWindows: Bool
        public var inCurrentWorkspace: Bool
        public var isProtected: Bool
        public var favorites: Set<String>
        public var membersAreCompanionOnly: Bool
        public var windowOwnerPIDs: Set<Int32>?

        public init(
            pid: Int32 = 0,
            bundleID: String,
            processName: String,
            path: String = "",
            isForeground: Bool,
            isAccessory: Bool,
            isRegularApp: Bool,
            ownsWindows: Bool,
            inCurrentWorkspace: Bool,
            isProtected: Bool,
            favorites: Set<String> = [],
            membersAreCompanionOnly: Bool = false,
            windowOwnerPIDs: Set<Int32>? = nil
        ) {
            self.pid = pid
            self.bundleID = bundleID
            self.processName = processName
            self.path = path
            self.isForeground = isForeground
            self.isAccessory = isAccessory
            self.isRegularApp = isRegularApp
            self.ownsWindows = ownsWindows
            self.inCurrentWorkspace = inCurrentWorkspace
            self.isProtected = isProtected
            self.favorites = favorites
            self.membersAreCompanionOnly = membersAreCompanionOnly
            self.windowOwnerPIDs = windowOwnerPIDs
        }

        public init(group: ProcessGroupViewModel, favorites: Set<String>, windowOwnerPIDs: Set<Int32>? = nil) {
            let primary = group.primary.snapshot
            self.init(
                pid: primary.pid,
                bundleID: primary.bundleID ?? group.score.bundleID,
                processName: group.displayName,
                path: group.appPath ?? primary.path,
                isForeground: group.isForeground,
                isAccessory: group.isAccessory,
                isRegularApp: group.isRegularApp,
                ownsWindows: group.ownsWindows,
                inCurrentWorkspace: group.score.isInCurrentWorkspace,
                isProtected: group.isProtected,
                favorites: favorites,
                membersAreCompanionOnly: !group.members.isEmpty
                    && group.members.allSatisfy {
                        ProcessFamily.isCompanion(
                            bundleID: $0.snapshot.bundleID,
                            processName: $0.snapshot.processName
                        )
                    },
                windowOwnerPIDs: windowOwnerPIDs
            )
        }
    }

    
    public static func skipReason(for candidate: Candidate) -> (JevHardGateReason, String)? {
        if candidate.isForeground {
            return (.foreground, "foreground")
        }
        if candidate.membersAreCompanionOnly
            || ProcessFamily.isCompanion(bundleID: candidate.bundleID, processName: candidate.processName) {
            return (.companionAlone, "companion_alone")
        }
        if let category = CategoryBanPolicy.match(
            bundleID: candidate.bundleID,
            processName: candidate.processName,
            path: candidate.path
        ) {
            return (.categoryBan, category.chineseName)
        }
        if KeepAlivePolicy.shouldStayAlive(
            bundleID: candidate.bundleID,
            processName: candidate.processName,
            path: candidate.path,
            extras: candidate.favorites
        ) {
            return (.keepAliveOrFavorite, "keep_alive_or_favorite")
        }
        if candidate.isProtected {
            return (.protectedProcess, "protected")
        }
        if candidate.isAccessory {
            return (.accessoryNotAllowed, "accessory_only")
        }
        if !UserFacingAppPolicy.isSuggestable(
            bundleID: candidate.bundleID,
            processName: candidate.processName,
            path: candidate.path,
            isAccessory: candidate.isAccessory,
            isRegularApp: candidate.isRegularApp
        ) {
            return (.notUserFacing, "not_user_facing")
        }
        return nil
    }

    
    public static func isGrayZone(_ candidate: Candidate) -> Bool {
        skipReason(for: candidate) == nil
    }

    
    public static func isUnsafeToFreeze(_ candidate: Candidate) -> Bool {
        if candidate.ownsWindows { return true }
        guard let owners = candidate.windowOwnerPIDs, candidate.pid > 0 else { return false }
        return WindowedProcessPolicy.isUnsafeToFreeze(
            pid: candidate.pid,
            bundleID: candidate.bundleID.isEmpty ? nil : candidate.bundleID,
            ownerPIDs: owners
        )
    }

    public static func freezeCeilingReason(for candidate: Candidate) -> (JevHardGateReason, String)? {
        if candidate.ownsWindows {
            return (.ownsWindows, "owns_windows")
        }
        if let owners = candidate.windowOwnerPIDs,
           candidate.pid > 0,
           WindowedProcessPolicy.isUnsafeToFreeze(
               pid: candidate.pid,
               bundleID: candidate.bundleID.isEmpty ? nil : candidate.bundleID,
               ownerPIDs: owners
           ) {
            return (.ownsWindows, "windowed_process_policy")
        }
        return nil
    }

    
    public static func clampAction(_ action: SuggestedAction, for candidate: Candidate) -> SuggestedAction {
        _ = candidate
        return action.withoutFreeze()
    }
}
