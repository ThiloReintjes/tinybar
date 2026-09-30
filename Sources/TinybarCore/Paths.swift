import Foundation

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Tinybar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func codexHome(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Claude Code config dirs: `CLAUDE_CONFIG_DIR` (comma-separated) or `~/.claude` and
    /// `~/.config/claude`, whichever exist.
    public static func claudeConfigDirs(env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let custom = env["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return custom.split(separator: ",").map {
                URL(fileURLWithPath: ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
        let candidates = [
            home.appendingPathComponent(".claude", isDirectory: true),
            home.appendingPathComponent(".config/claude", isDirectory: true),
        ]
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        return existing.isEmpty ? [candidates[0]] : existing
    }
}
