import CommonCrypto
import Foundation
import SQLite3

/// Reads session cookies from local browsers for the opt-in browser fallback (SPEC §4).
///
/// Chromium browsers encrypt cookies with a key kept in the login Keychain ("<Browser> Safe
/// Storage"); reading it shows a one-time macOS prompt, which is why this is opt-in. Firefox
/// stores cookies in plaintext. Safari needs Full Disk Access and is not supported.
public enum BrowserCookies {
    public struct Browser: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        /// Under ~/Library/Application Support.
        var root: String
        var keychainService: String?
        var keychainAccount: String?
        var isFirefox = false
    }

    public static let browsers: [Browser] = [
        Browser(name: "Chrome", root: "Google/Chrome", keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
        Browser(name: "Arc", root: "Arc/User Data", keychainService: "Arc Safe Storage", keychainAccount: "Arc"),
        Browser(name: "Dia", root: "Dia/User Data", keychainService: "Dia Safe Storage", keychainAccount: "Dia"),
        Browser(name: "Brave", root: "BraveSoftware/Brave-Browser", keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
        Browser(name: "Edge", root: "Microsoft Edge", keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
        Browser(name: "Comet", root: "Comet", keychainService: "Comet Safe Storage", keychainAccount: "Comet"),
        Browser(name: "Firefox", root: "Firefox/Profiles", isFirefox: true),
    ]

    public struct Found: Sendable {
        public var browser: String
        public var cookies: [String: String]
    }

    /// Returns the first browser profile holding all `required` cookie names for `domain`, with
    /// every cookie for that domain. Browsers are tried in order; decryption keys are only
    /// requested for a browser whose database actually contains the required cookie.
    public static func find(domain: String, required: [String]) -> Found? {
        for browser in browsers {
            for db in cookieDatabases(browser) {
                guard let rows = readRows(db: db, domain: domain, firefox: browser.isFirefox),
                      hasAll(required, in: rows.map(\.name))
                else { continue }
                let cookies = browser.isFirefox ? plaintext(rows) : decrypt(rows, browser: browser, db: db)
                if let cookies, hasAll(required, in: Array(cookies.keys)) {
                    return Found(browser: browser.name, cookies: cookies)
                }
            }
        }
        return nil
    }

    /// A required name also matches its chunked form ("name.0", "name.1", …).
    private static func hasAll(_ required: [String], in names: [String]) -> Bool {
        required.allSatisfy { r in names.contains { $0 == r || $0.hasPrefix(r + ".") } }
    }

    /// Value of a cookie that may be split into numbered chunks.
    public static func joined(_ name: String, in cookies: [String: String]) -> String? {
        if let v = cookies[name] { return v }
        var parts: [String] = []
        var i = 0
        while let part = cookies["\(name).\(i)"] { parts.append(part); i += 1 }
        return parts.isEmpty ? nil : parts.joined()
    }

    /// Browsers with a cookie database on this Mac (for the settings screen).
    public static func installed() -> [Browser] {
        browsers.filter { !cookieDatabases($0).isEmpty }
    }

    // MARK: Discovery

    static func cookieDatabases(_ browser: Browser) -> [URL] {
        let fm = FileManager.default
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(browser.root)
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        if browser.isFirefox {
            return entries.sorted().map { root.appendingPathComponent($0).appendingPathComponent("cookies.sqlite") }
                .filter { fm.fileExists(atPath: $0.path) }
        }
        let profiles = entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
        return profiles.compactMap { profile in
            let dir = root.appendingPathComponent(profile)
            return [dir.appendingPathComponent("Network/Cookies"), dir.appendingPathComponent("Cookies")]
                .first { fm.fileExists(atPath: $0.path) }
        }
    }

    // MARK: SQLite

    struct Row {
        var host: String
        var name: String
        var value: String
        var encrypted: Data
    }

    /// Opens the live database read-only as immutable: no locks, no WAL writes, so the browser
    /// is never disturbed (it may be running).
    static func readRows(db: URL, domain: String, firefox: Bool) -> [Row]? {
        var handle: OpaquePointer?
        let uri = "file:\(db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path)?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close_v2(handle)
            return nil
        }
        defer { sqlite3_close_v2(handle) }

        let sql = firefox
            ? "SELECT host, name, value, NULL FROM moz_cookies WHERE host = ? OR host = ?"
            : "SELECT host_key, name, value, encrypted_value FROM cookies WHERE host_key = ? OR host_key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, domain, -1, transient)
        sqlite3_bind_text(stmt, 2, "." + domain, -1, transient)

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text: (Int32) -> String = { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            var encrypted = Data()
            if let blob = sqlite3_column_blob(stmt, 3) {
                encrypted = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 3)))
            }
            rows.append(Row(host: text(0), name: text(1), value: text(2), encrypted: encrypted))
        }
        return rows
    }

    static func metaVersion(db: URL) -> Int {
        var handle: OpaquePointer?
        let uri = "file:\(db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path)?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close_v2(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM meta WHERE key = 'version'", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let v = sqlite3_column_text(stmt, 0) else { return 0 }
        return Int(String(cString: v)) ?? 0
    }

    // MARK: Decryption

    static func plaintext(_ rows: [Row]) -> [String: String] {
        Dictionary(rows.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// Cached per browser for the app's lifetime, so macOS asks at most once per launch
    /// (and never again after "Always Allow").
    nonisolated(unsafe) private static var keyCache: [String: Data] = [:]
    private static let keyLock = NSLock()

    static func decrypt(_ rows: [Row], browser: Browser, db: URL) -> [String: String]? {
        guard let key = key(for: browser) else { return nil }
        let stripsHostHash = metaVersion(db: db) >= 24
        var out: [String: String] = [:]
        for row in rows {
            if !row.value.isEmpty { out[row.name] = row.value; continue }
            guard row.encrypted.count > 3, row.encrypted.prefix(3) == Data("v10".utf8),
                  var plain = aes128CBCDecrypt(row.encrypted.dropFirst(3), key: key)
            else { continue }
            // Newer Chromium prefixes the plaintext with SHA256(host_key).
            if stripsHostHash, plain.count >= 32 { plain = plain.dropFirst(32) }
            if let s = String(data: plain, encoding: .utf8) { out[row.name] = s }
        }
        return out
    }

    static func key(for browser: Browser) -> Data? {
        guard let service = browser.keychainService, let account = browser.keychainAccount else { return nil }
        keyLock.lock(); defer { keyLock.unlock() }
        if let cached = keyCache[service] { return cached }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let password = item as? Data
        else { return nil }

        var derived = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { s in
                password.withUnsafeBytes { p in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        p.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        keyCache[service] = derived
        return derived
    }

    static func aes128CBCDecrypt(_ data: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLength = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, v.baseAddress,
                            d.baseAddress, data.count,
                            o.baseAddress, outCapacity, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLength
        return out
    }
}

/// Fetches limits using only the browser session (for diagnostics and the settings screen).
public enum BrowserFallback {
    public static func fetch(_ provider: ProviderID, session: URLSession = .subar) async throws -> (browser: String, snapshot: ProviderSnapshot) {
        switch provider {
        case .claude:
            guard let found = BrowserCookies.find(domain: "claude.ai", required: ["sessionKey"]),
                  let key = found.cookies["sessionKey"]
            else { throw ProviderError.notConfigured }
            return (found.browser, try await ClaudeWebAPI.fetch(sessionKey: key, session: session))
        case .codex:
            guard let found = BrowserCookies.find(domain: "chatgpt.com", required: [ChatGPTWebSession.cookieName])
            else { throw ProviderError.notConfigured }
            let creds = try await ChatGPTWebSession.accessToken(cookies: found.cookies, session: session)
            async let usage = CodexUsageAPI.fetchUsage(creds, session: session)
            async let banked = try? CodexUsageAPI.fetchBankedResets(creds, session: session)
            var snapshot = try await CodexUsageAPI.snapshot(from: usage, bankedResets: banked)
            snapshot.source = .browser
            return (found.browser, snapshot)
        case .cursor:
            let name = CursorUsageAPI.sessionCookie
            guard let found = BrowserCookies.find(domain: "cursor.com", required: [name]), let value = found.cookies[name]
            else { throw ProviderError.notConfigured }
            return (found.browser, try await CursorUsageAPI.fetch(cookieHeader: "\(name)=\(value)", source: .browser, session: session))
        case .gemini:
            throw ProviderError.notConfigured
        }
    }
}
