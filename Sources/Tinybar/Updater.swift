import AppKit
import Observation
import TinybarCore

/// Finds a newer Tinybar once a day and installs it through Homebrew (SPEC §11, ADR 0007).
///
/// Installing runs in two steps. While Tinybar stays open, the tap is pulled and the new zip
/// downloaded, which is the slow part. Then a small script outlives Tinybar: it waits for it to
/// quit, lets Homebrew swap the app, and opens the new one. If that fails, the old one opens and
/// shows why.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case none
        case available(Release)
        case preparing(Release)
        case failed(Release, String)
    }

    private(set) var state = State.none

    static let cask = "thiloreintjes/tinybar/tinybar"
    static let command = "brew upgrade --cask \(cask)"
    private static let checkInterval: TimeInterval = 24 * 3600

    private let defaults = UserDefaults.standard
    private var log: URL { Paths.appSupport.appendingPathComponent("update.log") }
    private var marker: URL { Paths.appSupport.appendingPathComponent("update-failed") }

    /// The running version; nil for development builds outside an app bundle.
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var release: Release? {
        switch state {
        case .none: nil
        case let .available(r), let .preparing(r), let .failed(r, _): r
        }
    }

    init() {
        // A failed swap leaves a marker for the relaunched old version to explain.
        if let reason = try? String(contentsOf: marker, encoding: .utf8) {
            try? FileManager.default.removeItem(at: marker)
            if let r = known, isNewer(r) { state = .failed(r, reason) }
        } else if let r = known, isNewer(r) {
            state = .available(r)
        }
    }

    /// The last release seen, kept so the notice survives a relaunch without asking GitHub again.
    private var known: Release? {
        get { defaults.data(forKey: "latestRelease").flatMap { try? JSONDecoder().decode(Release.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "latestRelease") }
    }

    private func isNewer(_ r: Release) -> Bool {
        current.map { ReleaseCheck.isNewer(r.version, than: $0) } ?? false
    }

    /// Asks GitHub if a day has passed since the last check. Returns a release seen for the first
    /// time, to notify about once.
    func checkIfDue(now: Date = Date()) async -> Release? {
        guard current != nil else { return nil }
        if let last = defaults.object(forKey: "lastUpdateCheck") as? Date, now.timeIntervalSince(last) < Self.checkInterval {
            return nil
        }
        defaults.set(now, forKey: "lastUpdateCheck")
        guard let latest = try? await ReleaseCheck.latest() else { return nil }
        let isFirstSighting = known?.version != latest.version
        known = latest
        if case .preparing = state { return isNewer(latest) && isFirstSighting ? latest : nil }
        guard isNewer(latest) else {
            state = .none
            return nil
        }
        if state == .none || release?.version != latest.version { state = .available(latest) }
        return isFirstSighting ? latest : nil
    }

    /// Snapshots only.
    func showForSnapshot(_ state: State) { self.state = state }

    // MARK: Installing

    /// Whether Update installs in place; otherwise it opens the release page.
    var installsWithHomebrew: Bool { brew != nil }

    /// Homebrew, if Tinybar was installed with it.
    private var brew: String? {
        let runningApp = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        for prefix in ["/opt/homebrew", "/usr/local"]
        where FileManager.default.isExecutableFile(atPath: "\(prefix)/bin/brew") {
            let caskroom = URL(fileURLWithPath: "\(prefix)/Caskroom/tinybar", isDirectory: true)
            guard let versions = try? FileManager.default.contentsOfDirectory(at: caskroom, includingPropertiesForKeys: nil)
            else { continue }
            // Homebrew leaves a symlink to the installed app in its versioned staging directory.
            if versions.contains(where: {
                let staged = $0.appendingPathComponent("Tinybar.app")
                return FileManager.default.fileExists(atPath: staged.path)
                    && staged.resolvingSymlinksInPath().standardizedFileURL == runningApp
            }) {
                return "\(prefix)/bin/brew"
            }
        }
        return nil
    }

    func install() {
        guard let release else { return }
        if case .preparing = state { return }
        guard let brew else {
            // Not a Homebrew install: the release page has the zip.
            NSWorkspace.shared.open(release.url)
            return
        }
        state = .preparing(release)
        Task {
            let outcome = await Self.prepare(brew: brew, version: release.version, log: log)
            guard outcome == nil else {
                state = .failed(release, outcome!)
                return
            }
            swap(brew: brew, release: release)
        }
    }

    /// Pulls the tap and downloads the new zip. nil on success, else what went wrong.
    private nonisolated static func prepare(brew: String, version: String, log: URL) async -> String? {
        let script = """
        set -e
        tap="$("$BREW" --repository thiloreintjes/tinybar)"
        /usr/bin/git -C "$tap" pull --ff-only --quiet
        listed="$("$BREW" info --cask --json=v2 "$CASK" | /usr/bin/sed -n 's/.*"version": *"\\([^"]*\\)".*/\\1/p' | /usr/bin/head -1)"
        if [ "$listed" != "$VERSION" ]; then echo "Homebrew doesn't list $VERSION yet. Try again in a few minutes."; exit 3; fi
        "$BREW" fetch --cask "$CASK"
        """
        let (status, output) = await run(script, env: ["BREW": brew, "CASK": cask, "VERSION": version], log: log)
        guard status != 0 else { return nil }
        let last = output.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        return last.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) } ?? "Homebrew stopped with status \(status)."
    }

    /// Hands over to a script that outlives Tinybar, then quits.
    private func swap(brew: String, release: Release) {
        let app = Bundle.main.bundleURL.path
        let script = """
        while /bin/kill -0 "$PID" 2>/dev/null; do /bin/sleep 0.2; done
        if "$BREW" upgrade --cask "$CASK" >> "$LOG" 2>&1; then
          # Not notarized yet: clear the quarantine Homebrew sets, as the user asked for this update.
          /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        else
          /usr/bin/tail -n 1 "$LOG" > "$MARKER"
        fi
        /usr/bin/open "$APP"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = Self.environment.merging([
            "BREW": brew, "CASK": Self.cask, "APP": app, "LOG": log.path, "MARKER": marker.path,
            "PID": String(ProcessInfo.processInfo.processIdentifier),
        ]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            state = .failed(release, "Couldn't start Homebrew.")
            return
        }
        NSApp.terminate(nil)
    }

    private nonisolated static let environment: [String: String] = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(),
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    ]

    /// Runs a script with its output in `log`, which also holds what went wrong if it fails.
    private nonisolated static func run(_ script: String, env: [String: String], log: URL) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exec > \"$LOG\" 2>&1\n" + script]
            process.environment = environment.merging(env) { $1 }.merging(["LOG": log.path]) { $1 }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                continuation.resume(returning: (p.terminationStatus, output))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: (-1, "Couldn't start Homebrew."))
            }
        }
    }

    /// For the failure notice: the command to run by hand.
    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.command, forType: .string)
    }
}
