import Foundation
import SQLite3

/// Tiny wrapper over the system SQLite. Not thread-safe; owned by one actor.
final class SQLiteDB {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw ProviderError.unexpected("Cannot open database at \(path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-2000;")
    }

    deinit {
        for stmt in statements.values { sqlite3_finalize(stmt) }
        sqlite3_close_v2(db)
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw ProviderError.unexpected("SQLite: \(message)")
        }
    }

    enum Value {
        case int(Int64)
        case text(String)
        case null
    }

    /// Runs a (cached) statement; returns rows as arrays of column values.
    @discardableResult
    func run(_ sql: String, _ params: [Value] = []) throws -> [[Value]] {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let .int(v): sqlite3_bind_int64(stmt, idx, v)
            case let .text(s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [[Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw ProviderError.unexpected("SQLite: \(String(cString: sqlite3_errmsg(db)))")
            }
            let n = sqlite3_column_count(stmt)
            var row: [Value] = []
            row.reserveCapacity(Int(n))
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_NULL: row.append(.null)
                default: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                }
            }
            rows.append(row)
        }
        return rows
    }

    var changes: Int { Int(sqlite3_changes(db)) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ProviderError.unexpected("SQLite prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        statements[sql] = stmt
        return stmt
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension SQLiteDB.Value {
    var int: Int64 {
        if case let .int(v) = self { return v }
        return 0
    }

    var text: String? {
        if case let .text(s) = self { return s }
        return nil
    }
}
