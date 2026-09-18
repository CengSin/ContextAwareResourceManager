import Foundation

/// Resolves the Jev / OpenRouter API key without depending on adhoc Keychain ACLs.
///
/// Precedence:
/// 1. Process environment `RESOURCE_STEWARD_JEV_API_KEY`
/// 2. Same key in `~/Library/Application Support/ResourceSteward/env` (KEY=VALUE lines)
/// 3. Legacy Keychain item (often lost after adhoc re-sign)
public enum JevAPIKey {
    /// Export this in the shell / LaunchAgent / Application Support `env` file.
    public static let environmentVariable = "RESOURCE_STEWARD_JEV_API_KEY"

    public enum Source: String, Sendable {
        case environment
        case envFile
        case keychain
        case missing
    }

    public static var hasAPIKey: Bool { loadAPIKey() != nil }

    public static func loadAPIKey() -> String? {
        load().key
    }

    public static func load() -> (key: String?, source: Source) {
        if let key = trimmed(ProcessInfo.processInfo.environment[environmentVariable]) {
            return (key, .environment)
        }
        if let key = trimmed(valueFromEnvFile(named: environmentVariable)) {
            return (key, .envFile)
        }
        if let key = JevKeychain.loadAPIKey() {
            return (key, .keychain)
        }
        return (nil, .missing)
    }

    public static func statusDescription() -> String {
        switch load().source {
        case .environment:
            return "已配置（环境变量 \(environmentVariable)）"
        case .envFile:
            return "已配置（Application Support/env 文件）"
        case .keychain:
            return "已配置（钥匙串；adhoc 重签后可能丢失）"
        case .missing:
            return "未配置"
        }
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Parse `~/Library/Application Support/ResourceSteward/env` for KEY=VALUE lines.
    private static func valueFromEnvFile(named key: String) -> String? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = dir
            .appendingPathComponent("ResourceSteward", isDirectory: true)
            .appendingPathComponent("env", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == key else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2 {
                let first = value.first!
                let last = value.last!
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    value.removeFirst()
                    value.removeLast()
                }
            }
            return value
        }
        return nil
    }
}
