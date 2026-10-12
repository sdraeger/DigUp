#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import DigUpKit

/// Searching by example: `like:` queries, the vector they go by, and files that aren't indexed.
@Suite final class LikeTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func likeQueries() {
        #expect(LikeQuery.path(of: "like: ~/Pictures/a beach.jpg") == NSHomeDirectory() + "/Pictures/a beach.jpg")
        #expect(LikeQuery.path(of: "  Like:/tmp/x.pdf ") == "/tmp/x.pdf")
        #expect(LikeQuery.path(of: "like:") == nil)
        #expect(LikeQuery.path(of: "likely otters") == nil)
        #expect(LikeQuery.query(NSHomeDirectory() + "/Notes/a.txt") == "like: ~/Notes/a.txt")
        #expect(LikeQuery.path(of: LikeQuery.query("/tmp/x.pdf")) == "/tmp/x.pdf")
    }

    @Test func pathsBeingTypedCompleteToTheNewestFitting() {
        let day: TimeInterval = 86_400
        let entries: [LikeQuery.Entry] = [
            .init(name: "Receipts", isFolder: true, modified: Date(timeIntervalSince1970: 3 * day)),
            .init(name: "receipt-may.pdf", isFolder: false, modified: Date(timeIntervalSince1970: 2 * day)),
            .init(name: "receipt-june.pdf", isFolder: false, modified: Date(timeIntervalSince1970: 4 * day)),
            .init(name: "recorder.zip", isFolder: false, modified: Date(timeIntervalSince1970: 9 * day)),  // not read
            .init(name: ".recent", isFolder: true, modified: Date(timeIntervalSince1970: 9 * day)),       // hidden
        ]
        var listed: [String] = []
        let complete = { (query: String) in
            LikeQuery.completion(of: query) { folder in
                listed.append(folder)
                return entries
            }
        }
        #expect(complete("like: ~/Downloads/REC") == "like: ~/Downloads/receipt-june.pdf")
        #expect(listed == [NSHomeDirectory() + "/Downloads"])
        #expect(complete("like:/tmp/receipt-m") == "like:/tmp/receipt-may.pdf")
        #expect(complete("like: /tmp/receipts") == "like: /tmp/Receipts/")   // a folder named in full: go on in it
        #expect(complete("like: /tmp/receipt-may.pdf") == nil)              // whole
        #expect(complete("like: /tmp/.rec") == "like: /tmp/.recent/")
        #expect(complete("like: /tmp/zzz") == nil)
        #expect(complete("like: ~") == "like: ~/")
        #expect(complete("like: ") == nil)
        #expect(complete("like otters") == nil)
        #expect(complete("receipts") == nil)
    }

    @Test func aFileIsMostLikeItself() throws {
        let files = folder.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for name in ["otters", "ledger", "recipe", "garden"] {
            try "All about \(name), and nothing else at all.".write(to: files.appendingPathComponent("\(name).txt"),
                                                                    atomically: true, encoding: .utf8)
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([files])
        _ = try indexer.run()
        let searcher = try Searcher(store: store)
        let path = FolderSelection.realPath(files.appendingPathComponent("ledger.txt").path)
        let vector = try #require(try searcher.vector(likeFile: path))
        #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3)
        #expect(try searcher.search("", queryVector: vector, zGate: -10).first?.path == path)
        var segment: Int64 = 0
        try store.db.query("SELECT s.id FROM segments s JOIN files f ON f.id = s.file WHERE f.path = ? "
                           + "AND s.vec IS NOT NULL", [.text(path)]) { segment = $0.int(0) }
        #expect(try searcher.vector(likeFile: "/elsewhere", segment: segment) == vector)   // a one-segment file
        #expect(try searcher.vector(likeFile: "/not/indexed.txt") == nil)
    }

    @Test func filesNotInTheIndexAreReadLikeIndexingReadsThem() throws {
        let note = folder.appendingPathComponent("Field notes.txt")
        try "Otters build dens along the river.".write(to: note, atomically: true, encoding: .utf8)
        guard case .text(let text) = try Example.prepare(note) else { Issue.record("a note is text"); return }
        #expect(text == Prompts.document(title: "Field notes", text: "Otters build dens along the river."))

        let archive = folder.appendingPathComponent("old.zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
        #expect(try Example.prepare(archive) == nil)

        #if canImport(CoreGraphics)   // macOS keeps a prepared picture in memory
        let photo = folder.appendingPathComponent("river.png")
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        try ImageExtractor.encode(context.makeImage()!, png: true).write(to: photo)
        guard case .image(.bytes, let budget) = try Example.prepare(photo) else {
            Issue.record("a picture is an image, in memory")
            return
        }
        #expect(budget == IndexOptions().photoBudget)
        #endif
    }
}
