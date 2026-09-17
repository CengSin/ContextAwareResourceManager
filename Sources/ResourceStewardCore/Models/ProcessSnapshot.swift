import Foundation

public struct ProcessSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(pid)-\(timestamp.timeIntervalSince1970)" }

    public let timestamp: Date
    public let pid: Int32
    public let uid: UInt32
    public let bundleID: String?
    public let processName: String
    public let path: String
    public let memoryFootprintMB: Double
    public let cpuPercent: Double
    public let isForeground: Bool
    public let isAccessory: Bool
    public let isRegularApp: Bool
    public let ownsWindows: Bool
    public let idleSeconds: TimeInterval
    public let startUnix: TimeInterval

    public init(
        timestamp: Date = Date(),
        pid: Int32,
        uid: UInt32,
        bundleID: String?,
        processName: String,
        path: String = "",
        memoryFootprintMB: Double,
        cpuPercent: Double,
        isForeground: Bool,
        isAccessory: Bool = false,
        isRegularApp: Bool = true,
        ownsWindows: Bool = false,
        idleSeconds: TimeInterval,
        startUnix: TimeInterval = 0
    ) {
        self.timestamp = timestamp
        self.pid = pid
        self.uid = uid
        self.bundleID = bundleID
        self.processName = processName
        self.path = path
        self.memoryFootprintMB = memoryFootprintMB
        self.cpuPercent = cpuPercent
        self.isForeground = isForeground
        self.isAccessory = isAccessory
        self.isRegularApp = isRegularApp
        self.ownsWindows = ownsWindows
        self.idleSeconds = idleSeconds
        self.startUnix = startUnix
    }

    public var idleMinutes: Double { idleSeconds / 60.0 }

    public var displayName: String {
        if let bundleID, !bundleID.isEmpty {
            return processName
        }
        return processName
    }
}

public struct RawProcessSample: Sendable, Equatable {
    public let pid: Int32
    public let uid: UInt32
    public let physFootprintBytes: UInt64
    public let residentBytes: UInt64
    public let cpuTimeNs: UInt64
    public let startUnix: UInt64
    public let name: String
    public let path: String

    public var memoryFootprintMB: Double {
        Double(physFootprintBytes) / (1024.0 * 1024.0)
    }
}
