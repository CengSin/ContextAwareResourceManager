import Foundation
import ResourceStewardCore
import SQLite3

enum JevCredentialChecks {
    static func run() throws -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "ok  " : "FAIL") \(name)")
            if !condition { failures.append(name) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("credentials.sqlite").path
        let store = try LocalStore(path: path)
        check("SQLite credentials initially absent", try store.loadJevAPIKey() == nil)
        let key = "test-'quoted'; SELECT 1; 密钥"
        try store.saveJevAPIKey(" \n\(key)\t")
        check("SQLite key round trip preserves bound text", try store.loadJevAPIKey() == key)
        let reopened = try LocalStore(path: path)
        check("SQLite key survives reopening", try reopened.loadJevAPIKey() == key)
        try store.saveSettings(.default)
        check("saving settings preserves key", try store.loadJevAPIKey() == key)
        try store.saveJevAPIKey("replacement")
        check("SQLite key replacement persists", try reopened.loadJevAPIKey() == "replacement")
        let advisor = JevReclaimAdvisor(enabled: true, apiKeyProvider: { nil })
        advisor.updateAPIKey(try store.loadJevAPIKey())
        check("saved key activates advisor", advisor.isActive)
        try store.saveJevAPIKey(" \n\t")
        advisor.updateAPIKey(nil)
        check("SQLite key clearing persists", try reopened.loadJevAPIKey() == nil)
        check("clearing key disables advisor", !advisor.isActive)
        advisor.updateAPIKey("   ")
        check("blank key cannot activate advisor", !advisor.isActive)
        try store.saveJevAPIKey("retained")
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw StoreError.openFailed("test database") }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TRIGGER reject_key_delete BEFORE DELETE ON settings BEGIN SELECT RAISE(ABORT, 'test rejection'); END", nil, nil, nil)
        do {
            try store.saveJevAPIKey("")
            check("SQLite clear failure is reported", false)
        } catch {
            check("SQLite clear failure is reported", true)
        }
        check("failed clear preserves persisted key", try reopened.loadJevAPIKey() == "retained")
        sqlite3_exec(db, "CREATE TRIGGER reject_key_update BEFORE UPDATE ON settings BEGIN SELECT RAISE(ABORT, 'test rejection'); END", nil, nil, nil)
        do {
            try store.saveJevAPIKey("rejected")
            check("SQLite replacement failure is reported", false)
        } catch {
            check("SQLite replacement failure is reported", true)
        }
        check("failed replacement preserves persisted key", try reopened.loadJevAPIKey() == "retained")
        sqlite3_exec(db, "DROP TABLE settings", nil, nil, nil)
        do {
            _ = try store.loadJevAPIKey()
            check("SQLite read failure is reported", false)
        } catch {
            check("SQLite read failure is reported", true)
        }
        return failures
    }
}
