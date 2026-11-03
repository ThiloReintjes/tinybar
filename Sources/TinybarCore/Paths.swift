import Foundation

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Tinybar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A folder a CLI lets a variable override, else one in the home folder.
    private static func cliHome(_ variable: String, default folder: String, env: [String: String]) -> URL {
        if let custom = env[variable]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(folder, isDirectory: true)
    }

    public static func codexHome(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        cliHome("CODEX_HOME", default: ".codex", env: env)
    }

    /// Where a CLI is usually installed. GUI apps get a minimal PATH, so it can't be searched.
    static func locateCLI(_ name: String, home: URL = Paths.home) -> String? {
        let candidates = [
            home.appendingPathComponent(".local/bin/\(name)").path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// OpenCode's data directory: `XDG_DATA_HOME` if absolute, as OpenCode reads it, else `~/.local/share`.
    public static func openCodeData(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        xdgDir("XDG_DATA_HOME", default: ".local/share", env: env).appendingPathComponent("opencode", isDirectory: true)
    }

    /// The Copilot CLI's directory: `COPILOT_HOME` or `~/.copilot`.
    static func copilotHome(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        cliHome("COPILOT_HOME", default: ".copilot", env: env)
    }

    /// The Grok CLI's directory: `GROK_HOME` or `~/.grok`.
    static func grokHome(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        cliHome("GROK_HOME", default: ".grok", env: env)
    }

    /// An XDG variable if absolute, as those CLIs read it, else its default in the home folder.
    private static func xdgDir(_ variable: String, default folder: String, env: [String: String]) -> URL {
        env[variable].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? home.appendingPathComponent(folder, isDirectory: true)
    }

    static func xdgConfig(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        xdgDir("XDG_CONFIG_HOME", default: ".config", env: env)
    }

    /// `gh`'s config: `GH_CONFIG_DIR`, else `gh` in the XDG config directory.
    static func ghConfig(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = env["GH_CONFIG_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return xdgConfig(env: env).appendingPathComponent("gh", isDirectory: true)
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

    /// Another login's config folders, other than the default ones (SPEC §15): those directly in the
    /// home directory named like the default (`.codex*`), then the added ones holding that CLI's
    /// files. Whether one holds a login is up to the caller.
    static func extraConfigDirs(
        _ provider: ProviderID, home: URL = Paths.home,
        env: [String: String] = ProcessInfo.processInfo.environment,
        added: [URL] = AddedLoginFolders.urls()) -> [URL]
    {
        let dirs = extraConfigDirsByOrigin(provider, home: home, env: env, added: added)
        return dirs.inHome + dirs.added
    }

    /// `extraConfigDirs`, with those found in the home folder apart from the added ones.
    static func extraConfigDirsByOrigin(
        _ provider: ProviderID, home: URL = Paths.home,
        env: [String: String] = ProcessInfo.processInfo.environment,
        added: [URL] = AddedLoginFolders.urls()) -> (inHome: [URL], added: [URL])
    {
        guard let kind = LoginFolderKind.of(provider) else { return ([], []) }
        // Only the one in use is the default: with the variable set, `~/.codex` is a login like any
        // other. claude-swap's own store isn't a login, though its name looks like one.
        let defaults = kind.defaultFolders(home, env) + [home.appendingPathComponent(".claude-swap-backup", isDirectory: true)]
        var taken = Set(defaults.map { $0.resolvingSymlinksInPath().path })
        let names = kind.homePrefix.map { prefix in
            ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
        } ?? []
        let found = names.compactMap { name -> URL? in
            let url = home.appendingPathComponent(name, isDirectory: true)
            // Two links to one folder are one login.
            guard isDirectory(url), taken.insert(url.resolvingSymlinksInPath().path).inserted else { return nil }
            return url
        }
        // One the user added as well counts as added: it can be removed, and may ask the Keychain.
        let chosen = Set(added.map { $0.resolvingSymlinksInPath().path })
        let (alsoAdded, inHome) = found.reduce(into: ([URL](), [URL]())) { split, url in
            if chosen.contains(url.resolvingSymlinksInPath().path) { split.0.append(url) } else { split.1.append(url) }
        }
        return (inHome, alsoAdded + added.filter { url in
            isDirectory(url) && kind.holdsFiles(url) && taken.insert(url.resolvingSymlinksInPath().path).inserted
        })
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether a folder is the default login's, which is read anyway.
    /// Whether a folder is the default login's, which is read anyway: any CLI's, or `provider`'s.
    public static func isDefaultConfigDir(
        _ url: URL, of provider: ProviderID? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let place = url.resolvingSymlinksInPath().path
        return LoginFolderKind.all.filter { provider == nil || $0.provider == provider }
            .flatMap { $0.defaultFolders(home, env) }.contains { $0.resolvingSymlinksInPath().path == place }
    }

    /// A path as the user would type it: `~/…` inside the home folder.
    public static func abbreviated(_ url: URL, home: URL = Paths.home) -> String {
        let path = url.standardizedFileURL.path, root = home.standardizedFileURL.path
        if path == root { return "~" }
        return path.hasPrefix(root + "/") ? "~" + path.dropFirst(root.count) : path
    }

    /// Where the CLIs log by default: all that versions before Accounts read.
    static func defaultLogRoots(env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        claudeConfigDirs(env: env).map { $0.appendingPathComponent("projects", isDirectory: true) }
            + ["sessions", "archived_sessions"].map { codexHome(env: env).appendingPathComponent($0, isDirectory: true) }
    }

    /// Every place Claude Code logs, the default first. Folders that resolve to the same place, like
    /// a `cswap run --share-history` profile, count once. Others are returned resolved, since the log
    /// walk doesn't follow a link at its root; the default stays as it was, as saved cursors name it.
    public static func claudeLogRoots(
        home: URL = Paths.home, env: [String: String] = ProcessInfo.processInfo.environment,
        added: [URL] = AddedLoginFolders.urls()) -> [URL]
    {
        let others = (extraConfigDirs(.claude, home: home, env: env, added: added) + ClaudeSwap.sessionFolders(home: home))
            .map { $0.appendingPathComponent("projects", isDirectory: true) }
        return unique(claudeConfigDirs(env: env).map { $0.appendingPathComponent("projects", isDirectory: true) } + others.filter(exists).map { $0.resolvingSymlinksInPath() })
    }

    /// Every place the Codex CLI logs, the default first.
    public static func codexLogRoots(
        home: URL = Paths.home, env: [String: String] = ProcessInfo.processInfo.environment,
        added: [URL] = AddedLoginFolders.urls()) -> [URL]
    {
        func logs(_ home: URL) -> [URL] {
            [home.appendingPathComponent("sessions", isDirectory: true), home.appendingPathComponent("archived_sessions", isDirectory: true)]
        }
        // Grok's and OpenCode's folders hold an `auth.json` too: an added one counts only with a
        // Codex login in it, or their sessions would be read as Codex's.
        let dirs = extraConfigDirsByOrigin(.codex, home: home, env: env, added: added)
        let added = dirs.added.filter { LoginFolderKind.of(.codex)?.hasLogin($0) == true }
        return unique(logs(codexHome(env: env)) + (dirs.inHome + added).flatMap(logs).filter(exists).map { $0.resolvingSymlinksInPath() })
    }

    /// Only folders that really log are watched: `~/.claude-worktrees` looks like one and is busy.
    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// One of each place, keeping the order. A link gives way to the folder it points at, since the
    /// log walk doesn't follow a link at its root.
    static func unique(_ urls: [URL]) -> [URL] {
        var kept: [String: Int] = [:]
        var result: [URL] = []
        for url in urls {
            let place = url.resolvingSymlinksInPath().path
            if let i = kept[place] {
                let isLink = (try? result[i].resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                if isLink { result[i] = url }
            } else {
                kept[place] = result.count
                result.append(url)
            }
        }
        return result
    }
}
