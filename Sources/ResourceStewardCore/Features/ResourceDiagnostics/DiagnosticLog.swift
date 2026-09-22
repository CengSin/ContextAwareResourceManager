import Foundation
import os

public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ResourceSteward/Diagnostics"))
    private let queue = DispatchQueue(label: "cc.resourcesteward.diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "cc.resourcesteward.diagnostics", category: "storage")
    private let directory: URL
    private let maxBytes: Int
    private let archives: Int
    private let retention: TimeInterval
    private let session = UUID().uuidString
    private var enabled = true
    private var lastCleanup = Date.distantPast
    private var lastError = Date.distantPast

    public init(directory: URL, maxBytes: Int = 8 * 1024 * 1024, archives: Int = 7, retention: TimeInterval = 7 * 86400) {
        self.directory = directory
        self.maxBytes = max(256, maxBytes)
        self.archives = max(1, archives)
        self.retention = retention
    }

    public func configure(enabled: Bool) { queue.sync { self.enabled = enabled } }
    public func flush() { queue.sync {} }

    public func record(_ event: String, _ fields: [String: Any] = [:], at date: Date = Date()) {
        guard queue.sync(execute: { enabled }) else { return }
        var payload = fields
        payload["schema"] = 1
        payload["session_id"] = session
        payload["timestamp"] = date.timeIntervalSince1970
        payload["event"] = event
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              data.count + 1 <= maxBytes else {
            queue.async { self.reportFailure(code: "invalid_or_oversized_record") }
            return
        }
        queue.async {
            guard self.enabled else { return }
            do { try self.append(data + Data([10]), at: date) }
            catch { self.reportFailure(code: "write_failed_\((error as NSError).code)") }
        }
    }

    private func reportFailure(code: String) {
        guard Date().timeIntervalSince(lastError) >= 60 else { return }
        lastError = Date()
        logger.error("diagnostics_error code=\(code, privacy: .public)")
    }

    private func file(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "events.jsonl" : "events.\(index).jsonl")
    }

    private func append(_ data: Data, at now: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if now.timeIntervalSince(lastCleanup) >= 3600 || now < lastCleanup {
            for index in 0...archives {
                let url = file(index)
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let modified = attrs[.modificationDate] as? Date,
                   now.timeIntervalSince(modified) > retention {
                    try fm.removeItem(at: url)
                }
            }
            lastCleanup = now
        }
        let url = file(0)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > maxBytes {
            if fm.fileExists(atPath: file(archives).path) { try fm.removeItem(at: file(archives)) }
            for index in stride(from: archives - 1, through: 0, by: -1) where fm.fileExists(atPath: file(index).path) {
                try fm.moveItem(at: file(index), to: file(index + 1))
            }
        }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
