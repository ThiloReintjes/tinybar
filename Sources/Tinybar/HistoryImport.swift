import Foundation
import TinybarCore

/// Runs the first-launch history import in a child copy of this executable (`--import-history`),
/// reporting progress parsed from its stdout.
enum HistoryImport {
    static let flag = "--import-history"

    /// Child side: ingest everything, printing "done/total" lines. Called before the app starts.
    static func runChildIfRequested() {
        guard CommandLine.arguments.contains(flag) else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            if let store = try? UsageStore() {
                _ = try? await store.ingestAll { p in
                    print("\(p.filesDone)/\(p.filesTotal)")
                    fflush(stdout)
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    /// Parent side. Falls back to in-process ingestion if the child can't be launched.
    @MainActor
    static func run(progress: @escaping @MainActor (Double) -> Void) async {
        guard let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [flag]
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
        if done == nil {
            _ = try? await UsageStore().ingestAll()
        }
    }
}
