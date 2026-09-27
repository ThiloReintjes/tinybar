import Foundation

/// Gemini limits via the Antigravity CLI (`agy`). Google stopped serving Gemini CLI OAuth to
/// individual, AI Pro and Ultra accounts in June 2026; Antigravity is where those quotas live now.
///
/// Source: a short-lived `agy -p /usage --output-format json`. It runs the CLI's built-in usage
/// command (no model turn, no tokens spent), uses and refreshes the CLI's own login, and exits.
/// Same shape as the `codex app-server` fallback: Subar never touches Google tokens itself.
public struct GeminiProvider: UsageProvider {
    public let id = ProviderID.gemini

    public init() {}

    public func isConfigured() -> Bool {
        AntigravityCLI.locate() != nil
            && FileManager.default.fileExists(atPath: AntigravityCLI.stateDir.path)
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let executable = AntigravityCLI.locate() else { throw ProviderError.notConfigured }
        let output = try await Task.detached(priority: .utility) {
            try AntigravityCLI.runUsage(executable: executable)
        }.value
        return try AntigravityCLI.snapshot(fromUsageReport: output)
    }
}

enum AntigravityCLI {
    static var stateDir: URL { Paths.home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true) }

    static func locate() -> String? {
        let candidates = [
            Paths.home.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Report

    struct Report: Decodable {
        var status: String?
        var response: String?
        var command: Command?

        struct Command: Decodable {
            var name: String?
            var data: DataBlock?
        }

        struct DataBlock: Decodable {
            var groups: [Group]?
        }

        struct Group: Decodable {
            var name: String
            var buckets: [Bucket]?
        }

        struct Bucket: Decodable {
            var id: String?
            var name: String?
            var window: String?
            var remainingFraction: Double?
            var resetTime: String?

            enum CodingKeys: String, CodingKey {
                case id, name, window
                case remainingFraction = "remaining_fraction"
                case resetTime = "reset_time"
            }
        }
    }

    /// Groups as Antigravity reports them: "Gemini Models" is the Gemini quota; "Claude and GPT
    /// models" is Antigravity's separate allowance for third-party models, shown as model-specific.
    static func snapshot(fromUsageReport data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else {
            throw ProviderError.unexpected("agy returned no usage report (update Antigravity CLI)")
        }
        guard report.status == "SUCCESS", report.command?.name == "usage",
              let groups = report.command?.data?.groups, !groups.isEmpty
        else {
            let text = (report.response ?? "").lowercased()
            if ["sign in", "log in", "login", "auth", "credential"].contains(where: text.contains) {
                throw ProviderError.loginExpired
            }
            throw ProviderError.unexpected("agy usage report failed")
        }

        var windows: [LimitWindow] = []
        for group in groups {
            let isGemini = group.name.lowercased().hasPrefix("gemini")
            let prefix = isGemini ? nil : "third-party"
            let label = isGemini ? nil : "Claude & GPT"
            for bucket in group.buckets ?? [] {
                guard let fraction = bucket.remainingFraction else { continue }
                let seconds: Int? = switch bucket.window {
                case "5h": 5 * 3600
                case "weekly": 7 * 86400
                default: nil
                }
                let kind = WindowKind(durationSeconds: seconds)
                let base = kind.idComponent ?? bucket.id ?? bucket.window ?? "limit"
                let title = WindowKind.title(durationSeconds: seconds)
                windows.append(LimitWindow(
                    id: prefix.map { "\($0)-\(base)" } ?? base,
                    title: label.map { "\($0) \(title)" } ?? title,
                    usedPercent: min(max((1 - fraction) * 100, 0), 100),
                    resetsAt: bucket.resetTime.flatMap(parseISODate),
                    durationSeconds: seconds,
                    isModelSpecific: !isGemini))
            }
        }
        // Gemini first, 5-hour before weekly, like the other cards.
        windows.sort { a, b in
            if a.isModelSpecific != b.isModelSpecific { return !a.isModelSpecific }
            return (a.durationSeconds ?? .max) < (b.durationSeconds ?? .max)
        }
        return ProviderSnapshot(provider: .gemini, plan: nil, windows: windows, source: .cliProcess, fetchedAt: now)
    }

    // MARK: Process

    static let maxOutput = 1 << 20

    /// Runs the usage command in a private empty directory (so no project context is loaded),
    /// with logging off and stdin closed, and kills it if it hangs.
    static func runUsage(executable: String, timeout: TimeInterval = 45) throws -> Data {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subar-agy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "/usage", "--output-format", "json", "--log-file", "/dev/null"]
        process.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let stdout = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { throw ProviderError.unexpected("Could not launch agy: \(error.localizedDescription)") }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
        }

        var output = Data()
        let handle = stdout.fileHandleForReading
        while output.count <= maxOutput {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
        }
        if process.isRunning, output.count > maxOutput { process.terminate() }
        process.waitUntilExit()
        guard !output.isEmpty else { throw ProviderError.unexpected("agy exited without a usage report") }
        return output
    }
}
