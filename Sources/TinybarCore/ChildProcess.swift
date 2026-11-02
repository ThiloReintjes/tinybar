import Foundation

enum ChildProcess {
    private static let maxOutput = 256 * 1024

    private final class Output: @unchecked Sendable {
        var data = Data()
    }

    /// What a short-lived program printed, trimmed, or nil if it failed, ran out of time or printed
    /// more than any answer would. A descendant left holding stdout can't outlast the timeout.
    static func output(of executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let output = Output()
        let finished = DispatchSemaphore(value: 0)
        let handle = stdout.fileHandleForReading
        // Its own thread, as a busy Dispatch pool could otherwise use up the timeout before it starts.
        Thread.detachNewThread {
            while output.data.count <= maxOutput {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                output.data.append(chunk)
            }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success, output.data.count <= maxOutput else {
            if process.isRunning { process.terminate() }
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
