import Foundation

/// Maps a working directory to its Project: the git repository containing it (CONTEXT.md).
///
/// - Worktrees (a `.git` *file* pointing at `<repo>/.git/worktrees/<name>`) resolve to the main repo.
/// - A directory that no longer exists, with no repository above it, is named by its last path component.
/// - Anything else outside a repository has no Project.
public final class ProjectResolver: @unchecked Sendable {
    public static let noProject = ""

    private var cache: [String: String] = [:]
    private let lock = NSLock()
    private let fm = FileManager.default

    public init() {}

    /// Returns the Project key (repo root path), a bare name for deleted paths, or `noProject`.
    public func project(for cwd: String?) -> String {
        guard let cwd, cwd.hasPrefix("/") else { return Self.noProject }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[cwd] { return hit }
        let resolved = resolve(cwd)
        cache[cwd] = resolved
        return resolved
    }

    public static func displayName(_ project: String) -> String {
        project.isEmpty ? "No project" : (project as NSString).lastPathComponent
    }

    private func resolve(_ cwd: String) -> String {
        let standardized = (cwd as NSString).standardizingPath
        var dir = standardized
        while dir != "/" && !dir.isEmpty {
            if let cached = cache[dir] { return cached }
            let git = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                let root = isDir.boolValue ? dir : (mainRepo(fromGitFile: git) ?? dir)
                cache[dir] = root
                return root
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if !fm.fileExists(atPath: standardized) {
            return (standardized as NSString).lastPathComponent
        }
        return Self.noProject
    }

    /// `gitdir: /repo/.git/worktrees/name` → `/repo`. Submodules (`.git/modules/…`) keep their own dir.
    private func mainRepo(fromGitFile path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") {
            gitdir = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(gitdir)
        }
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<range.lowerBound])
    }
}
