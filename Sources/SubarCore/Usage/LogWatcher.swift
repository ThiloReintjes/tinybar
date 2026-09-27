import CoreServices
import Foundation

/// Collects paths of changed `*.jsonl` files under the log roots via FSEvents, so a refresh only
/// stats the files that actually changed instead of walking ~100k session files.
///
/// Events are just recorded; ingestion still happens on the refresh schedule. If FSEvents reports
/// that it dropped events, the next drain asks for a full walk.
public final class LogWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "subar.logwatcher", qos: .utility)
    private var pending = Set<String>()
    private var needsFullScan = true

    public init(roots: [URL]) {
        let paths = roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
        stream = FSEventStreamCreate(
            nil, Self.callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            10,  // latency: coalesce Codex's frequent appends
            flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    public enum Changes: Sendable {
        case all
        case paths(Set<String>)
    }

    /// Returns what changed since the last drain and resets.
    public func drain() -> Changes {
        queue.sync {
            defer { pending.removeAll(); needsFullScan = false }
            return (needsFullScan || stream == nil) ? .all : .paths(pending)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self)
        for i in 0..<count {
            let f = Int(flags[i])
            if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                watcher.needsFullScan = true
                continue
            }
            guard let path = list[i] as? String, path.hasSuffix(".jsonl") else { continue }
            watcher.pending.insert(path)
        }
    }
}
