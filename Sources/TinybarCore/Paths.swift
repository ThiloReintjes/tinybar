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

    /// OpenCode's data directory: `XDG_DATA_HOME` if absolute, as OpenCode reads it, else `~/.local/share`.
    public static func openCodeData(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = env["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("opencode", isDirectory: true)
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

    /// Folders directly in the home directory that look like another login's config: `.claude*` or
    /// `.codex*`, other than the default ones (SPEC §15). Whether one holds a login is up to the caller.
    static func extraConfigDirs(
        _ provider: ProviderID, home: URL = Paths.home,
        env: [String: String] = ProcessInfo.processInfo.environment) -> [URL]
    {
        let prefix: String
        var defaults: [URL]
        // Only the one in use is the default: with the variable set, `~/.codex` is a login like any other.
        func isSet(_ name: String) -> Bool { env[name]?.trimmingCharacters(in: .whitespaces).isEmpty == false }
        switch provider {
        case .claude:
            prefix = ".claude"
            defaults = isSet("CLAUDE_CONFIG_DIR") ? claudeConfigDirs(env: env) : [home.appendingPathComponent(".claude", isDirectory: true)]
        case .codex:
            prefix = ".codex"
            defaults = isSet("CODEX_HOME") ? [codexHome(env: env)] : [home.appendingPathComponent(".codex", isDirectory: true)]
        case .gemini, .cursor, .opencode:
            return []
        }
        // claude-swap's own store isn't a login, though its name looks like one.
        defaults.append(home.appendingPathComponent(".claude-swap-backup", isDirectory: true))
        let taken = Set(defaults.map { $0.resolvingSymlinksInPath().path })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().compactMap { name in
            let url = home.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !taken.contains(url.resolvingSymlinksInPath().path)
            else { return nil }
            return url
        }
    }

    /// Every place Claude Code logs, the default first. Folders that resolve to the same place, like
    /// a `cswap run --share-history` profile, count once. Others are returned resolved, since the log
    /// walk doesn't follow a link at its root; the default stays as it was, as saved cursors name it.
    public static func claudeLogRoots(home: URL = Paths.home, env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let others = (extraConfigDirs(.claude, home: home, env: env) + ClaudeSwap.sessionFolders(home: home))
            .map { $0.appendingPathComponent("projects", isDirectory: true) }
        return unique(claudeConfigDirs(env: env).map { $0.appendingPathComponent("projects", isDirectory: true) } + others.filter(exists).map { $0.resolvingSymlinksInPath() })
    }

    /// Every place the Codex CLI logs, the default first.
    public static func codexLogRoots(home: URL = Paths.home, env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        func logs(_ home: URL) -> [URL] {
            [home.appendingPathComponent("sessions", isDirectory: true), home.appendingPathComponent("archived_sessions", isDirectory: true)]
        }
        return unique(logs(codexHome(env: env)) + extraConfigDirs(.codex, home: home, env: env).flatMap(logs).filter(exists).map { $0.resolvingSymlinksInPath() })
    }

    /// Only folders that really log are watched: `~/.claude-worktrees` looks like one and is busy.
    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }
}
