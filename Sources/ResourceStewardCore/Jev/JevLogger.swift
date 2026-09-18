import Foundation
import os

/// Structured logging for Jev reclaim. Never log API keys or Authorization headers.
public enum JevLog {
    public static let subsystem = "cc.resourcesteward.jev"
    private static let logger = Logger(subsystem: subsystem, category: "reclaim")
    private static let queue = DispatchQueue(label: "cc.resourcesteward.jev.log")
    private static var ring: [String] = []
    private static let ringLimit = 400

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append(message)
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR " + message)
    }

    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        append(message)
    }

    public static func recentLines(limit: Int = 80) -> [String] {
        queue.sync {
            Array(ring.suffix(limit))
        }
    }

    private static func append(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)"
        queue.async {
            ring.append(line)
            if ring.count > ringLimit {
                ring.removeFirst(ring.count - ringLimit)
            }
            persistLine(line)
        }
    }

    private static func persistLine(_ line: String) {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ResourceSteward", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("jev-reclaim.log")
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
}
