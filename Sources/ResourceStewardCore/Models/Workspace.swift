import Foundation

public struct Workspace: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var coreAppBundleIDs: Set<String>
    public var observedAppFrequency: [String: Double]
    public var createdAt: Date
    public var lastActiveAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        coreAppBundleIDs: Set<String>,
        observedAppFrequency: [String: Double] = [:],
        createdAt: Date = Date(),
        lastActiveAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.coreAppBundleIDs = coreAppBundleIDs
        self.observedAppFrequency = observedAppFrequency
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}

public struct WorkspaceMatch: Sendable, Equatable {
    public let workspace: Workspace?
    public let similarity: Double
    public let activeBundleIDs: Set<String>
    public let scoresByWorkspaceID: [UUID: Double]

    public var isUnclassified: Bool { workspace == nil }

    public var workspaceID: UUID? { workspace?.id }

    public var displayName: String {
        workspace?.name ?? "未分类"
    }

    public init(
        workspace: Workspace?,
        similarity: Double,
        activeBundleIDs: Set<String>,
        scoresByWorkspaceID: [UUID: Double] = [:]
    ) {
        self.workspace = workspace
        self.similarity = similarity
        self.activeBundleIDs = activeBundleIDs
        self.scoresByWorkspaceID = scoresByWorkspaceID
    }
}

public struct AppActivation: Sendable, Equatable {
    public let timestamp: Date
    public let bundleID: String
    public let processName: String

    public init(timestamp: Date = Date(), bundleID: String, processName: String) {
        self.timestamp = timestamp
        self.bundleID = bundleID
        self.processName = processName
    }
}
