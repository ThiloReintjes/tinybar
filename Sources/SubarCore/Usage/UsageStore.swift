import Foundation

/// A row of the daily aggregate (SPEC §9).
public struct DailyUsage: Sendable, Hashable {
    public var day: String  // yyyy-MM-dd, local calendar day
    public var provider: ProviderID
    public var model: String
    public var project: String
    public var tokens: TokenCounts
}

/// Persistent store of daily token totals plus per-file read cursors, so history survives CLIs
/// deleting their logs and each ingest only reads appended bytes.
public actor UsageStore {
    private let db: SQLiteDB
    private let projects = ProjectResolver()
    private static let schemaVersion: Int64 = 2

    public init(path: URL = Paths.appSupport.appendingPathComponent("usage.sqlite")) throws {
        db = try SQLiteDB(path: path.path)
        try Self.migrate(db)
    }

    private static func migrate(_ db: SQLiteDB) throws {
        let version = try db.run("PRAGMA user_version").first?.first?.int ?? 0
        guard version < schemaVersion else { return }
        if version >= 1 {
            // v1 → v2: Claude message table only.
            try db.exec(claudeMessageSchema + "PRAGMA user_version = \(schemaVersion);")
            return
        }
        try db.exec(claudeMessageSchema)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS daily_usage (
            day TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            project TEXT NOT NULL,
            input INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            cache_write INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, provider, model, project)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS file_cursor (
            path TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            inode INTEGER NOT NULL,
            size INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            offset INTEGER NOT NULL,
            state BLOB
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
        PRAGMA user_version = \(schemaVersion);
        """)
    }

    /// One row per Claude message id: the usage we have counted for it, so a later, more
    /// complete copy of the same message replaces its contribution instead of adding to it.
    private static let claudeMessageSchema = """
    CREATE TABLE IF NOT EXISTS claude_message (
        id TEXT PRIMARY KEY,
        day TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        project TEXT NOT NULL,
        input INTEGER NOT NULL,
        output INTEGER NOT NULL,
        cache_write INTEGER NOT NULL,
        cache_read INTEGER NOT NULL
    ) WITHOUT ROWID;
    """

    // MARK: Ingestion

    public struct IngestProgress: Sendable {
        public var filesDone: Int
        public var filesTotal: Int
    }

    public struct IngestResult: Sendable {
        public var filesScanned: Int
        public var bytesRead: Int64
        public var recordsAdded: Int
    }

    public static let codexRoots = [
        Paths.codexHome().appendingPathComponent("sessions"),
        Paths.codexHome().appendingPathComponent("archived_sessions"),
    ]

    public static let claudeRoots: [URL] = Paths.claudeConfigDirs().map { $0.appendingPathComponent("projects") }

    public enum LogSource: String, Sendable, CaseIterable {
        case codex, claude

        public var roots: [URL] {
            switch self {
            case .codex: UsageStore.codexRoots
            case .claude: UsageStore.claudeRoots
            }
        }
    }

    /// Ingests every log source. With `only`, just those paths are checked (from `LogWatcher`)
    /// instead of walking every root.
    @discardableResult
    public func ingestAll(
        only: Set<String>? = nil,
        progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult
    {
        var total = IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0)
        for source in LogSource.allCases {
            let r = try ingest(source, roots: source.roots, only: only, progress: progress)
            total.filesScanned += r.filesScanned
            total.bytesRead += r.bytesRead
            total.recordsAdded += r.recordsAdded
        }
        return total
    }

    @discardableResult
    public func ingestCodex(
        roots: [URL] = UsageStore.codexRoots,
        only: Set<String>? = nil,
        progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult
    {
        try ingest(.codex, roots: roots, only: only, progress: progress)
    }

    @discardableResult
    public func ingestClaude(
        roots: [URL] = UsageStore.claudeRoots,
        only: Set<String>? = nil,
        progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult
    {
        try ingest(.claude, roots: roots, only: only, progress: progress)
    }

    /// Reads only bytes appended since the last run of each changed file.
    private func ingest(
        _ source: LogSource, roots: [URL], only: Set<String>?,
        progress: (@Sendable (IngestProgress) -> Void)?) throws -> IngestResult
    {
        var changed: [(String, FileStamp)] = []
        if let only {
            let rootPaths = roots.map { $0.path + "/" }
            for path in only where path.hasSuffix(".jsonl") && rootPaths.contains(where: path.hasPrefix) {
                if let stamp = Self.stamp(path), try isChanged(path, stamp) { changed.append((path, stamp)) }
            }
        } else {
            for root in roots {
                try Self.walkJSONL(root.path) { path, stamp in
                    if try isChanged(path, stamp) { changed.append((path, stamp)) }
                }
            }
        }
        // Oldest first, so a fork's parent is ingested before the fork when both are new.
        changed.sort { $0.1.mtime < $1.1.mtime }

        var result = IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0)
        let batchSize = 200
        var index = 0
        while index < changed.count {
            let batch = changed[index..<min(index + batchSize, changed.count)]
            try db.transaction {
                for (path, stamp) in batch {
                    let (read, added) = try autoreleasepool {
                        let cursor = try loadCursor(path: path)
                        switch source {
                        case .codex: return try ingestCodexFile(path: path, stamp: stamp, cursor: cursor)
                        case .claude: return try ingestClaudeFile(path: path, stamp: stamp, cursor: cursor)
                        }
                    }
                    result.filesScanned += 1
                    result.bytesRead += read
                    result.recordsAdded += added
                }
            }
            index += batch.count
            progress?(IngestProgress(filesDone: index, filesTotal: changed.count))
        }
        if result.filesScanned > batchSize {
            // A large import leaves the malloc heap full of freed pages; hand them back to the OS
            // so the idle footprint stays small.
            try? db.exec("PRAGMA shrink_memory")
            malloc_zone_pressure_relief(nil, 0)
        }
        return result
    }

    private func isChanged(_ path: String, _ stamp: FileStamp) throws -> Bool {
        guard let known = try db.run(
            "SELECT inode, size, mtime FROM file_cursor WHERE path = ?", [.text(path)]).first
        else { return true }
        return FileStamp(inode: known[0].int, size: known[1].int, mtime: known[2].int) != stamp
    }

    private func ingestCodexFile(path: String, stamp: FileStamp, cursor: Cursor?) throws -> (Int64, Int) {
        let url = URL(fileURLWithPath: path)
        // Resume only if it's the same file and it only grew; otherwise start over.
        var parser = CodexLogParser()
        var offset: Int64 = 0
        if let cursor, cursor.stamp.inode == stamp.inode, stamp.size >= cursor.offset,
           let state = cursor.state, let decoded = try? JSONDecoder().decode(CodexLogParser.self, from: state)
        {
            parser = decoded
            offset = cursor.offset
        } else if cursor != nil {
            // Rewritten file: its earlier contribution can't be separated from the aggregate, so
            // we accept a possible double count rather than keeping per-file rows. Rare for Codex.
            offset = 0
        }

        var agg: [AggKey: TokenCounts] = [:]
        var added = 0
        let endOffset = try JSONLReader.forEachLine(url: url, from: offset) { line in
            guard let record = parser.consume(line: line) else { return }
            let key = AggKey(
                day: DayKey.string(for: record.timestamp),
                model: ModelName.normalize(record.model),
                project: projects.project(for: record.cwd))
            agg[key, default: TokenCounts()] += record.tokens
            added += 1
        }

        for (key, t) in agg {
            try addDaily(day: key.day, provider: .codex, model: key.model, project: key.project, t)
        }
        let state = (try? JSONEncoder().encode(parser)).map { String(decoding: $0, as: UTF8.self) }
        try saveCursor(path: path, source: .codex, stamp: stamp, offset: endOffset, state: state)
        return (endOffset - offset, added)
    }

    private func ingestClaudeFile(path: String, stamp: FileStamp, cursor: Cursor?) throws -> (Int64, Int) {
        // Counting is per message id and idempotent, so a replaced or truncated file can simply
        // be re-read from the start.
        var offset: Int64 = 0
        if let cursor, cursor.stamp.inode == stamp.inode, stamp.size >= cursor.offset {
            offset = cursor.offset
        }

        // Merge within the file first: streaming writes several lines per message.
        var latest: [String: UsageRecord] = [:]
        var order: [String] = []
        let endOffset = try JSONLReader.forEachLine(url: URL(fileURLWithPath: path), from: offset) { line in
            guard let entry = ClaudeLogParser.parse(line: line) else { return }
            if let existing = latest[entry.messageID] {
                latest[entry.messageID] = Self.merged(existing, entry.record)
            } else {
                latest[entry.messageID] = entry.record
                order.append(entry.messageID)
            }
        }

        var added = 0
        for id in order {
            guard let record = latest[id] else { continue }
            if try upsertClaudeMessage(id: id, record) { added += 1 }
        }
        try saveCursor(path: path, source: .claude, stamp: stamp, offset: endOffset, state: nil)
        return (endOffset - offset, added)
    }

    /// Streaming copies only ever grow, so the field-wise max is the final usage regardless of
    /// the order copies are seen in.
    private static func merged(_ a: UsageRecord, _ b: UsageRecord) -> UsageRecord {
        var r = a
        r.tokens = TokenCounts(
            input: max(a.tokens.input, b.tokens.input),
            output: max(a.tokens.output, b.tokens.output),
            cacheWrite: max(a.tokens.cacheWrite, b.tokens.cacheWrite),
            cacheRead: max(a.tokens.cacheRead, b.tokens.cacheRead))
        if r.cwd == nil { r.cwd = b.cwd }
        return r
    }

    /// Records a message's usage, replacing any earlier count for the same id.
    /// Returns true for a message seen for the first time.
    private func upsertClaudeMessage(id: String, _ record: UsageRecord) throws -> Bool {
        let existing = try db.run(
            "SELECT day, provider, model, project, input, output, cache_write, cache_read FROM claude_message WHERE id = ?",
            [.text(id)]).first

        var final = record
        if let e = existing {
            let old = TokenCounts(input: e[4].int, output: e[5].int, cacheWrite: e[6].int, cacheRead: e[7].int)
            final = Self.merged(UsageRecord(timestamp: record.timestamp, model: record.model, cwd: record.cwd, tokens: old), record)
            if final.tokens == old { return false }
            // Undo the old contribution, keeping its original day/model/project.
            let oldProvider = e[1].text.flatMap(ProviderID.init(rawValue:)) ?? .claude
            try addDaily(day: e[0].text ?? "", provider: oldProvider, model: e[2].text ?? "", project: e[3].text ?? "",
                         TokenCounts(input: -old.input, output: -old.output, cacheWrite: -old.cacheWrite, cacheRead: -old.cacheRead))
            try addDaily(day: e[0].text ?? "", provider: oldProvider, model: e[2].text ?? "", project: e[3].text ?? "", final.tokens)
            try db.run("""
            UPDATE claude_message SET input = ?, output = ?, cache_write = ?, cache_read = ? WHERE id = ?
            """, [.int(final.tokens.input), .int(final.tokens.output), .int(final.tokens.cacheWrite),
                  .int(final.tokens.cacheRead), .text(id)])
            return false
        }

        let day = DayKey.string(for: record.timestamp)
        let model = ModelName.normalize(record.model)
        let provider = ClaudeLogParser.provider(forModel: model)
        let project = projects.project(for: record.cwd)
        try addDaily(day: day, provider: provider, model: model, project: project, record.tokens)
        try db.run("""
        INSERT INTO claude_message (id, day, provider, model, project, input, output, cache_write, cache_read)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [.text(id), .text(day), .text(provider.rawValue), .text(model), .text(project),
              .int(record.tokens.input), .int(record.tokens.output), .int(record.tokens.cacheWrite), .int(record.tokens.cacheRead)])
        return true
    }

    private func addDaily(day: String, provider: ProviderID, model: String, project: String, _ t: TokenCounts) throws {
        try db.run("""
        INSERT INTO daily_usage (day, provider, model, project, input, output, cache_write, cache_read)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(day, provider, model, project) DO UPDATE SET
            input = input + excluded.input,
            output = output + excluded.output,
            cache_write = cache_write + excluded.cache_write,
            cache_read = cache_read + excluded.cache_read
        """, [.text(day), .text(provider.rawValue), .text(model), .text(project),
              .int(t.input), .int(t.output), .int(t.cacheWrite), .int(t.cacheRead)])
    }

    private func saveCursor(path: String, source: LogSource, stamp: FileStamp, offset: Int64, state: String?) throws {
        try db.run("""
        INSERT OR REPLACE INTO file_cursor (path, provider, inode, size, mtime, offset, state)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [.text(path), .text(source.rawValue), .int(stamp.inode), .int(stamp.size),
              .int(stamp.mtime), .int(offset), state.map { .text($0) } ?? .null])
    }

    // MARK: Queries

    /// Daily rows with `day >= since` (inclusive), optionally for one provider.
    public func daily(since: String, provider: ProviderID? = nil) throws -> [DailyUsage] {
        var sql = "SELECT day, provider, model, project, input, output, cache_write, cache_read FROM daily_usage WHERE day >= ?"
        var params: [SQLiteDB.Value] = [.text(since)]
        if let provider {
            sql += " AND provider = ?"
            params.append(.text(provider.rawValue))
        }
        return try db.run(sql, params).compactMap { r in
            guard let provider = r[1].text.flatMap(ProviderID.init(rawValue:)) else { return nil }
            return DailyUsage(
                day: r[0].text ?? "",
                provider: provider,
                model: r[2].text ?? "",
                project: r[3].text ?? "",
                tokens: TokenCounts(input: r[4].int, output: r[5].int, cacheWrite: r[6].int, cacheRead: r[7].int))
        }
    }

    public func hasCompletedInitialImport() throws -> Bool {
        try db.run("SELECT value FROM meta WHERE key = 'initial_import'").first?.first?.text == "done"
    }

    public func markInitialImportDone() throws {
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('initial_import', 'done')")
    }

    // MARK: Internals

    struct FileStamp: Equatable {
        var inode: Int64
        var size: Int64
        var mtime: Int64

        init(inode: Int64, size: Int64, mtime: Int64) {
            self.inode = inode
            self.size = size
            self.mtime = mtime
        }

        init(_ st: stat) {
            inode = Int64(bitPattern: UInt64(st.st_ino))
            size = Int64(st.st_size)
            mtime = Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec / 1_000_000)
        }
    }

    struct Cursor {
        var stamp: FileStamp
        var offset: Int64
        var state: Data?
    }

    private struct AggKey: Hashable {
        var day: String
        var model: String
        var project: String
    }

    private func loadCursor(path: String) throws -> Cursor? {
        guard let r = try db.run(
            "SELECT inode, size, mtime, offset, state FROM file_cursor WHERE path = ?", [.text(path)]).first
        else { return nil }
        return Cursor(
            stamp: FileStamp(inode: r[0].int, size: r[1].int, mtime: r[2].int),
            offset: r[3].int,
            state: r[4].text.map { Data($0.utf8) })
    }

    /// Recursively visits `*.jsonl` files with one stat each, via fts(3): no Foundation
    /// objects per file, which matters with ~100k session files.
    static func walkJSONL(_ root: String, _ visit: (String, FileStamp) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: root) else { return }
        let rootC = strdup(root)
        defer { free(rootC) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootC, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_D, entry.pointee.fts_level > 0, String(cString: entry.pointee.fts_accpath).split(separator: "/").last?.hasPrefix(".") == true {  // skip hidden dirs
                fts_set(fts, entry, FTS_SKIP)
                continue
            }
            guard info == FTS_F, let st = entry.pointee.fts_statp?.pointee else { continue }
            let path = String(cString: entry.pointee.fts_path)
            guard path.hasSuffix(".jsonl") else { continue }
            try visit(path, FileStamp(st))
        }
    }

    static func stamp(_ path: String) -> FileStamp? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileStamp(st)
    }
}

/// Local calendar day keys (SPEC §9: day boundary).
public enum DayKey {
    public static func string(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func daysAgo(_ n: Int, from now: Date = Date(), calendar: Calendar = .current) -> String {
        string(for: calendar.date(byAdding: .day, value: -n, to: calendar.startOfDay(for: now))!, calendar: calendar)
    }

    /// Today is provisional; yesterday is too until 01:00 (logs are written late).
    public static func isProvisional(_ day: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if day >= string(for: now, calendar: calendar) { return true }
        return day == daysAgo(1, from: now, calendar: calendar) && calendar.component(.hour, from: now) < 1
    }
}

public enum ModelName {
    /// Strips vendor prefixes so log names match pricing keys (e.g. "openai/gpt-6-sol" → "gpt-6-sol").
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        return s.isEmpty ? "unknown" : s
    }
}

/// Streams lines of a file from a byte offset in 256 KB chunks. Returns the offset just past the
/// last complete line, so a half-written trailing line is re-read on the next ingest.
enum JSONLReader {
    static let chunkSize = 1024 * 1024
    /// Lines longer than this are skipped (Codex embeds multi-MB tool outputs; we never need them).
    static let maxLineBytes = 1024 * 1024

    /// Calls `body` with each complete line (no newline) as a raw buffer valid only for the call.
    static func forEachLine(url: URL, from start: Int64, _ body: (UnsafeRawBufferPointer) -> Void) throws -> Int64 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return start }
        defer { close(fd) }
        guard lseek(fd, off_t(start), SEEK_SET) == off_t(start) else { return start }

        let capacity = chunkSize + maxLineBytes
        let buf = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buf.deallocate() }
        var filled = 0            // valid bytes in buf
        var consumedOffset = start // file offset just past the last complete line
        var skipping = false       // inside an oversized line; drop bytes until the next newline

        while true {
            let n = read(fd, buf + filled, capacity - filled)
            if n <= 0 { break }
            filled += n
            var lineStart = 0
            while lineStart < filled,
                  let nl = memchr(buf + lineStart, 0x0A, filled - lineStart)
            {
                let end = buf.distance(to: nl)
                if skipping {
                    skipping = false
                } else if end > lineStart {
                    body(UnsafeRawBufferPointer(start: buf + lineStart, count: end - lineStart))
                }
                lineStart = end + 1
            }
            consumedOffset += Int64(lineStart)
            let rest = filled - lineStart
            if rest > maxLineBytes {
                consumedOffset += Int64(rest)
                filled = 0
                skipping = true
            } else {
                if rest > 0, lineStart > 0 { memmove(buf, buf + lineStart, rest) }
                filled = rest
            }
        }
        // If we stopped inside an oversized line, its remaining tail is read as one junk
        // fragment next time, which the parser ignores.
        return consumedOffset
    }
}
