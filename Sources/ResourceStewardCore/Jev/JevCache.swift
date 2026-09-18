import Foundation

public struct JevCacheEntry: Codable, Sendable, Equatable {
    public var bundleID: String
    public var pressureBucket: String
    public var idleSeconds: Double
    public var memoryMB: Double
    public var classificationFetchedAt: Date
    public var actionFetchedAt: Date
    public var answers: StoredAnswers
    public var composedAction: String
    public var composedRule: String
    public var model: String
    public var requestID: String

    public struct StoredAnswers: Codable, Sendable, Equatable {
        public var looksLikeNetworkOrSync: Double
        public var looksLikeCommunication: Double
        public var looksLikeInputOrA11y: Double
        public var looksLikeAVOrCapture: Double
        public var userLikelyNeedsSoon: Double
        public var safeToReclaimIdle: Double
        public var preferredChoice: String
        public var preferredConfidence: Double
        public var preferredProbabilities: [String: Double]

        public init(from answers: JevEvaluationAnswers) {
            looksLikeNetworkOrSync = answers.looksLikeNetworkOrSync
            looksLikeCommunication = answers.looksLikeCommunication
            looksLikeInputOrA11y = answers.looksLikeInputOrA11y
            looksLikeAVOrCapture = answers.looksLikeAVOrCapture
            userLikelyNeedsSoon = answers.userLikelyNeedsSoon
            safeToReclaimIdle = answers.safeToReclaimIdle
            preferredChoice = answers.preferredAction.choice
            preferredConfidence = answers.preferredAction.confidence
            preferredProbabilities = answers.preferredAction.probabilities
        }

        public func toAnswers() -> JevEvaluationAnswers {
            JevEvaluationAnswers(
                looksLikeNetworkOrSync: looksLikeNetworkOrSync,
                looksLikeCommunication: looksLikeCommunication,
                looksLikeInputOrA11y: looksLikeInputOrA11y,
                looksLikeAVOrCapture: looksLikeAVOrCapture,
                userLikelyNeedsSoon: userLikelyNeedsSoon,
                safeToReclaimIdle: safeToReclaimIdle,
                preferredAction: JevChoiceAnswer(
                    choice: preferredChoice,
                    confidence: preferredConfidence,
                    probabilities: preferredProbabilities
                )
            )
        }
    }
}

public final class JevCache: @unchecked Sendable {
    public static let classificationTTL: TimeInterval = 4 * 3600
    public static let actionTTL: TimeInterval = 3 * 60
    public static let idleDeltaInvalidate: Double = 60
    public static let memoryRelInvalidate: Double = 0.2

    private let queue = DispatchQueue(label: "cc.resourcesteward.jev.cache")
    private var entries: [String: JevCacheEntry] = [:]
    private let fileURL: URL

    public init(filename: String = "jev-cache.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ResourceSteward", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(filename)
        queue.sync { loadLocked() }
    }

    /// In-memory only (unit tests).
    public init(memoryOnly: Bool) {
        self.fileURL = URL(fileURLWithPath: "/dev/null")
        if !memoryOnly {
            // keep API symmetry; unused
        }
    }

    public func lookup(
        bundleID: String,
        pressureBucket: String,
        idleSeconds: Double,
        memoryMB: Double,
        now: Date = Date()
    ) -> (entry: JevCacheEntry, actionFresh: Bool)? {
        queue.sync {
            guard let entry = entries[cacheKey(bundleID: bundleID, pressure: pressureBucket)] else {
                return nil
            }
            let classificationFresh = now.timeIntervalSince(entry.classificationFetchedAt) <= Self.classificationTTL
            guard classificationFresh else {
                entries.removeValue(forKey: cacheKey(bundleID: bundleID, pressure: pressureBucket))
                return nil
            }
            let idleDelta = abs(entry.idleSeconds - idleSeconds)
            let memBase = max(entry.memoryMB, 1)
            let memRel = abs(entry.memoryMB - memoryMB) / memBase
            let contextOK = idleDelta <= Self.idleDeltaInvalidate && memRel <= Self.memoryRelInvalidate
            let actionFresh = contextOK
                && entry.pressureBucket == pressureBucket
                && now.timeIntervalSince(entry.actionFetchedAt) <= Self.actionTTL
            return (entry, actionFresh)
        }
    }

    public func store(
        bundleID: String,
        pressureBucket: String,
        idleSeconds: Double,
        memoryMB: Double,
        answers: JevEvaluationAnswers,
        composed: JevComposeResult,
        model: String,
        requestID: String,
        now: Date = Date()
    ) {
        let entry = JevCacheEntry(
            bundleID: bundleID,
            pressureBucket: pressureBucket,
            idleSeconds: idleSeconds,
            memoryMB: memoryMB,
            classificationFetchedAt: now,
            actionFetchedAt: now,
            answers: .init(from: answers),
            composedAction: composed.action.rawValue,
            composedRule: composed.rule.rawValue,
            model: model,
            requestID: requestID
        )
        queue.sync {
            entries[cacheKey(bundleID: bundleID, pressure: pressureBucket)] = entry
            persistLocked()
        }
    }

    public func clear() {
        queue.sync {
            entries.removeAll()
            persistLocked()
        }
    }

    private func cacheKey(bundleID: String, pressure: String) -> String {
        "\(bundleID.lowercased())|\(pressure)"
    }

    private func loadLocked() {
        guard fileURL.path != "/dev/null",
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: JevCacheEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func persistLocked() {
        guard fileURL.path != "/dev/null" else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
