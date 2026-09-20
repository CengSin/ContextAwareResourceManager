import Foundation
import SQLite3

public final class LocalStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "cc.resourcesteward.store")
    private let path: String

    public init(filename: String = "resource-steward.sqlite") throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ResourceSteward", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent(filename).path
        try queue.sync {
            try self.openLocked()
            try self.migrateLocked()
        }
    }

    public init(path: String) throws {
        self.path = path
        try queue.sync {
            try self.openLocked()
            try self.migrateLocked()
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public var filePath: String { path }

    

    public func loadSettings() -> AppSettings {
        queue.sync {
            guard let json = try? stringLocked("SELECT value FROM settings WHERE key = 'app'") else {
                return .default
            }
            guard let data = json.data(using: .utf8),
                  let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
                return .default
            }
            return settings
        }
    }

    public func saveSettings(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try queue.sync {
            try execLocked(
                "INSERT INTO settings(key, value) VALUES('app', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                bind: { stmt in bindText(stmt, 1, json) }
            )
        }
    }

    

    public func loadWorkspaces() -> [Workspace] {
        queue.sync {
            var rows: [Workspace] = []
            try? queryLocked("SELECT payload FROM workspaces ORDER BY created_at") { stmt in
                if let payload = columnText(stmt, 0),
                   let data = payload.data(using: .utf8),
                   let workspace = try? JSONDecoder().decode(Workspace.self, from: data) {
                    rows.append(workspace)
                }
            }
            return rows
        }
    }

    public func saveWorkspace(_ workspace: Workspace) throws {
        let data = try JSONEncoder().encode(workspace)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try queue.sync {
            try execLocked(
                """
                INSERT INTO workspaces(id, name, payload, created_at, last_active_at)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    payload = excluded.payload,
                    last_active_at = excluded.last_active_at
                """,
                bind: { stmt in
                    bindText(stmt, 1, workspace.id.uuidString)
                    bindText(stmt, 2, workspace.name)
                    bindText(stmt, 3, json)
                    sqlite3_bind_double(stmt, 4, workspace.createdAt.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 5, workspace.lastActiveAt.timeIntervalSince1970)
                }
            )
        }
    }

    public func deleteWorkspace(id: UUID) throws {
        try queue.sync {
            try execLocked("DELETE FROM workspaces WHERE id = ?", bind: { stmt in
                bindText(stmt, 1, id.uuidString)
            })
        }
    }

    

    public func insertSnapshot(_ snapshot: ProcessSnapshot) throws {
        try queue.sync {
            try execLocked(
                """
                INSERT INTO process_snapshots(
                    timestamp, pid, bundle_id, process_name, memory_footprint_mb,
                    cpu_percent, is_foreground, idle_seconds
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bind: { stmt in
                    sqlite3_bind_double(stmt, 1, snapshot.timestamp.timeIntervalSince1970)
                    sqlite3_bind_int(stmt, 2, snapshot.pid)
                    bindText(stmt, 3, snapshot.bundleID)
                    bindText(stmt, 4, snapshot.processName)
                    sqlite3_bind_double(stmt, 5, snapshot.memoryFootprintMB)
                    sqlite3_bind_double(stmt, 6, snapshot.cpuPercent)
                    sqlite3_bind_int(stmt, 7, snapshot.isForeground ? 1 : 0)
                    sqlite3_bind_double(stmt, 8, snapshot.idleSeconds)
                }
            )
        }
    }

    public func insertSnapshots(_ snapshots: [ProcessSnapshot]) throws {
        try queue.sync {
            try execLocked("BEGIN")
            do {
                for snapshot in snapshots {
                    try execLocked(
                        """
                        INSERT INTO process_snapshots(
                            timestamp, pid, bundle_id, process_name, memory_footprint_mb,
                            cpu_percent, is_foreground, idle_seconds
                        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bind: { stmt in
                            sqlite3_bind_double(stmt, 1, snapshot.timestamp.timeIntervalSince1970)
                            sqlite3_bind_int(stmt, 2, snapshot.pid)
                            bindText(stmt, 3, snapshot.bundleID)
                            bindText(stmt, 4, snapshot.processName)
                            sqlite3_bind_double(stmt, 5, snapshot.memoryFootprintMB)
                            sqlite3_bind_double(stmt, 6, snapshot.cpuPercent)
                            sqlite3_bind_int(stmt, 7, snapshot.isForeground ? 1 : 0)
                            sqlite3_bind_double(stmt, 8, snapshot.idleSeconds)
                        }
                    )
                }
                try execLocked("COMMIT")
            } catch {
                try? execLocked("ROLLBACK")
                throw error
            }
        }
    }

    public func insertActivation(_ activation: AppActivation) throws {
        try queue.sync {
            try execLocked(
                "INSERT INTO app_activations(timestamp, bundle_id, process_name) VALUES(?, ?, ?)",
                bind: { stmt in
                    sqlite3_bind_double(stmt, 1, activation.timestamp.timeIntervalSince1970)
                    bindText(stmt, 2, activation.bundleID)
                    bindText(stmt, 3, activation.processName)
                }
            )
        }
    }

    public func loadActivations(since: Date) -> [AppActivation] {
        queue.sync {
            var rows: [AppActivation] = []
            try? queryLocked(
                "SELECT timestamp, bundle_id, process_name FROM app_activations WHERE timestamp >= ? ORDER BY timestamp",
                bind: { stmt in sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970) }
            ) { stmt in
                let ts = sqlite3_column_double(stmt, 0)
                let bundle = columnText(stmt, 1) ?? ""
                let name = columnText(stmt, 2) ?? ""
                rows.append(AppActivation(timestamp: Date(timeIntervalSince1970: ts), bundleID: bundle, processName: name))
            }
            return rows
        }
    }

    public func insertFeedback(_ feedback: UserFeedback) throws {
        try queue.sync {
            try execLocked(
                "INSERT INTO user_feedback(bundle_id, score_at_decision, user_action, timestamp) VALUES(?, ?, ?, ?)",
                bind: { stmt in
                    bindText(stmt, 1, feedback.bundleID)
                    sqlite3_bind_double(stmt, 2, feedback.scoreAtDecisionTime)
                    bindText(stmt, 3, feedback.userAction)
                    sqlite3_bind_double(stmt, 4, feedback.timestamp.timeIntervalSince1970)
                }
            )
        }
    }

    public func loadBlacklist() -> Set<String> {
        queue.sync {
            var ids: Set<String> = []
            try? queryLocked("SELECT bundle_id FROM blacklist") { stmt in
                if let id = columnText(stmt, 0) {
                    ids.insert(id)
                }
            }
            return ids
        }
    }

    public func addToBlacklist(bundleID: String, reason: String) throws {
        try queue.sync {
            try execLocked(
                "INSERT OR REPLACE INTO blacklist(bundle_id, reason, created_at) VALUES(?, ?, ?)",
                bind: { stmt in
                    bindText(stmt, 1, bundleID)
                    bindText(stmt, 2, reason)
                    sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
                }
            )
        }
    }

    public func removeFromBlacklist(bundleID: String) throws {
        try queue.sync {
            try execLocked("DELETE FROM blacklist WHERE bundle_id = ?", bind: { stmt in
                bindText(stmt, 1, bundleID)
            })
        }
    }

    public func loadClassifications() -> [AppClassification] {
        queue.sync {
            var rows: [AppClassification] = []
            try? queryLocked("SELECT payload FROM app_classifications ORDER BY classified_at DESC") { stmt in
                if let payload = columnText(stmt, 0),
                   let data = payload.data(using: .utf8),
                   let item = try? JSONDecoder().decode(AppClassification.self, from: data) {
                    rows.append(item)
                }
            }
            return rows
        }
    }

    public func saveClassification(_ item: AppClassification) throws {
        let data = try JSONEncoder().encode(item)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try queue.sync {
            try execLocked(
                """
                INSERT INTO app_classifications(bundle_id, payload, classified_at)
                VALUES(?, ?, ?)
                ON CONFLICT(bundle_id) DO UPDATE SET
                    payload = excluded.payload,
                    classified_at = excluded.classified_at
                """,
                bind: { stmt in
                    bindText(stmt, 1, item.bundleID)
                    bindText(stmt, 2, json)
                    sqlite3_bind_double(stmt, 3, item.classifiedAt.timeIntervalSince1970)
                }
            )
        }
    }

    public func loadFrozen() -> [FrozenProcess] {
        queue.sync {
            var rows: [FrozenProcess] = []
            try? queryLocked(
                "SELECT pid, bundle_id, process_name, frozen_at, action, start_unix, original_nice FROM frozen_processes ORDER BY frozen_at DESC"
            ) { stmt in
                let pid = sqlite3_column_int(stmt, 0)
                let bundle = columnText(stmt, 1) ?? ""
                let name = columnText(stmt, 2) ?? ""
                let frozenAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                let action = SuggestedAction(rawValue: columnText(stmt, 4) ?? "freeze") ?? .freeze
                let startUnix = sqlite3_column_double(stmt, 5)
                let originalNice: Int32? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_int(stmt, 6)
                rows.append(
                    FrozenProcess(
                        pid: pid,
                        bundleID: bundle,
                        processName: name,
                        frozenAt: frozenAt,
                        action: action,
                        startUnix: startUnix,
                        originalNice: originalNice
                    )
                )
            }
            return rows
        }
    }

    public func replaceFrozen(_ items: [FrozenProcess]) throws {
        try queue.sync {
            try execLocked("BEGIN")
            do {
                try execLocked("DELETE FROM frozen_processes")
                for item in items {
                    try execLocked(
                        "INSERT INTO frozen_processes(pid, bundle_id, process_name, frozen_at, action, start_unix, original_nice) VALUES(?, ?, ?, ?, ?, ?, ?)",
                        bind: { stmt in
                            sqlite3_bind_int(stmt, 1, item.pid)
                            bindText(stmt, 2, item.bundleID)
                            bindText(stmt, 3, item.processName)
                            sqlite3_bind_double(stmt, 4, item.frozenAt.timeIntervalSince1970)
                            bindText(stmt, 5, item.action.rawValue)
                            sqlite3_bind_double(stmt, 6, item.startUnix)
                            if let nice = item.originalNice {
                                sqlite3_bind_int(stmt, 7, nice)
                            } else {
                                sqlite3_bind_null(stmt, 7)
                            }
                        }
                    )
                }
                try execLocked("COMMIT")
            } catch {
                try? execLocked("ROLLBACK")
                throw error
            }
        }
    }

    public func insertWorkspaceTransition(
        from: UUID?,
        to: UUID?,
        at: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        guard from != to else { return }
        let hour = calendar.component(.hour, from: at)
        let weekday = calendar.component(.weekday, from: at)
        try queue.sync {
            try execLocked(
                """
                INSERT INTO workspace_transitions(from_id, to_id, hour, weekday, timestamp)
                VALUES(?, ?, ?, ?, ?)
                """,
                bind: { stmt in
                    bindText(stmt, 1, from?.uuidString ?? "")
                    bindText(stmt, 2, to?.uuidString ?? "")
                    sqlite3_bind_int(stmt, 3, Int32(hour))
                    sqlite3_bind_int(stmt, 4, Int32(weekday))
                    sqlite3_bind_double(stmt, 5, at.timeIntervalSince1970)
                }
            )
        }
    }

    public func loadWorkspaceTransitions(limit: Int = 4000) -> [WorkspaceTransition] {
        queue.sync {
            var rows: [WorkspaceTransition] = []
            try? queryLocked(
                """
                SELECT id, from_id, to_id, hour, weekday, timestamp
                FROM workspace_transitions
                ORDER BY timestamp DESC
                LIMIT ?
                """,
                bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(limit)) }
            ) { stmt in
                let id = sqlite3_column_int64(stmt, 0)
                let fromID = uuidColumn(stmt, 1)
                let toID = uuidColumn(stmt, 2)
                let hour = Int(sqlite3_column_int(stmt, 3))
                let weekday = Int(sqlite3_column_int(stmt, 4))
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                rows.append(
                    WorkspaceTransition(
                        id: id,
                        fromWorkspaceID: fromID,
                        toWorkspaceID: toID,
                        hourOfDay: hour,
                        weekday: weekday,
                        timestamp: timestamp
                    )
                )
            }
            return rows
        }
    }

    public func pruneOlderThan(days: Int = 14) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600).timeIntervalSince1970
        let transitionCutoff = Date().addingTimeInterval(-180 * 24 * 3600).timeIntervalSince1970
        try queue.sync {
            try execLocked("DELETE FROM process_snapshots WHERE timestamp < ?", bind: { stmt in
                sqlite3_bind_double(stmt, 1, cutoff)
            })
            try execLocked("DELETE FROM app_activations WHERE timestamp < ?", bind: { stmt in
                sqlite3_bind_double(stmt, 1, cutoff)
            })
            try execLocked("DELETE FROM workspace_transitions WHERE timestamp < ?", bind: { stmt in
                sqlite3_bind_double(stmt, 1, transitionCutoff)
            })
        }
    }

    

    private func openLocked() throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw StoreError.openFailed(messageLocked())
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    private func migrateLocked() throws {
        try execLocked("""
        CREATE TABLE IF NOT EXISTS process_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            pid INTEGER NOT NULL,
            bundle_id TEXT,
            process_name TEXT NOT NULL,
            memory_footprint_mb REAL NOT NULL,
            cpu_percent REAL NOT NULL,
            is_foreground INTEGER NOT NULL,
            idle_seconds REAL NOT NULL
        );
        """)
        try execLocked("CREATE INDEX IF NOT EXISTS idx_snapshots_ts ON process_snapshots(timestamp);")
        try execLocked("""
        CREATE TABLE IF NOT EXISTS workspaces (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_active_at REAL NOT NULL
        );
        """)
        try execLocked("""
        CREATE TABLE IF NOT EXISTS app_activations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            bundle_id TEXT NOT NULL,
            process_name TEXT NOT NULL
        );
        """)
        try execLocked("CREATE INDEX IF NOT EXISTS idx_activations_ts ON app_activations(timestamp);")
        try execLocked("""
        CREATE TABLE IF NOT EXISTS user_feedback (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bundle_id TEXT NOT NULL,
            score_at_decision REAL NOT NULL,
            user_action TEXT NOT NULL,
            timestamp REAL NOT NULL
        );
        """)
        try execLocked("""
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        try execLocked("""
        CREATE TABLE IF NOT EXISTS blacklist (
            bundle_id TEXT PRIMARY KEY,
            reason TEXT,
            created_at REAL NOT NULL
        );
        """)
        try execLocked("""
        CREATE TABLE IF NOT EXISTS frozen_processes (
            pid INTEGER PRIMARY KEY,
            bundle_id TEXT,
            process_name TEXT NOT NULL,
            frozen_at REAL NOT NULL,
            action TEXT NOT NULL,
            start_unix REAL NOT NULL DEFAULT 0,
            original_nice INTEGER
        );
        """)
        try? execLocked("ALTER TABLE frozen_processes ADD COLUMN start_unix REAL NOT NULL DEFAULT 0")
        try? execLocked("ALTER TABLE frozen_processes ADD COLUMN original_nice INTEGER")
        try execLocked("""
        CREATE TABLE IF NOT EXISTS workspace_transitions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            from_id TEXT NOT NULL,
            to_id TEXT NOT NULL,
            hour INTEGER NOT NULL,
            weekday INTEGER NOT NULL,
            timestamp REAL NOT NULL
        );
        """)
        try execLocked("CREATE INDEX IF NOT EXISTS idx_transitions_from_hour ON workspace_transitions(from_id, hour);")
        try execLocked("CREATE INDEX IF NOT EXISTS idx_transitions_ts ON workspace_transitions(timestamp);")
        try execLocked("""
        CREATE TABLE IF NOT EXISTS app_classifications (
            bundle_id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            classified_at REAL NOT NULL
        );
        """)
    }

    private func execLocked(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.prepareFailed(sql, messageLocked())
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE && result != SQLITE_ROW {
            throw StoreError.execFailed(sql, messageLocked())
        }
        while result == SQLITE_ROW && sqlite3_step(stmt) == SQLITE_ROW {}
    }

    private func queryLocked(
        _ sql: String,
        bind: ((OpaquePointer) -> Void)? = nil,
        row: (OpaquePointer) -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.prepareFailed(sql, messageLocked())
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt)
        }
    }

    private func stringLocked(_ sql: String) throws -> String? {
        var value: String?
        try queryLocked(sql) { stmt in
            value = columnText(stmt, 0)
        }
        return value
    }

    private func messageLocked() -> String {
        guard let db else { return "no db" }
        if let c = sqlite3_errmsg(db) {
            return String(cString: c)
        }
        return "unknown sqlite error"
    }
}

private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
    if let value {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    } else {
        sqlite3_bind_null(stmt, index)
    }
}

private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
    guard let c = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: c)
}

private func uuidColumn(_ stmt: OpaquePointer, _ index: Int32) -> UUID? {
    guard let text = columnText(stmt, index), !text.isEmpty else { return nil }
    return UUID(uuidString: text)
}

public enum StoreError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String, String)
    case execFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "无法打开数据库：\(m)"
        case .prepareFailed(let sql, let m): return "SQL 编译失败：\(m) (\(sql))"
        case .execFailed(_, let m): return "SQL 执行失败：\(m)"
        }
    }
}
