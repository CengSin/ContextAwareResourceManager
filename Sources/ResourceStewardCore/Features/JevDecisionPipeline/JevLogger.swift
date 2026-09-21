import Foundation
import os





public enum JevLog {
    public static let subsystem = "cc.resourcesteward.jev"
    private static let logger = Logger(subsystem: subsystem, category: "reclaim")
    private static let queue = DispatchQueue(label: "cc.resourcesteward.jev.log")
    private static let ringBox = RingBox()
    private static let ringLimit = 400
    
    private static let maxFileBytes: UInt64 = 512_000

    private final class RingBox: @unchecked Sendable {
        var fileLoggingEnabled = true
        var lines: [String] = []
        var onceKeys: Set<String> = []
        var lastThrottled: [String: Date] = [:]
    }

    public static func configureFileLogging(enabled: Bool) {
        queue.sync { ringBox.fileLoggingEnabled = enabled }
    }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append(message, toFile: true)
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR " + message, toFile: true)
    }

    
    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        append(message, toFile: false)
    }

    
    public static func infoOnce(key: String, _ message: String) {
        let should = queue.sync { () -> Bool in
            if ringBox.onceKeys.contains(key) { return false }
            ringBox.onceKeys.insert(key)
            return true
        }
        if should {
            info(message)
        } else {
            debug(message)
        }
    }

    
    public static func infoThrottled(key: String, interval: TimeInterval = 600, _ message: String) {
        let now = Date()
        let should = queue.sync { () -> Bool in
            if let last = ringBox.lastThrottled[key], now.timeIntervalSince(last) < interval {
                return false
            }
            ringBox.lastThrottled[key] = now
            return true
        }
        if should {
            info(message)
        } else {
            debug(message)
        }
    }

    public static func recentLines(limit: Int = 80) -> [String] {
        queue.sync {
            Array(ringBox.lines.suffix(limit))
        }
    }

    private static func append(_ message: String, toFile: Bool) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)"
        queue.async {
            ringBox.lines.append(line)
            if ringBox.lines.count > ringLimit {
                ringBox.lines.removeFirst(ringBox.lines.count - ringLimit)
            }
            guard toFile, ringBox.fileLoggingEnabled else { return }
            persistLine(line)
        }
    }

    private static func persistLine(_ line: String) {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ResourceSteward", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("jev-reclaim.log")
        rotateIfNeeded(url)
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileBytes else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("jev-reclaim.log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
