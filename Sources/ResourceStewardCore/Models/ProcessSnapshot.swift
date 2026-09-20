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
    public let gpuPercent: Double
    public let isForeground: Bool
    public let isAccessory: Bool
    public let isRegularApp: Bool
    public let ownsWindows: Bool
    public let idleSeconds: TimeInterval
    public let startUnix: TimeInterval
    public let parentPID: Int32

    public init(
        timestamp: Date = Date(),
        pid: Int32,
        uid: UInt32 = 0,
        bundleID: String?,
        processName: String,
        path: String = "",
        memoryFootprintMB: Double,
        cpuPercent: Double,
        gpuPercent: Double = 0,
        isForeground: Bool,
        isAccessory: Bool = false,
        isRegularApp: Bool = true,
        ownsWindows: Bool = false,
        idleSeconds: TimeInterval,
        startUnix: TimeInterval = 0,
        parentPID: Int32 = 0
    ) {
        self.timestamp = timestamp
        self.pid = pid
        self.uid = uid
        self.bundleID = bundleID
        self.processName = processName
        self.path = path
        self.memoryFootprintMB = memoryFootprintMB
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.isForeground = isForeground
        self.isAccessory = isAccessory
        self.isRegularApp = isRegularApp
        self.ownsWindows = ownsWindows
        self.idleSeconds = idleSeconds
        self.startUnix = startUnix
        self.parentPID = parentPID
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, pid, uid, bundleID, processName, path
        case memoryFootprintMB, cpuPercent, gpuPercent
        case isForeground, isAccessory, isRegularApp, ownsWindows
        case idleSeconds, startUnix, parentPID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        pid = try container.decode(Int32.self, forKey: .pid)
        uid = try container.decodeIfPresent(UInt32.self, forKey: .uid) ?? 0
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        processName = try container.decode(String.self, forKey: .processName)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        memoryFootprintMB = try container.decodeIfPresent(Double.self, forKey: .memoryFootprintMB) ?? 0
        cpuPercent = try container.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? 0
        gpuPercent = try container.decodeIfPresent(Double.self, forKey: .gpuPercent) ?? 0
        isForeground = try container.decodeIfPresent(Bool.self, forKey: .isForeground) ?? false
        isAccessory = try container.decodeIfPresent(Bool.self, forKey: .isAccessory) ?? false
        isRegularApp = try container.decodeIfPresent(Bool.self, forKey: .isRegularApp) ?? true
        ownsWindows = try container.decodeIfPresent(Bool.self, forKey: .ownsWindows) ?? false
        idleSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .idleSeconds) ?? 0
        startUnix = try container.decodeIfPresent(TimeInterval.self, forKey: .startUnix) ?? 0
        parentPID = try container.decodeIfPresent(Int32.self, forKey: .parentPID) ?? 0
    }

    public var generation: ProcessGeneration {
        ProcessGeneration(pid: pid, startUnix: startUnix)
    }

    public var idleMinutes: Double { idleSeconds / 60.0 }

    public var displayName: String {
        if let bundleID, !bundleID.isEmpty {
            return processName
        }
        return processName
    }

    public static func == (lhs: ProcessSnapshot, rhs: ProcessSnapshot) -> Bool {
        lhs.pid == rhs.pid
            && lhs.uid == rhs.uid
            && lhs.bundleID == rhs.bundleID
            && lhs.processName == rhs.processName
            && lhs.path == rhs.path
            && abs(lhs.memoryFootprintMB - rhs.memoryFootprintMB) < 0.5
            && abs(lhs.cpuPercent - rhs.cpuPercent) < 0.5
            && abs(lhs.gpuPercent - rhs.gpuPercent) < 0.5
            && lhs.isForeground == rhs.isForeground
            && lhs.isAccessory == rhs.isAccessory
            && lhs.isRegularApp == rhs.isRegularApp
            && lhs.ownsWindows == rhs.ownsWindows
            && abs(lhs.idleSeconds - rhs.idleSeconds) < 15
            && lhs.startUnix == rhs.startUnix
            && lhs.parentPID == rhs.parentPID
    }
}

public struct RawProcessSample: Sendable, Equatable {
    public let pid: Int32
    public let parentPID: Int32
    public let uid: UInt32
    public let physFootprintBytes: UInt64
    public let residentBytes: UInt64
    public let cpuTimeNs: UInt64
    public let startUnix: UInt64
    public let startUsec: UInt32
    public let name: String
    public let path: String

    public var memoryFootprintMB: Double {
        Double(physFootprintBytes) / (1024.0 * 1024.0)
    }

    public var startTimeInterval: TimeInterval {
        TimeInterval(startUnix) + TimeInterval(startUsec) / 1_000_000
    }
}


public struct ProcessGeneration: Sendable, Equatable, Hashable {
    public let pid: Int32
    public let startUnix: TimeInterval

    public init(pid: Int32, startUnix: TimeInterval = 0) {
        self.pid = pid
        self.startUnix = startUnix
    }

    public var key: String {
        if startUnix > 0 {
            return "pid:\(pid):\(startUnix)"
        }
        return "pid:\(pid)"
    }

    public var isKnown: Bool { startUnix > 0 }

    public func sameGeneration(_ other: ProcessGeneration) -> Bool {
        guard pid == other.pid else { return false }
        if !isKnown || !other.isKnown {
            return !isKnown && !other.isKnown
        }
        return abs(startUnix - other.startUnix) < 0.002
    }
}
