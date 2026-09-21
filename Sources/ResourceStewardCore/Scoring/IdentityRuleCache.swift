import Foundation

final class IdentityRuleCache<Value: Sendable>: @unchecked Sendable {
    private struct Identity: Hashable {
        let bundleID: String?
        let processName: String
        let path: String
    }

    private struct Entry {
        let value: Value
    }

    private let lock = NSLock()
    private var entries: [Identity: Entry] = [:]
    private let capacity = 2_048

    func value(bundleID: String?, processName: String, path: String, compute: () -> Value) -> Value {
        let identity = Identity(bundleID: bundleID, processName: processName, path: path)
        lock.lock()
        if let entry = entries[identity] {
            lock.unlock()
            return entry.value
        }
        lock.unlock()
        let result = compute()
        lock.lock()
        if entries.count >= capacity {
            entries.removeAll(keepingCapacity: true)
        }
        entries[identity] = Entry(value: result)
        lock.unlock()
        return result
    }
}
