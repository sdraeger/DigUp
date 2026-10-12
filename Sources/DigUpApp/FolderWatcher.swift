import CoreServices
import DigUpKit
import Foundation

/// File-level FSEvents on the chosen folders. Reports which paths changed (and whether each is a folder), a batch at
/// a time; the engine debounces and syncs. Costs nothing while nothing changes (no polling), and hidden files
/// (.DS_Store, editors' temp files) are ignored, since browsing a folder in Finder writes those: hidden below a
/// watched folder, that is (one chosen inside a hidden folder is watched like any other). `excluding` (up to
/// 8 folders inside `paths`) never reaches the app at all: ~/Library changes many times a second.
nonisolated final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([(path: String, isFolder: Bool)]) -> Void
    /// The watched folders as FSEvents reports paths in them (/private/tmp for /tmp).
    private let roots: [String]

    init?(paths: [String], excluding: [String] = [], latency: TimeInterval, queue: DispatchQueue,
          handler: @escaping @Sendable ([(path: String, isFolder: Bool)]) -> Void) {
        self.handler = handler
        roots = paths.map(FolderSelection.realPath)
        guard !paths.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, folderWatcherCallback, &context,
                                               paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, FSEventStreamCreateFlags(flags)) else { return nil }
        self.stream = stream
        if !excluding.isEmpty { FSEventStreamSetExclusionPaths(stream, Array(excluding.prefix(8)) as CFArray) }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    fileprivate func received(_ changes: [(path: String, isFolder: Bool)]) {
        let relevant = changes.filter { change in
            // Any watched folder it's in without a hidden one between (~/.config/notes, with home watched too).
            let inside = roots.filter { change.path == $0 || FolderSelection.isInside(change.path, $0) }
            return (inside.isEmpty ? [""] : inside).contains { root in
                !change.path.dropFirst(root.count).split(separator: "/").contains { $0.hasPrefix(".") }
            }
        }
        if !relevant.isEmpty { handler(relevant) }
    }
}

private nonisolated func folderWatcherCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
    _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
    // Dropped events come as a folder to scan again, without the folder flag.
    let folder = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagMustScanSubDirs)
    watcher.received(list.enumerated().map { (path: $1, isFolder: flags[$0] & folder != 0) })
}
