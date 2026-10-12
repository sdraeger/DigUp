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
