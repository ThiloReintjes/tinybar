import Foundation

/// Reads the Accounts claude-swap manages, through its versioned `cswap list --json` (ADR 0010).
/// Opt-in, because that command can renew an idle account's login. Tinybar never sees a token, and
/// never runs anything else, so it can't switch accounts.
public enum ClaudeSwap {
    static let arguments = ["list", "--json"]
    static let schemaVersion = 1
    static let maxOutput = 256 * 1024
    static let timeout: TimeInterval = 30
    /// What fixes a login only claude-swap can renew.
    static let loginHint = "log in with that account in `claude`, then run `cswap add`"

    public static func locate(home: URL = Paths.home) -> String? {
        let candidates = [
            home.appendingPathComponent(".local/bin/cswap").path,
            "/opt/homebrew/bin/cswap",
            "/usr/local/bin/cswap",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The `cswap run` profiles, whose logs Tinybar reads with or without this turned on (SPEC §9).
    static func sessionFolders(home: URL = Paths.home) -> [URL] {
        let root = home.appendingPathComponent(".claude-swap-backup/sessions", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().map { root.appendingPathComponent($0, isDirectory: true) }
    }

    public static func read(executable: String) throws -> [Account] {
        try parse(try run(executable: executable))
    }

    static func run(executable: String, timeout: TimeInterval = timeout) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // GUI apps get a minimal PATH; cswap is a Python script.
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let stdout = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { throw ProviderError.unexpected("Could not launch cswap") }
        // Asked to stop first, since it may be holding a credential lock. Then the whole group,
        // including any descendant that inherited stdout and would keep the read below waiting.
        let pid = process.processIdentifier
        let target = getpgid(pid) == pid ? -pid : pid
        let stop: @Sendable () -> Void = {
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { kill(target, SIGKILL) }
        }
        let watchdog = DispatchWorkItem(block: stop)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { stop() }
            process.waitUntilExit()
        }

        var output = Data()
        let handle = stdout.fileHandleForReading
        while output.count <= maxOutput {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
        }
        guard output.count <= maxOutput else { throw ProviderError.unexpected("cswap's report is too large") }
        // A handled failure exits non-zero with an error object on stdout, which `parse` reports.
        return output
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> [Account] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.unexpected("cswap's report isn't readable")
        }
        guard json["schemaVersion"] as? Int == schemaVersion else {
            throw ProviderError.unexpected("This version of cswap isn't supported")
        }
        guard json["error"] == nil, let rows = json["accounts"] as? [[String: Any]] else {
            throw ProviderError.unexpected("cswap couldn't list its accounts")
        }
        return rows.compactMap { account(from: $0, now: now) }
    }

    private static func account(from row: [String: Any], now: Date) -> Account? {
        let status = row["usageStatus"] as? String
        // No subscription, so no limits.
        guard status != "api_key" else { return nil }
        guard let email = nonEmpty(row["email"]) else { return nil }

        let identity = LoginIdentity(email: email, organization: nonEmpty(row["organizationUuid"]))
        var account = Account(
            id: identity.accountID, name: email, alias: nonEmpty(row["alias"]),
            organizationName: nonEmpty(row["organizationName"]),
            isActive: row["active"] as? Bool ?? false)

        if status == "ok", let usage = row["usage"] as? [String: Any] {
            account.snapshot = snapshot(from: usage, fetchedAt: date(row["usageFetchedAt"]) ?? now)
        } else {
            account.error = error(status: status)
            if account.error == .loginExpired { account.loginHint = loginHint }
            if let usage = row["lastGoodUsage"] as? [String: Any] {
                account.snapshot = snapshot(from: usage, fetchedAt: date(row["lastGoodFetchedAt"]) ?? now)
            }
        }
        return account
    }

    private static func error(status: String?) -> ProviderError {
        switch status {
        case "token_expired", "relogin_required", "no_credentials": .loginExpired
        case "keychain_unavailable": .unexpected("claude-swap couldn't read the Keychain")
        case "foreign_credential": .unexpected("Signed in as another account. Run `cswap switch` to repair it")
        default: .unexpected("claude-swap couldn't read this account's limits")
        }
    }

    private static func snapshot(from usage: [String: Any], fetchedAt: Date) -> ProviderSnapshot {
        var windows: [LimitWindow] = []
        func add(_ entry: Any?, id: String, title: String, seconds: Int?, modelSpecific: Bool) {
            guard let entry = entry as? [String: Any], let used = number(entry["pct"]) else { return }
            windows.append(LimitWindow(
                id: id, title: title, usedPercent: min(max(used, 0), 100), resetsAt: date(entry["resetsAt"]),
                durationSeconds: seconds, isModelSpecific: modelSpecific))
        }
        add(usage["fiveHour"], id: "session", title: "5-hour", seconds: 5 * 3600, modelSpecific: false)
        add(usage["sevenDay"], id: "weekly", title: "Weekly", seconds: 7 * 86400, modelSpecific: false)
        // Ids as the usage API maps them, so an Account's windows stay the same whichever way it's read.
        for case let entry as [String: Any] in usage["scoped"] as? [Any] ?? [] {
            guard let name = nonEmpty(entry["name"]) else { continue }
            add(entry, id: "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))-weekly",
                title: "\(name) Weekly", seconds: 7 * 86400, modelSpecific: true)
        }
        var extra: ExtraUsageSpend?
        if let spend = usage["spend"] as? [String: Any], let used = number(spend["used"]) {
            extra = ExtraUsageSpend(used: used, limit: number(spend["limit"]), currency: nonEmpty(spend["currency"]) ?? "USD")
        }
        return ProviderSnapshot(provider: .claude, plan: nil, windows: windows, extraUsage: extra, fetchedAt: fetchedAt)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap(parseISODate)
    }
}
