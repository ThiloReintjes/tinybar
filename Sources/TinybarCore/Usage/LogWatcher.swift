import CoreServices
import Foundation

/// Collects changed log paths via FSEvents. Ingestion still runs on the refresh schedule;
/// dropped events and directory changes ask the next drain for a full walk.
public final class LogWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "tinybar.logwatcher", qos: .utility)
    private let state: State

    // Retained by the stream, not the watcher: callbacks remain valid during teardown without
    // creating a watcher → stream → watcher cycle. All mutation runs on `queue`.
    private final class State {
        let roots: [String]
        var pending = Set<String>()
        var needsFullScan = true
        init(roots: [URL]) { self.roots = roots.map { $0.standardizedFileURL.path } }
    }

    public init(roots: [URL]) {
        state = State(roots: roots)
        let paths = Self.watchPaths(roots: roots) as CFArray
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(state).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<State>.fromOpaque(info).retain()
                return info
            }, release: { info in
                if let info { Unmanaged<State>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf
                | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, Self.callback, &context, paths,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 10, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    /// Watch an existing parent too, so a CLI installed after Tinybar starts is discovered.
    static func watchPaths(roots: [URL]) -> [String] {
        Array(Set(roots.map { root in
            var path = root.standardizedFileURL.deletingLastPathComponent().path
            while path != "/", !FileManager.default.fileExists(atPath: path) {
                path = (path as NSString).deletingLastPathComponent
            }
            return path
        }))
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

    public func drain() -> Changes {
        queue.sync {
            defer { state.pending.removeAll(); state.needsFullScan = false }
            return (state.needsFullScan || stream == nil) ? .all : .paths(state.pending)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self)
        for i in 0..<count {
            let f = Int(flags[i])
            if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 {
                state.needsFullScan = true
                continue
            }
            guard let path = list[i] as? String,
                  state.roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") })
            else { continue }
            if f & kFSEventStreamEventFlagItemIsDir != 0 {
                state.needsFullScan = true
            } else if path.hasSuffix(".jsonl") {
                state.pending.insert(path)
            }
        }
    }
}
