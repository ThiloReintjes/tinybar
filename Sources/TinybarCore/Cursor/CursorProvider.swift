import Foundation
import SQLite3

/// Cursor limits. Source order (as in CodexBar): Cursor.app's stored login → the cursor.com
/// session cookie in a browser. Both are only read; an expired token is never refreshed
/// (ADR 0001). Enabling Cursor in Settings is the consent to read its browser cookie (ADR 0005), since
/// many Cursor users have no app login on this Mac.
public struct CursorProvider: UsageProvider {
    public let id = ProviderID.cursor
    private let session: URLSession

    public init(session: URLSession = .tinybar) {
        self.session = session
    }

    /// Auto-enabled only when Cursor.app holds a login; the browser path is opt-in via Settings.
    public func isConfigured() -> Bool {
        CursorAppAuth.storedAccessToken() != nil
    }

    public func fetch() async throws -> ProviderSnapshot {
        var lastError = ProviderError.notConfigured
        if let stored = CursorAppAuth.storedAccessToken() {
            if let token = CursorAppAuth.accessToken(stored),
               let cookie = CursorAppAuth.cookieHeader(accessToken: token) {
                do {
                    return try await CursorUsageAPI.fetch(cookieHeader: cookie, source: .cli, session: session)
                } catch let error as ProviderError {
                    guard error == .loginExpired else { throw error }
                    lastError = error
                }
            } else {
                lastError = .loginExpired
            }
        }
        for domain in ["cursor.com", "www.cursor.com"] {
            guard let found = BrowserCookies.find(domain: domain, required: [CursorUsageAPI.sessionCookie]),
                  let value = found.cookies[CursorUsageAPI.sessionCookie]
            else { continue }
            return try await CursorUsageAPI.fetch(
                cookieHeader: "\(CursorUsageAPI.sessionCookie)=\(value)", source: .browser, session: session)
        }
        throw lastError
    }
}

/// Cursor.app (a VS Code fork) keeps its login in `state.vscdb`, key `cursorAuth/accessToken`.
enum CursorAppAuth {
    static var stateDB: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cursor/User/globalStorage/state.vscdb")
    }

    /// Presence keeps an expired login visible; usability is checked only when fetching.
    static func storedAccessToken(db: URL = stateDB) -> String? {
        guard let token = readItem("cursorAuth/accessToken", db: db), !token.isEmpty else { return nil }
        return token
    }

    /// The token if valid and not about to expire.
    static func accessToken(_ token: String, now: Date = Date()) -> String? {
        guard let payload = jwtPayload(token) else { return nil }
        if let exp = (payload["exp"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: exp) < now.addingTimeInterval(60) {
            return nil
        }
        return token
    }

    /// cursor.com accepts the app token as the web session cookie: `<userID>::<token>`.
    static func cookieHeader(accessToken: String) -> String? {
        guard let sub = jwtPayload(accessToken)?["sub"] as? String,
              let userID = sub.split(separator: "|").last.map(String.init), !userID.isEmpty,
              userID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.init(charactersIn: "._-")).contains($0) })
        else { return nil }
        return "\(CursorUsageAPI.sessionCookie)=\(userID)%3A%3A\(accessToken)"
    }

    static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Never lets SQLite write beside Cursor's database, including its WAL sidecars.
    static func readItem(_ key: String, db: URL = stateDB) -> String? {
        CredentialDatabase.read(db) { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            return decode(data)
        }
    }

    /// Values are usually UTF-8; some builds store UTF-16LE.
    static func decode(_ data: Data) -> String? {
        if data.count >= 2, data.count % 2 == 0, data[data.startIndex + 1] == 0 {
            return String(data: data, encoding: .utf16LittleEndian)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // VS Code storage sometimes JSON-quotes string values.
        if let q = s, q.hasPrefix("\""), q.hasSuffix("\""), q.count >= 2 { s = String(q.dropFirst().dropLast()) }
        return s
    }
}
