import Foundation

/// A row of the daily aggregate (SPEC §9).
public struct DailyUsage: Sendable, Hashable {
    public var day: String  // yyyy-MM-dd, local calendar day
    public var provider: ProviderID
    public var model: String
    public var project: String
    public var tokens: TokenCounts
    /// The part of `tokens` from long requests, by Context Band, for Long-context Prices.
    public var long: [Int64: TokenCounts] = [:]
}

/// Requests are filed by how far their context goes past these sizes, so Long-context Prices can
/// be applied at display time whatever tiers models.dev lists then (SPEC §10). Each request is
/// in one band: the largest size its context exceeds. A tier at a size between two bands is
/// applied from the next band up.
public enum ContextBand {
    public static let sizes: [Int64] = [100_000, 200_000, 272_000, 400_000, 1_000_000]

    public static func of(_ tokens: TokenCounts) -> Int64? {
        sizes.last { tokens.context > $0 }
    }
}

/// A row of the activity counters (SPEC §9).
public struct DailyStat: Sendable, Hashable {
    public var day: String
    public var provider: ProviderID
    public var model: String
    public var key: String
    public var value: Int64
}

/// Persistent store of daily token totals plus per-file read cursors, so history survives CLIs
/// deleting their logs and each ingest only reads appended bytes.
public actor UsageStore {
    private let db: SQLiteDB
    private let projects = ProjectResolver()
    private static let schemaVersion: Int64 = 6

    public init(path: URL = Paths.appSupport.appendingPathComponent("usage.sqlite")) throws {
        let db = try SQLiteDB(path: path.path)
        try db.transaction {
            try Self.migrate(db)
            try Self.armBackfill(db, key: "stats_backfill")
            try Self.armBackfill(db, key: "long_context_backfill", codexOnly: true)
        }
        self.db = db
    }

    private static func migrate(_ db: SQLiteDB) throws {
        let version = try db.run("PRAGMA user_version").first?.first?.int ?? 0
        guard version < schemaVersion else { return }
        if version >= 2 {
            // 0.5.0 files long requests by Context Band. Claude's come from the messages kept for
            // de-duplication; Codex logs are read again by `backfillLongContext`.
            try db.exec(longContextSchema)
            try db.exec("""
            INSERT OR REPLACE INTO daily_long_context
                (day, provider, model, project, band, input, output, cache_write, cache_read)
            SELECT day, provider, model, project, \(bandSQL("input + cache_write + cache_read")),
                   sum(input), sum(output), sum(cache_write), sum(cache_read)
            FROM claude_message WHERE input + cache_write + cache_read > \(ContextBand.sizes[0])
            GROUP BY 1, 2, 3, 4, 5;
            """)
        }
        if version == 5 {
            try db.exec("PRAGMA user_version = \(schemaVersion);")
            return
        }
        if version == 3 || version == 4 {
            // 0.2.0 kept prompts, tool calls, lines and Agent Time without their model; 0.3.0 had
            // no shell commands, file kinds or parallel tool calls. Count all activity again from
            // the logs still on disk (the backfill runs next).
            try db.exec("""
            DELETE FROM daily_stat;
            DELETE FROM claude_event;
            UPDATE claude_message SET stats = NULL;
            DELETE FROM meta WHERE key = 'stats_backfill';
            PRAGMA user_version = \(schemaVersion);
            """)
            return
        }
        if version == 2 {
            try db.exec("ALTER TABLE claude_message ADD COLUMN stats TEXT;" + statSchema + "PRAGMA user_version = \(schemaVersion);")
            return
        }
        if version == 1 {
            try db.exec(claudeMessageSchema + statSchema + longContextSchema + "PRAGMA user_version = \(schemaVersion);")
            return
        }
        try db.exec(claudeMessageSchema + statSchema + longContextSchema)
        try db.exec("""
        INSERT OR REPLACE INTO meta (key, value) VALUES ('long_context_backfill', 'done');
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
        PRAGMA user_version = \(schemaVersion);
        """)
    }

    /// The tokens of long requests (SPEC §10), a subset of `daily_usage` by Context Band.
    private static let longContextSchema = """
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS daily_long_context (
        day TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        project TEXT NOT NULL,
        band INTEGER NOT NULL,
        input INTEGER NOT NULL DEFAULT 0,
        output INTEGER NOT NULL DEFAULT 0,
        cache_write INTEGER NOT NULL DEFAULT 0,
        cache_read INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day, provider, model, project, band)
    ) WITHOUT ROWID;
    """

    /// `ContextBand.of` in SQL, for a context expression.
    private static func bandSQL(_ context: String) -> String {
        "CASE " + ContextBand.sizes.reversed().map { "WHEN \(context) > \($0) THEN \($0)" }.joined(separator: " ") + " END"
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
        cache_read INTEGER NOT NULL,
        stats TEXT
    ) WITHOUT ROWID;
    """

    /// Activity counters (SPEC §9), and the ids of one-off Claude events (prompts, edits,
    /// compactions) already counted, since resumed sessions copy them into new transcripts.
    private static let statSchema = """
    CREATE TABLE IF NOT EXISTS daily_stat (
        day TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        key TEXT NOT NULL,
        value INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day, provider, model, key)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS claude_event (
        id TEXT PRIMARY KEY,
        day TEXT NOT NULL
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
        try pruneClaudeMessagesDaily()
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
                        let cursor = try source == .codex ? codexCursor(path: path, stamp: stamp) : loadCursor(path: path)
                        switch source {
                        case .codex: return try ingestCodexFile(path: path, stamp: stamp, cursor: cursor, mode: .incremental)
                        case .claude: return try ingestClaudeFile(path: path, stamp: stamp, cursor: cursor, mode: .incremental)
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

    /// How a file is read. `backfill` re-reads what an earlier version already counted, up to the
    /// saved offset, for activity stats only: token totals and offsets stay as they are.
    /// `longContext` is the same for the tokens of long requests (Codex only; schema 6).
    enum ReadMode {
        case incremental
        case backfill
        case longContext
    }

    private func ingestCodexFile(path: String, stamp: FileStamp, cursor: Cursor?, mode: ReadMode, limit: Int64? = nil) throws -> (Int64, Int) {
        let url = URL(fileURLWithPath: path)
        // Resume only if it's the same file and it only grew; otherwise start over.
        var parser = CodexLogParser()
        var offset: Int64 = 0
        var until: Int64?
        if mode != .incremental {
            guard let cursor else { return (0, 0) }
            until = limit ?? cursor.offset
        } else if let cursor, cursor.stamp.inode == stamp.inode, stamp.size > cursor.stamp.size || stamp == cursor.stamp,
           let state = cursor.state, let decoded = try? JSONDecoder().decode(CodexLogParser.self, from: state)
        {
            parser = decoded
            offset = cursor.offset
        } else if let state = cursor?.state, let decoded = try? JSONDecoder().decode(CodexLogParser.self, from: state) {
            parser = CodexLogParser(replaying: decoded)
        }

        var agg: [AggKey: TokenCounts] = [:]
        var long: [AggKey: TokenCounts] = [:]
        var stats = StatBatch()
        var added = 0
        let endOffset = try JSONLReader.forEachLine(url: url, from: offset, until: until) { line in
            let current = ModelName.normalize(parser.model ?? "unknown")
            let record = parser.consume(line: line) { if mode != .longContext { stats.add($0, provider: .codex, model: current) } }
            guard let record else { return }
            let day = DayKey.string(for: record.timestamp)
            let model = ModelName.normalize(record.model)
            if mode != .longContext {
                stats.addResponse(day: day, provider: .codex, model: model, at: record.timestamp, tokens: record.tokens)
            }
            if mode != .backfill {
                let key = AggKey(day: day, model: model, project: projects.project(for: record.cwd))
                if mode == .incremental { agg[key, default: TokenCounts()] += record.tokens }
                if let band = ContextBand.of(record.tokens) { long[key.band(band), default: TokenCounts()] += record.tokens }
            }
            added += 1
        }

        for (key, t) in agg {
            try addDaily(day: key.day, provider: .codex, model: key.model, project: key.project, t)
        }
        for (key, tokens) in long {
            let t = mode == .longContext ? try boundedBackfill(tokens, key: key) : tokens
            if !t.isZero { try addLong(day: key.day, provider: .codex, model: key.model, project: key.project, band: key.band, t) }
        }
        try write(stats)
        let state = (try? JSONEncoder().encode(parser)).map { String(decoding: $0, as: UTF8.self) }
        if mode != .incremental, let cursor {
            if until == cursor.offset { try saveCursor(path: path, source: .codex, stamp: cursor.stamp, offset: cursor.offset, state: state) }
        } else {
            try saveCursor(path: path, source: .codex, stamp: stamp, offset: endOffset, state: state)
        }
        return (endOffset - offset, added)
    }

    private func ingestClaudeFile(path: String, stamp: FileStamp, cursor: Cursor?, mode: ReadMode, limit: Int64? = nil) throws -> (Int64, Int) {
        // Counting is per message id and idempotent, so a replaced or truncated file can simply
        // be re-read from the start.
        var offset: Int64 = 0
        var until: Int64?
        var session = ClaudeLogParser.Session(subagentFile: path.contains("/subagents/"))
        if mode == .backfill {
            guard let cursor else { return (0, 0) }
            until = limit ?? cursor.offset
        } else if let cursor, cursor.stamp.inode == stamp.inode, stamp.size > cursor.stamp.size || stamp == cursor.stamp {
            offset = cursor.offset
            if let state = cursor.state, let decoded = try? JSONDecoder().decode(ClaudeLogParser.Session.self, from: state) {
                session = decoded
            }
        }

        // Merge within the file first: streaming writes several lines per message.
        var latest: [String: ClaudeMessage] = [:]
        var order: [String] = []
        var events: [(id: String, at: Date, model: String, values: [String: Int64])] = []
        let endOffset = try JSONLReader.forEachLine(url: URL(fileURLWithPath: path), from: offset, until: until) { line in
            for event in session.consume(line: line) {
                switch event {
                case let .message(m):
                    if latest[m.entry.messageID] != nil {
                        latest[m.entry.messageID]!.merge(m)
                    } else {
                        latest[m.entry.messageID] = ClaudeMessage(m)
                        order.append(m.entry.messageID)
                    }
                case let .prompt(id, at, model):
                    events.append(("p:" + id, at, model, [StatKey.prompts: 1]))
                case let .edit(id, at, model, ext, added, removed):
                    events.append(("e:" + id, at, model, StatKey.edit(ext: ext, added: added, removed: removed)
                        .merging([StatKey.linesAdded: added, StatKey.linesRemoved: removed]) { a, _ in a }))
                case let .command(id, at, model, values):
                    events.append(("b:" + id, at, model, values))
                case let .commandResult(id, at, model, failed):
                    events.append(("x:" + id, at, model, [StatKey.commandsFinished: 1, StatKey.commandsFailed: failed ? 1 : 0]))
                case let .compaction(id, at, model, dropped):
                    events.append(("c:" + id, at, model, [StatKey.compactions: 1, StatKey.compactedTokens: dropped]))
                }
            }
        }

        var added = 0
        for id in order {
            guard let message = latest[id] else { continue }
            if try upsertClaudeMessage(id: id, message, countTokens: mode == .incremental) { added += 1 }
        }
        var stats = StatBatch()
        for event in events {
            let day = DayKey.string(for: event.at)
            try db.run("INSERT OR IGNORE INTO claude_event (id, day) VALUES (?, ?)", [.text(event.id), .text(day)])
            if db.changes > 0 {
                stats.add(StatEvent(timestamp: event.at, values: event.values),
                          provider: ClaudeLogParser.provider(forModel: event.model), model: event.model)
            }
        }
        try write(stats)
        let state = (try? JSONEncoder().encode(session)).map { String(decoding: $0, as: UTF8.self) }
        if mode == .backfill, let cursor {
            if until == cursor.offset { try saveCursor(path: path, source: .claude, stamp: cursor.stamp, offset: cursor.offset, state: state) }
        } else {
            try saveCursor(path: path, source: .claude, stamp: stamp, offset: endOffset, state: state)
        }
        return (endOffset - offset, added)
    }

    /// Records a message's usage and activity, replacing any earlier count for the same id.
    /// With `countTokens` false (backfill) the daily token totals are left alone.
    /// Returns true for a message seen for the first time.
    private func upsertClaudeMessage(id: String, _ message: ClaudeMessage, countTokens: Bool = true) throws -> Bool {
        let record = message.record
        let existing = try db.run(
            "SELECT day, provider, model, project, input, output, cache_write, cache_read, stats FROM claude_message WHERE id = ?",
            [.text(id)]).first

        if let e = existing {
            let old = TokenCounts(input: e[4].int, output: e[5].int, cacheWrite: e[6].int, cacheRead: e[7].int)
            let final = old.mergingCopy(record.tokens)
            let oldStats = e[8].text.flatMap { try? JSONDecoder().decode(MessageStats.self, from: Data($0.utf8)) }
            let newStats = MessageStats(message).merged(with: oldStats)
            let tokensChanged = final != old
            guard tokensChanged || newStats != oldStats else { return false }

            let day = e[0].text ?? ""
            let provider = e[1].text.flatMap(ProviderID.init(rawValue:)) ?? .claude
            let model = e[2].text ?? ""
            if tokensChanged && countTokens {
                // Undo the old contribution, keeping its original day/model/project.
                let project = e[3].text ?? ""
                try addDaily(day: day, provider: provider, model: model, project: project, -old)
                try addDaily(day: day, provider: provider, model: model, project: project, final)
                if let band = ContextBand.of(old) {
                    try addLong(day: day, provider: provider, model: model, project: project, band: band, -old)
                }
                if let band = ContextBand.of(final) {
                    try addLong(day: day, provider: provider, model: model, project: project, band: band, final)
                }
            }
            var stats = StatBatch()
            stats.replace(
                day: day, provider: provider, model: model,
                old: oldStats?.contributions(tokens: old) ?? [:], new: newStats.contributions(tokens: final))
            stats.addMaximum(day: day, provider: provider, model: model, StatKey.contextMax, final.context)
            try write(stats)
            try db.run("""
            UPDATE claude_message SET input = ?, output = ?, cache_write = ?, cache_read = ?, stats = ? WHERE id = ?
            """, [.int(final.input), .int(final.output), .int(final.cacheWrite),
                  .int(final.cacheRead), .text(newStats.encoded), .text(id)])
            return false
        }

        let day = DayKey.string(for: record.timestamp)
        let model = ModelName.normalize(record.model)
        let provider = ClaudeLogParser.provider(forModel: model)
        let project = projects.project(for: record.cwd)
        if countTokens {
            try addDaily(day: day, provider: provider, model: model, project: project, record.tokens)
            if let band = ContextBand.of(record.tokens) {
                try addLong(day: day, provider: provider, model: model, project: project, band: band, record.tokens)
            }
        }
        let newStats = MessageStats(message)
        var stats = StatBatch()
        stats.replace(day: day, provider: provider, model: model, old: [:], new: newStats.contributions(tokens: record.tokens))
        stats.addMaximum(day: day, provider: provider, model: model, StatKey.contextMax, record.tokens.context)
        try write(stats)
        try db.run("""
        INSERT INTO claude_message (id, day, provider, model, project, input, output, cache_write, cache_read, stats)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [.text(id), .text(day), .text(provider.rawValue), .text(model), .text(project),
              .int(record.tokens.input), .int(record.tokens.output), .int(record.tokens.cacheWrite), .int(record.tokens.cacheRead),
              .text(newStats.encoded)])
        return true
    }

    // MARK: Activity stats

    private func write(_ batch: StatBatch) throws {
        for (slot, value) in batch.sums where value != 0 {
            try db.run("""
            INSERT INTO daily_stat (day, provider, model, key, value) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(day, provider, model, key) DO UPDATE SET value = value + excluded.value
            """, [.text(slot.day), .text(slot.provider.rawValue), .text(slot.model), .text(slot.key), .int(value)])
        }
        for (slot, value) in batch.maxima where value > 0 {
            try db.run("""
            INSERT INTO daily_stat (day, provider, model, key, value) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(day, provider, model, key) DO UPDATE SET value = max(value, excluded.value)
            """, [.text(slot.day), .text(slot.provider.rawValue), .text(slot.model), .text(slot.key), .int(value)])
        }
    }

    /// Re-reads every log already ingested by a version without activity stats, up to its saved
    /// offset, counting activity only. Runs once, in the history import's child process.
    @discardableResult
    public func backfillStats(progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult {
        guard try !hasCompletedStatsBackfill() else { return IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0) }
        try db.transaction {
            try Self.armBackfill(db, key: "stats_backfill")
            try relocateArchivedCursors()
        }
        let cursors = try db.run("""
        SELECT path, provider, CAST(meta.value AS INTEGER) FROM file_cursor
        JOIN meta ON meta.key = 'stats_backfill_limit:' || path ORDER BY path
        """).compactMap { r -> (String, LogSource, Int64)? in
            guard let path = r[0].text, let source = r[1].text.flatMap(LogSource.init(rawValue:)) else { return nil }
            return (path, source, r[2].int)
        }
        var result = IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0)
        let batchSize = 200
        var index = 0
        while index < cursors.count {
            let batch = cursors[index..<min(index + batchSize, cursors.count)]
            try db.transaction {
                for (path, source, limit) in batch {
                    let checkpoint = "stats_backfill_file:" + path
                    guard try db.run("SELECT 1 FROM meta WHERE key = ?", [.text(checkpoint)]).isEmpty else { continue }
                    guard let cursor = try loadCursor(path: path), let stamp = Self.stamp(path),
                          stamp.inode == cursor.stamp.inode, stamp.size >= cursor.offset
                    else { continue }  // gone or replaced: the next ingest reads it from the start
                    let (read, added) = try autoreleasepool {
                        switch source {
                        case .codex: try ingestCodexFile(path: path, stamp: stamp, cursor: cursor, mode: .backfill, limit: limit)
                        case .claude: try ingestClaudeFile(path: path, stamp: stamp, cursor: cursor, mode: .backfill, limit: limit)
                        }
                    }
                    // Commit the checkpoint with its counters, so a restarted backfill cannot add them twice.
                    try db.run("INSERT INTO meta (key, value) VALUES (?, 'done')", [.text(checkpoint)])
                    result.filesScanned += 1
                    result.bytesRead += read
                    result.recordsAdded += added
                }
            }
            index += batch.count
            progress?(IngestProgress(filesDone: index, filesTotal: cursors.count))
        }
        try markStatsBackfillDone()
        if result.filesScanned > batchSize {
            try? db.exec("PRAGMA shrink_memory")
            malloc_zone_pressure_relief(nil, 0)
        }
        return result
    }

    /// Re-reads Codex logs up to their saved offsets, filing long requests by Context Band.
    /// Runs once after upgrading to schema 6, in the history import's child process.
    @discardableResult
    public func backfillLongContext(progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult {
        guard try !hasCompletedLongContextBackfill() else { return IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0) }
        try db.transaction {
            try Self.armBackfill(db, key: "long_context_backfill", codexOnly: true)
            try relocateArchivedCursors()
        }
        let paths = try db.run("""
        SELECT path, CAST(meta.value AS INTEGER) FROM file_cursor
        JOIN meta ON meta.key = 'long_context_backfill_limit:' || path ORDER BY path
        """).compactMap { r -> (String, Int64)? in r[0].text.map { ($0, r[1].int) } }
        var result = IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0)
        let batchSize = 200
        var index = 0
        while index < paths.count {
            let batch = paths[index..<min(index + batchSize, paths.count)]
            try db.transaction {
                for (path, limit) in batch {
                    let checkpoint = "long_context_backfill_file:" + path
                    guard try db.run("SELECT 1 FROM meta WHERE key = ?", [.text(checkpoint)]).isEmpty else { continue }
                    guard let cursor = try loadCursor(path: path), let stamp = Self.stamp(path),
                          stamp.inode == cursor.stamp.inode, stamp.size >= cursor.offset
                    else { continue }
                    let (read, added) = try autoreleasepool {
                        try ingestCodexFile(path: path, stamp: stamp, cursor: cursor, mode: .longContext, limit: limit)
                    }
                    try db.run("INSERT INTO meta (key, value) VALUES (?, 'done')", [.text(checkpoint)])
                    result.filesScanned += 1
                    result.bytesRead += read
                    result.recordsAdded += added
                }
            }
            index += batch.count
            progress?(IngestProgress(filesDone: index, filesTotal: paths.count))
        }
        try markLongContextBackfillDone()
        if result.filesScanned > batchSize {
            try? db.exec("PRAGMA shrink_memory")
            malloc_zone_pressure_relief(nil, 0)
        }
        return result
    }

    /// Freeze the pre-upgrade prefix before normal ingestion can advance any cursor.
    private static func armBackfill(_ db: SQLiteDB, key: String, codexOnly: Bool = false) throws {
        guard try db.run("SELECT 1 FROM meta WHERE key IN (?, ?) AND value = 'done'",
                         [.text(key), .text(key + "_bounds")]).isEmpty else { return }
        try db.run("""
        INSERT OR IGNORE INTO meta (key, value)
        SELECT ? || path, CAST(offset AS TEXT) FROM file_cursor
        """ + (codexOnly ? " WHERE provider = 'codex'" : ""), [.text(key + "_limit:")])
        try db.run("INSERT INTO meta (key, value) VALUES (?, 'done')", [.text(key + "_bounds")])
    }

    public func hasCompletedLongContextBackfill() throws -> Bool {
        try db.run("SELECT value FROM meta WHERE key = 'long_context_backfill'").first?.first?.text == "done"
    }

    public func markLongContextBackfillDone() throws {
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('long_context_backfill', 'done')")
            try db.exec("DELETE FROM meta WHERE key GLOB 'long_context_backfill_*'")
        }
    }

    public func hasCompletedStatsBackfill() throws -> Bool {
        try db.run("SELECT value FROM meta WHERE key = 'stats_backfill'").first?.first?.text == "done"
    }

    public func markStatsBackfillDone() throws {
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('stats_backfill', 'done')")
            try db.exec("DELETE FROM meta WHERE key GLOB 'stats_backfill_*'")
        }
    }

    /// How long a Claude message id is kept for de-duplication. Copies of a message in later
    /// transcripts (resumed sessions) were seen up to 29 days after it, and Claude Code deletes
    /// transcripts after 30 days by default, so 90 days leaves a wide margin. A copy older than
    /// that would be counted twice; daily totals are never touched by pruning (ADR 0003).
    public static let claudeMessageRetentionDays = 90

    /// Drops Claude message ids older than the retention window. Returns the number removed.
    @discardableResult
    public func pruneClaudeMessages(now: Date = Date()) throws -> Int {
        let cutoff = DayKey.daysAgo(Self.claudeMessageRetentionDays, from: now)
        try db.run("DELETE FROM claude_message WHERE day < ?", [.text(cutoff)])
        let removed = db.changes
        try db.run("DELETE FROM claude_event WHERE day < ?", [.text(cutoff)])
        return removed
    }

    /// Prunes at most once per day, so the 5-minute poll doesn't scan the table each time.
    private func pruneClaudeMessagesDaily(now: Date = Date()) throws {
        let today = DayKey.string(for: now)
        guard try db.run("SELECT value FROM meta WHERE key = 'claude_message_pruned'").first?.first?.text != today
        else { return }
        try pruneClaudeMessages(now: now)
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('claude_message_pruned', ?)", [.text(today)])
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

    /// Old cursors didn't keep their timezone or resolved Project. Don't create orphan bands
    /// when replay attribution changed, or let a backfill exceed the totals actually on file.
    private func boundedBackfill(_ t: TokenCounts, key: AggKey) throws -> TokenCounts {
        let params: [SQLiteDB.Value] = [.text(key.day), .text(key.model), .text(key.project)]
        let filter = " WHERE day = ? AND provider = 'codex' AND model = ? AND project = ?"
        guard let total = try db.run("SELECT input, output, cache_write, cache_read FROM daily_usage" + filter, params).first
        else { return TokenCounts() }
        let used = try db.run("SELECT sum(input), sum(output), sum(cache_write), sum(cache_read) FROM daily_long_context" + filter, params).first!
        let values = zip([t.input, t.output, t.cacheWrite, t.cacheRead], 0..<4).map { value, i in
            min(max(0, value), max(0, total[i].int - used[i].int))
        }
        return TokenCounts(input: values[0], output: values[1], cacheWrite: values[2], cacheRead: values[3])
    }

    private func addLong(day: String, provider: ProviderID, model: String, project: String, band: Int64, _ t: TokenCounts) throws {
        try db.run("""
        INSERT INTO daily_long_context (day, provider, model, project, band, input, output, cache_write, cache_read)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(day, provider, model, project, band) DO UPDATE SET
            input = input + excluded.input,
            output = output + excluded.output,
            cache_write = cache_write + excluded.cache_write,
            cache_read = cache_read + excluded.cache_read
        """, [.text(day), .text(provider.rawValue), .text(model), .text(project), .int(band),
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
        struct Key: Hashable { var day, provider, model, project: String }
        var long: [Key: [Int64: TokenCounts]] = [:]
        for r in try db.run(sql.replacingOccurrences(of: "project, input", with: "project, band, input")
            .replacingOccurrences(of: "daily_usage", with: "daily_long_context"), params)
        {
            let key = Key(day: r[0].text ?? "", provider: r[1].text ?? "", model: r[2].text ?? "", project: r[3].text ?? "")
            long[key, default: [:]][r[4].int] = TokenCounts(input: r[5].int, output: r[6].int, cacheWrite: r[7].int, cacheRead: r[8].int)
        }
        return try db.run(sql, params).compactMap { r in
            guard let provider = r[1].text.flatMap(ProviderID.init(rawValue:)) else { return nil }
            let key = Key(day: r[0].text ?? "", provider: r[1].text ?? "", model: r[2].text ?? "", project: r[3].text ?? "")
            return DailyUsage(
                day: key.day,
                provider: provider,
                model: key.model,
                project: key.project,
                tokens: TokenCounts(input: r[4].int, output: r[5].int, cacheWrite: r[6].int, cacheRead: r[7].int),
                long: long[key] ?? [:])
        }
    }

    /// Activity counters with `day >= since`.
    public func stats(since: String) throws -> [DailyStat] {
        try db.run("SELECT day, provider, model, key, value FROM daily_stat WHERE day >= ?", [.text(since)]).compactMap { r in
            guard let provider = r[1].text.flatMap(ProviderID.init(rawValue:)) else { return nil }
            return DailyStat(day: r[0].text ?? "", provider: provider, model: r[2].text ?? "", key: r[3].text ?? "", value: r[4].int)
        }
    }

    /// Every day with any tokens, oldest first: streaks span the whole history.
    /// Days with any usage, or with usage of one model.
    public func activeDays(model: String? = nil) throws -> [String] {
        if let model {
            return try db.run("SELECT DISTINCT day FROM daily_usage WHERE model = ? ORDER BY day", [.text(model)])
                .compactMap { $0.first?.text }
        }
        return try db.run("SELECT DISTINCT day FROM daily_usage ORDER BY day").compactMap { $0.first?.text }
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
        var band: Int64 = 0

        func band(_ b: Int64) -> AggKey { AggKey(day: day, model: model, project: project, band: b) }
    }

    /// Backfill runs before normal ingestion, so find rollouts archived since the last poll.
    private func relocateArchivedCursors() throws {
        let paths = try db.run("SELECT path FROM file_cursor WHERE provider = 'codex'").compactMap { $0[0].text }
        for path in paths where Self.stamp(path) == nil {
            var root = URL(fileURLWithPath: path).deletingLastPathComponent()
            while root.path != "/", root.lastPathComponent != "sessions" { root.deleteLastPathComponent() }
            guard root.lastPathComponent == "sessions" else { continue }
            let archive = root.deletingLastPathComponent().appendingPathComponent("archived_sessions")
            let file = archive.appendingPathComponent((path as NSString).lastPathComponent).path
            if let stamp = Self.stamp(file) { _ = try codexCursor(path: file, stamp: stamp) }
        }
    }

    /// Archiving renames a rollout without changing its inode. Move its cursor and any frozen
    /// backfill bounds with it instead of importing the same session under a second path.
    private func codexCursor(path: String, stamp: FileStamp) throws -> Cursor? {
        if let cursor = try loadCursor(path: path) { return cursor }
        guard let oldPath = try db.run("SELECT path FROM file_cursor WHERE provider = 'codex' AND inode = ?",
                                       [.int(stamp.inode)]).compactMap({ $0[0].text }).first(where: {
                                           ($0 as NSString).lastPathComponent == (path as NSString).lastPathComponent && Self.stamp($0) == nil
                                       }),
              let cursor = try loadCursor(path: oldPath) else { return nil }
        try db.run("UPDATE file_cursor SET path = ? WHERE path = ?", [.text(path), .text(oldPath)])
        for prefix in ["stats_backfill_limit:", "stats_backfill_file:", "long_context_backfill_limit:", "long_context_backfill_file:"] {
            try db.run("UPDATE meta SET key = ? WHERE key = ?", [.text(prefix + path), .text(prefix + oldPath)])
        }
        return cursor
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
    /// With `until`, stops at the first line that ends past that offset.
    static func forEachLine(
        url: URL, from start: Int64, until: Int64? = nil, _ body: (UnsafeRawBufferPointer) -> Void) throws -> Int64
    {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return start }
        defer { close(fd) }
        // An offset inside a line only occurs while skipping an oversized line. Recover that
        // state from the preceding byte, without rereading its already discarded prefix.
        var skipping = false
        if start > 0, lseek(fd, off_t(start - 1), SEEK_SET) == off_t(start - 1) {
            var previous: UInt8 = 0
            if read(fd, &previous, 1) == 1 { skipping = previous != 0x0A }
        }
        guard lseek(fd, off_t(start), SEEK_SET) == off_t(start) else { return start }

        let capacity = chunkSize + maxLineBytes
        let buf = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buf.deallocate() }
        var filled = 0            // valid bytes in buf
        var consumedOffset = start // file offset just past the last complete line

        var reachedLimit = false
        while !reachedLimit {
            let n = read(fd, buf + filled, capacity - filled)
            if n <= 0 { break }
            filled += n
            var lineStart = 0
            while lineStart < filled,
                  let nl = memchr(buf + lineStart, 0x0A, filled - lineStart)
            {
                let end = buf.distance(to: nl)
                if let until, consumedOffset + Int64(end + 1) > until {
                    reachedLimit = true
                    break
                }
                if skipping {
                    skipping = false
                } else if end - lineStart > maxLineBytes {
                    // Skipped whether or not it happens to fit in the buffer, so a full read and an
                    // incremental one see the same lines.
                } else if end > lineStart {
                    // Parsers build Foundation objects per line; release them per line, not per file.
                    autoreleasepool { body(UnsafeRawBufferPointer(start: buf + lineStart, count: end - lineStart)) }
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
        return consumedOffset
    }
}
