import Foundation

/// The OAuth login Claude Code stores. Read-only: Tinybar never refreshes or rewrites it (ADR 0001).
///
/// Sources, in order:
/// 1. `<config dir>/.credentials.json` (Linux-style installs, `CLAUDE_CONFIG_DIR`).
/// 2. The login Keychain item `Claude Code-credentials`, read via `/usr/bin/security`.
///    Claude Code itself writes the item with that tool, so it is already on the item's access
///    list and reading through it does not show a password prompt, unlike a direct
///    Security.framework read from Tinybar's own binary.
public struct ClaudeCredentials: Sendable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// "max" → "Max", "pro" → "Pro"; tier refines Max (e.g. "default_claude_max_20x" → "Max 20x").
    public var planName: String? {
        guard let sub = subscriptionType?.lowercased(), !sub.isEmpty else { return nil }
        var name = sub.prefix(1).uppercased() + sub.dropFirst()
        if sub == "max", let tier = rateLimitTier?.lowercased(),
           let range = tier.range(of: #"\d+x"#, options: .regularExpression)
        {
            name += " \(tier[range])"
        }
        return name
    }

    static let keychainService = "Claude Code-credentials"

    /// The Keychain item of a login in another config folder. Claude Code names it with a hash of
    /// the `CLAUDE_CONFIG_DIR` it ran with; this isn't documented, so a change would hide the folder.
    static func keychainService(folder: URL?) -> String {
        guard let folder else { return keychainService }
        return "\(keychainService)-\(sha256Hex(folder.path.precomposedStringWithCanonicalMapping).prefix(8))"
    }

    /// With `folder`, a login in that config folder; without, the default login.
    public static func hasStoredLogin(folder: URL? = nil) -> Bool {
        if credentialFiles(folder: folder).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { return true }
        // Attribute-only lookup: never touches the secret, never prompts.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService(folder: folder)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    public static func load(folder: URL? = nil) throws -> ClaudeCredentials {
        for file in credentialFiles(folder: folder) {
            if let data = try? Data(contentsOf: file) { return try parse(data) }
        }
        guard let data = try readKeychain(service: keychainService(folder: folder)) else { throw ProviderError.notConfigured }
        return try parse(data)
    }

    static func credentialFiles(folder: URL? = nil) -> [URL] {
        (folder.map { [$0] } ?? Paths.claudeConfigDirs()).map { $0.appendingPathComponent(".credentials.json") }
    }

    /// Who is signed in, from the `oauthAccount` Claude Code keeps beside its settings. nil when it
    /// can't be told.
    public static func identity(folder: URL? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> LoginIdentity? {
        // The folder `load` would take the token from, so limits are filed under whose they are.
        let dirs = folder.map { [$0] } ?? Paths.claudeConfigDirs(env: env)
        let configHome = dirs.first { FileManager.default.isReadableFile(atPath: $0.appendingPathComponent(".credentials.json").path) } ?? dirs[0]
        let base = folder ?? (env["CLAUDE_CONFIG_DIR"]?.isEmpty == false ? configHome : Paths.home)
        // An older config file wins while it holds anything, as it does in Claude Code.
        let legacy = configHome.appendingPathComponent(".config.json")
        let size = (try? legacy.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let file = size > 0 ? legacy : base.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return identity(fromConfig: data)
    }

    static func identity(fromConfig data: Data) -> LoginIdentity? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let email = (account["emailAddress"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty
        else { return nil }
        return LoginIdentity(
            email: email,
            organization: account["organizationUuid"] as? String,
            organizationName: account["organizationName"] as? String)
    }

    static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { throw ProviderError.notConfigured }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String)
    }

    private static func readKeychain(service: String, timeout: TimeInterval = 5) throws -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        // If macOS ever shows an access prompt, don't hang the refresh on it.
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        guard p.terminationStatus == 0 else { return nil }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // `security -w` prints hex for values it deems binary.
        if !trimmed.hasPrefix("{"), let decoded = Data(hexString: trimmed) { return decoded }
        return Data(trimmed.utf8)
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0, hexString.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes)
    }
}
