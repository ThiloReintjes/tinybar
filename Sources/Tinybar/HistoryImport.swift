import Foundation
import TinybarCore

/// Runs heavy one-off reads of the whole history in a child copy of this executable.
enum HistoryImport {
    enum Job: String {
        case importHistory = "--import-history"
        case backfillStats = "--backfill-stats"
        case backfillLongContext = "--backfill-long-context"
        case importOpenCode = "--import-opencode"
        case importLogFolders = "--import-log-folders"
    }

    /// Child side: ingest everything, printing "done/total" lines. Called before the app starts.
    static func runChildIfRequested() {
        guard let job = [Job.importHistory, .backfillStats, .backfillLongContext, .importOpenCode, .importLogFolders].first(where: { CommandLine.arguments.contains($0.rawValue) })
        else { return }
        Task.detached(priority: .utility) {
            do {
                let path = ProcessInfo.processInfo.environment["TINYBAR_DB"].map { URL(fileURLWithPath: $0) }
                let store = try path.map { try UsageStore(path: $0) } ?? UsageStore()
                let report: @Sendable (UsageStore.IngestProgress) -> Void = { p in
                    print("\(p.filesDone)/\(p.filesTotal)")
                    fflush(stdout)
                }
                switch job {
                case .importHistory:
                    if try await store.hasCompletedInitialImport() { exit(0) }
                    // An older import may have stopped before setting its marker. Complete the
                    // store's pending migrations before reading new bytes; each marks itself done.
                    if !(try await store.hasCompletedStatsBackfill()) { _ = try await store.backfillStats(progress: report) }
                    if !(try await store.hasCompletedLongContextBackfill()) { _ = try await store.backfillLongContext(progress: report) }
                    let roots = UsageStore.codexRoots + UsageStore.claudeRoots
                    _ = try await store.ingestAll(progress: report)
                    // OpenCode's own job retries this: a bad database of theirs doesn't stop the rest.
                    try? await store.importOpenCode()
                    try await store.markLogRootsRead(roots)
                    try await store.markInitialImportDone()
                case .backfillStats:
                    if !(try await store.hasCompletedStatsBackfill()) { _ = try await store.backfillStats(progress: report) }
                case .backfillLongContext:
                    if !(try await store.hasCompletedLongContextBackfill()) { _ = try await store.backfillLongContext(progress: report) }
                case .importOpenCode:
                    if !(try await store.hasCompletedOpenCodeImport()) { try await store.importOpenCode() }
                case .importLogFolders:
                    let roots = UsageStore.codexRoots + UsageStore.claudeRoots
                    _ = try await store.ingestAll(progress: report)
                    try await store.markLogRootsRead(roots)
                }
                exit(0)
            } catch {
                exit(1)
            }
        }
        dispatchMain()
    }

    /// Parent side. Failed jobs stay incomplete and can be retried on the next launch.
    @MainActor
    static func run(_ job: Job, progress: @escaping @MainActor (Double) -> Void) async -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = [job.rawValue]
        process.qualityOfService = .utility
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        let succeeded: Bool = await withCheckedContinuation { continuation in
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationReason == .exit && p.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
                return
            }
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last
                else { return }
                let parts = last.split(separator: "/").compactMap { Double($0) }
                guard parts.count == 2, parts[1] > 0 else { return }
                Task { @MainActor in progress(min(max(parts[0] / parts[1], 0), 1)) }
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        return succeeded
    }
}
