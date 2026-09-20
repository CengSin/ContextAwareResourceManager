import Foundation



public struct ActionAttemptCooldown {
    private var attemptedAt: [String: Date] = [:]
    public let interval: TimeInterval

    public init(interval: TimeInterval = 90) {
        self.interval = interval
    }

    public func allows(_ key: String, at now: Date) -> Bool {
        guard let last = attemptedAt[key] else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    public mutating func record(_ key: String, at now: Date) {
        attemptedAt[key] = now
    }
}
