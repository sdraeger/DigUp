import Foundation

/// Timestamped lines in `<index folder>/app.log` and on stderr. This is how the app gets measured during
/// development (launch, sync, search and indexing timings), so lines say what happened and how long it took.
/// At `maxBytes` the log moves to app.log.1 (replacing the one before), so the two never take more than twice that.
nonisolated final class AppLog: @unchecked Sendable {
    static let shared = AppLog()
    static let maxBytes: UInt64 = 5 << 20
    private let lock = NSLock()
    private var file: FileHandle?
    private var url: URL?

    func open(in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        lock.withLock {
            file = handle
            self.url = url
        }
    }

    func write(_ message: String) {
        let data = Data("\(Self.timestamp()) \(message)\n".utf8)
        lock.withLock {
            // A full disk or a closed pipe throws: the line is lost, the app goes on.
            try? file?.write(contentsOf: data)
            if let url, let size = try? file?.offset(), size > Self.maxBytes {
                try? file?.close()
                let previous = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: url, to: previous)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                file = try? FileHandle(forWritingTo: url)
            }
        }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    /// Local wall-clock time with milliseconds, e.g. "03:41:07.218".
    static func timestamp() -> String {
        var now = timeval()
        gettimeofday(&now, nil)
        var seconds = now.tv_sec
        var parts = tm()
        localtime_r(&seconds, &parts)
        return String(format: "%02d:%02d:%02d.%03d", parts.tm_hour, parts.tm_min, parts.tm_sec, now.tv_usec / 1000)
    }
}

nonisolated func log(_ message: String) {
    AppLog.shared.write(message)
}

/// Milliseconds from `start` to `end` (default: now), for log lines.
nonisolated func ms(since start: Date, until end: Date = Date()) -> String {
    String(format: "%.0f ms", end.timeIntervalSince(start) * 1000)
}
