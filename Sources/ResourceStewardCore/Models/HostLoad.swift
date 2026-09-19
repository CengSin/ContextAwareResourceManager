import Foundation

public struct HostCPU: Sendable, Equatable {
    public let usagePercent: Double
    public let userPercent: Double
    public let systemPercent: Double

    public init(usagePercent: Double, userPercent: Double = 0, systemPercent: Double = 0) {
        self.usagePercent = min(100, max(0, usagePercent))
        self.userPercent = min(100, max(0, userPercent))
        self.systemPercent = min(100, max(0, systemPercent))
    }

    public static let empty = HostCPU(usagePercent: 0)

    public static func fromTicks(
        previousUser: UInt64, previousSystem: UInt64, previousIdle: UInt64, previousNice: UInt64,
        currentUser: UInt64, currentSystem: UInt64, currentIdle: UInt64, currentNice: UInt64
    ) -> HostCPU {
        let dUser = currentUser &- previousUser
        let dSystem = currentSystem &- previousSystem
        let dIdle = currentIdle &- previousIdle
        let dNice = currentNice &- previousNice
        let total = dUser + dSystem + dIdle + dNice
        guard total > 0 else { return .empty }
        let busy = dUser + dSystem + dNice
        return HostCPU(
            usagePercent: Double(busy) / Double(total) * 100,
            userPercent: Double(dUser + dNice) / Double(total) * 100,
            systemPercent: Double(dSystem) / Double(total) * 100
        )
    }
}

public struct HostGPU: Sendable, Equatable {
    public let usagePercent: Double
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let name: String
    public let available: Bool

    public init(
        usagePercent: Double,
        memoryUsedBytes: UInt64 = 0,
        memoryTotalBytes: UInt64 = 0,
        name: String = "",
        available: Bool
    ) {
        self.usagePercent = min(100, max(0, usagePercent))
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.name = name
        self.available = available
    }

    public static let unavailable = HostGPU(usagePercent: 0, available: false)

    public var displayName: String {
        if name.lowercased().contains("intel") { return "Intel GPU" }
        if name.lowercased().contains("agx") || name.lowercased().contains("apple") { return "Apple GPU" }
        if name.lowercased().contains("amd") || name.lowercased().contains("radeon") { return "AMD GPU" }
        if !name.isEmpty { return name }
        return "GPU"
    }

    public var isSharedMemory: Bool {
        let lower = name.lowercased()
        return lower.contains("intel") || lower.contains("agx") || lower.contains("apple")
    }

    public var memoryKindName: String {
        let lower = name.lowercased()
        if lower.contains("intel") { return "共享显存" }
        if lower.contains("agx") || lower.contains("apple") { return "统一内存" }
        return "显存"
    }
}
