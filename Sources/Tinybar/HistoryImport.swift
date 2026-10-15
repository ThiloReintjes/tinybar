import Foundation
import TinybarCore

/// Runs heavy one-off reads of the whole history in a child copy of this executable, reporting
/// progress parsed from its stdout: the first-launch import (`--import-history`) and the one-time
/// activity backfill after upgrading from a version without Stats (`--backfill-stats`).
enum HistoryImport {
    enum Job: String {
        case importHistory = "--import-history"
        case backfillStats = "--backfill-stats"
    }

    /// Child side: ingest everything, printing "done/total" lines. Called before the app starts.
    static func runChildIfRequested() {
        guard let job = [Job.importHistory, .backfillStats].first(where: { CommandLine.arguments.contains($0.rawValue) })
        else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            let path = ProcessInfo.processInfo.environment["TINYBAR_DB"].map { URL(fileURLWithPath: $0) }
            if let store = try? path.map({ try UsageStore(path: $0) }) ?? UsageStore() {
                let report: @Sendable (UsageStore.IngestProgress) -> Void = { p in
                    print("\(p.filesDone)/\(p.filesTotal)")
                    fflush(stdout)
                }
                switch job {
                case .importHistory: _ = try? await store.ingestAll(progress: report)
                case .backfillStats: _ = try? await store.backfillStats(progress: report)
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    /// Parent side. Falls back to running in-process if the child can't be launched.
    @MainActor
    static func run(_ job: Job, progress: @escaping @MainActor (Double) -> Void) async {
        guard let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [job.rawValue]
        process.qualityOfService = .utility
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        let done: Void? = await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume(returning: ()) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
                return
            }
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last
                else { return }
                let parts = last.split(separator: "/").compactMap { Double($0) }
                guard parts.count == 2, parts[1] > 0 else { return }
                Task { @MainActor in progress(parts[0] / parts[1]) }
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        if done == nil, let store = try? UsageStore() {
            switch job {
            case .importHistory: _ = try? await store.ingestAll()
            case .backfillStats: _ = try? await store.backfillStats()
            }
        }
    }
}
