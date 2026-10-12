import Foundation

/// A file to search by (`LikeQuery`) that isn't in the index: the start of what indexing reads of it, ready for the
/// model. Its picture (a photo, a screenshot, a video's first frame, a PDF's first page when it's a scan), its first
/// 30 s of sound, or its opening text, prepared and titled the way indexing does it, so it compares like an indexed
/// file would.
public enum Example: Sendable {
    case text(String)
    case image(MediaInput, budget: Int)
    case audio(MediaInput)

    /// Nil for a file indexing doesn't read (code outside code search, an archive…) or one with nothing to read.
    public static func prepare(_ url: URL, options: IndexOptions = IndexOptions()) throws -> Example? {
        let values = try? url.resourceValues(forKeys: Set(FileSystem.crawlKeys))
        guard case .index(let kind) = Rules.classify(url, values: values, options: options) else { return nil }
        let title = url.deletingPathExtension().lastPathComponent
        // One piece, kept in memory whatever its size.
        let sink = MediaSink(folder: FileManager.default.temporaryDirectory, budget: .max)
        switch kind {
        case .image, .screenshot:
            let screenshot = kind == .screenshot
            let image = try ImageExtractor.prepare(url, maxPixel: screenshot ? 1536 : 1024, minSide: 0, into: sink,
                                                   png: screenshot)
            return .image(image.input, budget: screenshot ? options.screenshotBudget : options.photoBudget)
        case .pdf:
            let read = try PDFExtractor.pages(of: url, range: { _ in 0..<1 }, minText: options.minPageText,
                                              renderPixels: 1400, into: sink)
            guard let page = read.pages.first else { return nil }
            if let image = page.image { return .image(image, budget: options.pageBudget) }
            return .text(Prompts.document(title: read.title ?? title, text: String(page.text.prefix(4000))))
        case .doc:
            let text = try DocExtractor.text(of: url)
            return DocExtractor.chunks(text, limit: 1).first.map { .text(Prompts.document(title: title, text: $0)) }
        case .audio:
            let (window, hop) = (options.audioWindow, options.audioHop)
            let pieces = try runBlocking {
                try await AudioExtractor.windows(of: url, window: window, hop: hop, into: sink, limit: 1)
            }.pieces
            return pieces.first.map { .audio($0.input) }
        case .video:
            let interval = options.frameInterval
            let frames = try runBlocking {
                try await VideoExtractor.keyframes(of: url, every: interval, maxPixel: 1024, maxFrames: 1, into: sink)
            }.frames
            return frames.first.map { .image($0.input, budget: options.frameBudget) }
        default:
            return nil
        }
    }
}

extension LikeQuery {
    /// A file or folder in the folder a path is being typed in.
    public struct Entry: Sendable {
        public let name: String
        public let isFolder: Bool
        public let modified: Date

        public init(name: String, isFolder: Bool, modified: Date) {
            self.name = name
            self.isFolder = isFolder
            self.modified = modified
        }
    }

    /// The query with the path being typed after "like:" completed, as fish suggests commands: to the newest file
    /// DigUp can search by, or folder to go on in, whose name starts with what's typed of the last part ("like:
    /// ~/Downloads/rec" → "like: ~/Downloads/receipt.pdf", its name as it's written). Nil when nothing fits or the
    /// path is whole. `entries` lists a folder.
    public static func completion(of query: String, entries: (String) -> [Entry]) -> String? {
        guard isLike(query) else { return nil }
        let path = query.drop { $0.isWhitespace }.dropFirst(prefix.count).drop { $0 == " " }
        if path == "~" { return query + "/" }
        guard path.hasPrefix("/") || path.hasPrefix("~/"), let slash = path.lastIndex(of: "/") else { return nil }
        let folder = (String(path[...slash]) as NSString).expandingTildeInPath
        let typed = path[path.index(after: slash)...]
        let start = typed.lowercased()
        let options = IndexOptions()
        let entry = entries(folder).filter { entry in
            let name = entry.name.lowercased()
            return name.hasPrefix(start) && (name != start || entry.isFolder)
                && (!name.hasPrefix(".") || start.hasPrefix("."))
        }.sorted { $0.modified > $1.modified }.first { entry in
            guard !entry.isFolder else { return true }
            let url = URL(fileURLWithPath: folder).appendingPathComponent(entry.name)
            if case .index = Rules.classify(byName: url, options: options) {
                return true
            }
            return false
        }
        return entry.map { String(query.dropLast(typed.count)) + $0.name + ($0.isFolder ? "/" : "") }
    }

    /// What's in a folder for `completion`: its folders (apps and bundles count as files) and files.
    public static func entries(in folder: String) -> [Entry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder),
                                                                includingPropertiesForKeys: Array(keys))) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return Entry(name: url.lastPathComponent, isFolder: values?.isDirectory == true && values?.isPackage != true,
                         modified: values?.contentModificationDate ?? .distantPast)
        }
    }
}
