import Foundation

/// Fallback source: asks a short-lived `codex app-server` (sandboxed read-only, no approvals) for
/// rate limits over JSON-RPC, then terminates it. Lets the CLI use and refresh its own login.
enum CodexAppServer {
    struct Response: Decodable {
        var rateLimits: Snapshot
        var rateLimitsByLimitId: [String: Snapshot]?
        var rateLimitResetCredits: ResetCredits?
    }

    struct Snapshot: Decodable {
        var limitId: String?
        var limitName: String?
        var primary: Window?
        var secondary: Window?
        var credits: CreditsWire?
        var planType: String?
    }

    struct Window: Decodable {
        var usedPercent: Double
        var windowDurationMins: Int?
        var resetsAt: Int?
    }

    struct CreditsWire: Decodable {
        var hasCredits: Bool
        var unlimited: Bool
        var balance: String?
    }

    struct ResetCredits: Decodable {
        var credits: [ResetCredit]
    }

    struct ResetCredit: Decodable {
        var id: String
        var status: String
        var expiresAt: Int?
        var title: String?
    }

    static func fetch(timeout: TimeInterval = 15) async throws -> ProviderSnapshot {
        guard let executable = locateCodex() else { throw ProviderError.notConfigured }
        let result = try await Task.detached(priority: .utility) {
            try runRPC(executable: executable, timeout: timeout)
        }.value
        return snapshot(from: result)
    }

    static func snapshot(from r: Response, now: Date = Date()) -> ProviderSnapshot {
        var windows: [LimitWindow] = []
        var seen = Set<String>()
        let main = r.rateLimits
        let extras = (r.rateLimitsByLimitId ?? [:])
            .filter { $0.key != (main.limitId ?? "codex") }
            .sorted { $0.key < $1.key }
        for (snapshot, isExtra) in [(main, false)] + extras.map({ ($0.value, true) }) {
            let name = isExtra ? (snapshot.limitName ?? snapshot.limitId) : nil
            let prefix = name.map { $0.lowercased().replacingOccurrences(of: " ", with: "-") }
            for (w, fallbackID) in [(snapshot.primary, "primary"), (snapshot.secondary, "secondary")] {
                guard let w else { continue }
                let seconds = w.windowDurationMins.map { $0 * 60 }
                let base = WindowKind(durationSeconds: seconds).idComponent ?? fallbackID
                let id = prefix.map { "\($0)-\(base)" } ?? base
                guard seen.insert(id).inserted else { continue }
                let title = WindowKind.title(durationSeconds: seconds)
                windows.append(LimitWindow(
                    id: id,
                    title: name.map { "\($0) \(title)" } ?? title,
                    usedPercent: min(max(w.usedPercent, 0), 100),
                    resetsAt: w.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    durationSeconds: seconds,
                    isModelSpecific: isExtra))
            }
        }
        let credits = main.credits.map {
            Credits(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance.flatMap(Double.init))
        }
        let banked = r.rateLimitResetCredits?.credits.map {
            BankedReset(
                id: $0.id, title: $0.title, status: $0.status,
                expiresAt: $0.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
        return ProviderSnapshot(
            provider: .codex,
            plan: main.planType.map(CodexUsageAPI.formatPlan),
            windows: windows,
            credits: credits,
            bankedResets: banked,
            source: .cliProcess,
            fetchedAt: now)
    }

    // MARK: Process

    static func locateCodex() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            Paths.home.appendingPathComponent(".local/bin/codex").path,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func runRPC(executable: String, timeout: TimeInterval) throws -> Response {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        var env = ProcessInfo.processInfo.environment
        // GUI apps get a minimal PATH; the npm-installed CLI is a node script.
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { throw ProviderError.unexpected("Could not launch codex: \(error.localizedDescription)") }
        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        // Kill the child if it hangs; closing its stdout unblocks our reader.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: data)
        }

        var reader = LineReader(handle: stdout.fileHandleForReading)
        func response(id: Int) throws -> [String: Any] {
            while let line = reader.next() {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (obj["id"] as? NSNumber)?.intValue == id
                else { continue }
                if let error = obj["error"] as? [String: Any] {
                    throw ProviderError.unexpected("codex app-server: \(error["message"] as? String ?? "error")")
                }
                return obj
            }
            throw ProviderError.unexpected("codex app-server exited without answering")
        }

        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "subar", "version": "0.1.0"]]])
        _ = try response(id: 1)
        try send(["method": "initialized", "params": [String: Any]()])
        try send(["id": 2, "method": "account/rateLimits/read", "params": [String: Any]()])
        let message = try response(id: 2)
        guard let result = message["result"] else { throw ProviderError.unexpected("codex app-server: no result") }
        let data = try JSONSerialization.data(withJSONObject: result)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected codex app-server response")
        }
    }
}

/// Minimal blocking newline reader over a pipe.
struct LineReader {
    let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) { self.handle = handle }

    mutating func next() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(chunk)
        }
    }
}
