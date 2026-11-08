import CoreServices
import Foundation

/// Watches directory trees with FSEvents and calls back (on the main queue) after changes settle.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let handler: ([String]) -> Void

    /// `handler` receives the relevant paths that changed (files, with file-level events).
    init(paths: [String], handler: @escaping ([String]) -> Void) {
        self.paths = paths
        self.handler = handler
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let relevant = paths.prefix(count).filter(FileWatcher.isRelevant)
            if !relevant.isEmpty {
                watcher.handler(Array(relevant))
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Object writes and lock files churn constantly during git commands and never change what we show.
    static func isRelevant(_ path: String) -> Bool {
        if path.contains("/.git/objects/") || path.hasSuffix(".lock") { return false }
        if path.contains("/node_modules/") || path.contains("/.build/") || path.contains("/DerivedData/") { return false }
        return true
    }
}
