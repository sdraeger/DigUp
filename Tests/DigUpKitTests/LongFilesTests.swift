import Foundation
import Testing
@testable import DigUpKit

/// Long PDFs and documents: the first step in the first pass, the rest in `finishLongFiles`, and what goes with it.
@Suite final class LongFilesTests {
    /// In Caches, not the temporary folder: syncing a folder twice needs a path that the crawl reports as it's given,
    /// and the walk reports /private/var/… for /var/… (which no chosen folder in the app is under).
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    var files: URL { folder.appendingPathComponent("files") }

    func indexer(_ store: IndexStore, _ embedder: FakeEmbedder, options: IndexOptions = IndexOptions()) throws -> Indexer {
        try Indexer(store: store, options: options, makeEmbedder: { embedder })
    }

    func store() throws -> IndexStore { try IndexStore(directory: folder.appendingPathComponent("index")) }

    /// Pages (from 1) of a file's segments of `kinds`, in order.
    func places(_ store: IndexStore, _ path: String, kinds: [String] = ["page", "page_image", "chunk"]) throws -> [Int] {
        var out: [Int] = []
        try store.db.query("""
            SELECT s.loc FROM segments s JOIN files f ON f.id = s.file
            WHERE f.path = ? AND s.kind IN (\(kinds.map { "'\($0)'" }.joined(separator: ","))) ORDER BY s.loc
            """, [.text(path)]) { out.append(Int($0.double(0))) }
        return out
    }

    func state(_ store: IndexStore, _ path: String) throws -> (state: String, info: [String: String]) {
        var result = ("", [String: String]())
        try store.db.query("SELECT id, state FROM files WHERE path = ?", [.text(path)]) { row in
            result = (row.text(1) ?? "", (try? store.info(of: row.int(0))) ?? [:])
        }
        return result
    }

    /// Where keyword search finds `word`: the page or chunk numbers.
    func found(_ store: IndexStore, _ word: String) throws -> [Int] {
        var out: [Int] = []
        try store.db.query("SELECT s.loc FROM fts JOIN segments s ON s.id = fts.rowid WHERE fts MATCH ? ORDER BY s.loc",
                           [.text("\"\(word)\"")]) { out.append(Int($0.double(0))) }
        return out
    }

    /// Files are saved a second's worth at a time (`Indexer.process`): a stop saves the ones done before it, where
    /// another connection (the app's) sees them.
    @Test func aStopSavesWhatWasDone() throws {
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for number in 1...6 {
            try "Note \(number) about otters and their dens.".write(to: files.appendingPathComponent("note\(number).txt"),
                                                                    atomically: true, encoding: .utf8)
        }
        let store = try store()
        let indexer = try indexer(store, FakeEmbedder())
        _ = try indexer.sync([files])
        let app = try IndexStore(directory: folder.appendingPathComponent("index"))
        var events = 0
        _ = try indexer.run(shouldStop: { events >= 3 }) { _ in events += 1 }
        #expect(events == 3)
        #expect(try found(app, "otters").count == 3)
        #expect(try store.pending(limit: nil, only: nil).count == 3)
        _ = try indexer.run()
        #expect(try store.pending(limit: nil, only: nil).isEmpty)
        #expect(try found(app, "otters").count == 6)
    }

    /// A run that crashed going carefully left the file it was on in its marker (`Indexer.recoverFromCrash`): the next
    /// run sets that file aside and reads the rest, and leaves no marker behind.
    @Test func theFileACrashedRunWasOnIsSetAside() throws {
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] {
            try "Notes \(name) about otters.".write(to: files.appendingPathComponent("\(name).txt"), atomically: true,
                                                   encoding: .utf8)
        }
        let store = try store()
        let indexer = try indexer(store, FakeEmbedder())
        _ = try indexer.sync([files])
        let culprit = try store.pending(limit: nil).first { $0.path.hasSuffix("b.txt") }!
        try "99999999 \(culprit.id):doc:".write(to: indexer.inflight, atomically: true, encoding: .utf8)
        let states = try indexer.run()
        #expect(states == ["done": 2])
        #expect(try state(store, culprit.path).state == "failed")
        #expect(!FileManager.default.fileExists(atPath: indexer.inflight.path))
    }

    @Test func aLongFileACrashedRunWasOnKeepsWhatItRead() throws {
        let pdf = try makePDF("Book.pdf", pages: 100)
        let store = try store()
        let indexer = try indexer(store, FakeEmbedder())
        _ = try indexer.sync([files])
        try indexer.run()   // pages 1–30
        let id = try store.unfinished()[0].id
        try "99999999 \(id):pdf:30".write(to: indexer.inflight, atomically: true, encoding: .utf8)
        try indexer.finishLongFiles()
        #expect(try places(store, pdf.path) == Array(1...30))
        #expect(try state(store, pdf.path).state == "done")
    }

    /// A folder given by a path the walk reports otherwise (/var is /private/var, letters typed in another case) syncs
    /// again without taking its files for new ones.
    @Test func aFolderGivenAnotherWayStillSyncs() throws {
        let given = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: given) }
        let notes = given.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "Otters.".write(to: notes.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let indexer = try indexer(try store(), FakeEmbedder())
        #expect(notes.path.hasPrefix("/var/"))   // the walk says /private/var
        #expect(try indexer.sync([notes]).added == 1)
        let again = try indexer.sync([given.appendingPathComponent("NOTES")])
        #expect(again.added == 0 && again.removed == 0 && again.unchanged == 1)
    }

    /// A screenshot told by its name stays one when renamed: not embedded again as a picture.
    @Test func aRenamedScreenshotIsNotEmbeddedAgain() throws {
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let shot = files.appendingPathComponent("Screenshot 2026-10-11 at 10.00.00.png")
        try Data(repeating: 0, count: 100).write(to: shot)
        let indexer = try indexer(try store(), FakeEmbedder())
        #expect(try indexer.sync([files]).added == 1)
        try FileManager.default.moveItem(at: shot, to: files.appendingPathComponent("error dialog.png"))
        #expect(try indexer.sync([files]).moved == 1)
        let again = try indexer.sync([files])
        #expect(again.changed == 0 && again.unchanged == 1)
    }

    /// A file that changed moments ago (a document saving itself while it's open) waits for a later sync.
    @Test func aFileStillChangingWaits() throws {
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let note = files.appendingPathComponent("draft.txt")
        try "Otters.".write(to: note, atomically: true, encoding: .utf8)
        let indexer = try indexer(try store(), FakeEmbedder())
        indexer.settle = 30
        #expect(try indexer.sync([files]).added == 1)   // new files don't wait
        try "Otters and their dens.".write(to: note, atomically: true, encoding: .utf8)
        let now = try indexer.sync([files])
        #expect(now.changed == 0 && now.deferred == 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: note.path)
        let later = try indexer.sync([files])
        #expect(later.changed == 1 && later.deferred == 0)
    }

    /// A folder the walk can't read (macOS hasn't granted access yet, or took it back) keeps its rows: taking them for
    /// deleted would embed every file again once access is back.
    @Test func anUnreadableFolderKeepsItsFiles() throws {
        let locked = files.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "Field notes about otters.".write(to: files.appendingPathComponent("open.txt"), atomically: true, encoding: .utf8)
        try "Private notes about otters.".write(to: locked.appendingPathComponent("hidden.txt"), atomically: true,
                                               encoding: .utf8)
        let store = try store()
        let indexer = try indexer(store, FakeEmbedder())
        #expect(try indexer.sync([files]).added == 2)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let summary = try indexer.sync([files])
        #expect(summary.removed == 0)
        #expect(try store.files(under: [files.path]).count == 2)
    }

    @Test func longPDFIsReadInSteps() throws {
        let pdf = try makePDF("Field guide.pdf", pages: 120, special: [100: "quokka"])
        let store = try store()
        let embedder = FakeEmbedder()
        let indexer = try indexer(store, embedder)
        _ = try indexer.sync([files])
        #expect(try indexer.run()["partial"] == 1)
        #expect(try places(store, pdf.path) == Array(1...30))
        #expect(try state(store, pdf.path).state == "partial")
        #expect(try state(store, pdf.path).info["read_to"] == "30")
        #expect(try store.unfinishedCount() == (1, 90))
        #expect(try found(store, "quokka").isEmpty)

        var steps: [Indexer.Step] = []
        #expect(try indexer.finishLongFiles(onStep: { steps.append($0) }) == ["done": 1])
        #expect(steps.map(\.done) == [30, 60, 90])
        #expect(steps.map(\.total) == [90, 90, 90])
        #expect(steps.map(\.state) == ["partial", "partial", "done"])
        #expect(steps.map(\.files) == [1, 1, 0])
        #expect(try places(store, pdf.path) == Array(1...120))
        #expect(try found(store, "quokka") == [100])
        let (done, info) = try state(store, pdf.path)
        #expect(done == "done")
        #expect(info["read_to"] == nil && info["read_end"] == nil && info["pages"] == "120")
        #expect(try store.unfinishedCount() == (0, 0))
        #expect(try indexer.finishLongFiles().isEmpty)   // nothing left
        #expect(embedder.texts == 120)                    // every page embedded once
    }

    @Test func stoppingBetweenStepsLosesNothing() throws {
        let pdf = try makePDF("Book.pdf", pages: 100)
        let store = try store()
        let indexer = try indexer(store, FakeEmbedder())
        _ = try indexer.sync([files])
        try indexer.run()
        var steps = 0
        try indexer.finishLongFiles(shouldStop: { steps >= 1 }, onStep: { _ in steps += 1 })
        #expect(try state(store, pdf.path).info["read_to"] == "60")
        #expect(try store.unfinishedCount() == (1, 40))
        try indexer.finishLongFiles()
        #expect(try places(store, pdf.path) == Array(1...100))
        #expect(try state(store, pdf.path).state == "done")
    }

    @Test func aChangedFileStartsOver() throws {
        let pdf = try makePDF("Book.pdf", pages: 80)
        let store = try store()
        let indexer = try indexer(store, FakeEmbedder())
        _ = try indexer.sync([files])
        try indexer.run()
        try makePDF("Book.pdf", pages: 90)   // a new edition, same name
        #expect(try indexer.sync([files]).changed == 1)
        #expect(try state(store, pdf.path).state == "pending")
        #expect(try places(store, pdf.path).isEmpty)
        try indexer.run()
        try indexer.finishLongFiles()
        #expect(try places(store, pdf.path) == Array(1...90))
    }

    @Test func longDocumentGoesOnWhereItStopped() throws {
        let text = prose(characters: 150_000, special: (at: 120_000, word: "axolotl"))
        let url = files.appendingPathComponent("Notes.txt")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
        let chunks = DocExtractor.chunks(text, limit: 10_000)
        #expect(chunks.count > 80)
        let store = try store()
        let indexer = try indexer(store, FakeEmbedder())
        _ = try indexer.sync([files])
        try indexer.run()
        #expect(try places(store, url.path) == Array(1...40))
        #expect(try state(store, url.path).info["read_end"] == "\(chunks.count)")
        #expect(try found(store, "axolotl").isEmpty)
        try indexer.finishLongFiles()
        #expect(try places(store, url.path) == Array(1...chunks.count))
        // The same chunks as one pass would cut, none twice: what the later steps added fits on.
        var stored: [String] = []
        try store.db.query("""
            SELECT coalesce(fts.original, fts.body) FROM fts JOIN segments s ON s.id = fts.rowid
            WHERE s.kind = 'chunk' ORDER BY s.loc
            """) { stored.append($0.text(0) ?? "") }
        #expect(stored == chunks)
        let places = try found(store, "axolotl")   // in one chunk, or two where they overlap
        #expect(!places.isEmpty && places.allSatisfy { $0 > 40 })
        #expect(try state(store, url.path).state == "done")
    }

    @Test func digitsGetKeywordSearchOnly() throws {
        var dump = ""
        for row in 0..<4_000 { dump += "\(row) \(row * 7919 % 100_003) \(row * 31 % 977)\n" }
        dump += "4815162342\n"
        let url = files.appendingPathComponent("sensor log.txt")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try dump.write(to: url, atomically: false, encoding: .utf8)
        #expect(!SearchText.hasWords(dump))
        #expect(SearchText.hasWords("Revenue 1,234,567 · Net income 234,567 · Margin 19% in the third quarter"))
        #expect(SearchText.hasWords("কলকাতায় বৃষ্টি হচ্ছে"))
        let store = try store()
        let embedder = FakeEmbedder()
        let indexer = try indexer(store, embedder)
        _ = try indexer.sync([files])
        try indexer.run()
        try indexer.finishLongFiles()
        #expect(embedder.texts == 0)
        var vectors = -1
        try store.db.query("SELECT COUNT(vec) FROM segments") { vectors = Int($0.int(0)) }
        #expect(vectors == 0)
        #expect(try found(store, "4815162342").count == 1)
    }

    @Test func machineMadeGiantsStopAtTheCap() throws {
        let pdf = try makePDF("Export.pdf", pages: 120)
        var options = IndexOptions()
        options.maxPages = 45
        let store = try store()
        let indexer = try indexer(store, FakeEmbedder(), options: options)
        _ = try indexer.sync([files])
        try indexer.run()
        #expect(try store.unfinishedCount() == (1, 15))
        try indexer.finishLongFiles()
        #expect(try places(store, pdf.path) == Array(1...45))
        #expect(try state(store, pdf.path).state == "done")
        var detail: String?
        try store.db.query("SELECT detail FROM files") { detail = $0.text(0) }
        #expect(detail == "the first 45 of 120 pages")
    }

    @Test func oldIndexesFinishWhatTheyCut() throws {
        // As schema 4 left them: a long PDF read to page 30, a document cut at its 40th chunk, and a chunk of digits
        // with a vector.
        var store: IndexStore? = try self.store()
        try store!.insert(Candidate(path: "/books/atlas.pdf", kind: .pdf, size: 10, mtime: 1, inode: 1, device: 1))
        try store!.insert(Candidate(path: "/notes/long.txt", kind: .doc, size: 10, mtime: 1, inode: 2, device: 1))
        let short = try store!.insert(Candidate(path: "/notes/short.txt", kind: .doc, size: 10, mtime: 1, inode: 3,
                                                device: 1))
        let dump = try store!.insert(Candidate(path: "/data/dump.txt", kind: .doc, size: 10, mtime: 1, inode: 4,
                                               device: 1))
        try store!.addSegment(file: short, kind: .chunk, modality: .text, loc: 1, text: "Notes from the harbour meeting",
                              vector: FakeEmbedder.vector(for: "words"))
        try store!.addSegment(file: dump, kind: .chunk, modality: .text, loc: 1, text: "1760000000 4 9153\n1760000060 5 17",
                              vector: FakeEmbedder.vector(for: "digits"))
        try store!.db.execute("""
            UPDATE files SET state = 'partial', info = '{"pages":"463","scanned_pages":"4"}' WHERE path = '/books/atlas.pdf';
            UPDATE files SET state = 'done', info = '{"chars":"100000","chunks":"40"}' WHERE path = '/notes/long.txt';
            UPDATE files SET state = 'done', info = '{"chars":"3000","chunks":"2"}' WHERE path = '/notes/short.txt';
            UPDATE files SET state = 'done', info = '{"chars":"30","chunks":"1"}' WHERE path = '/data/dump.txt';
            PRAGMA user_version = 4;
            """)
        store = nil
        let migrated = try self.store()
        #expect(try state(migrated, "/books/atlas.pdf").state == "partial")
        #expect(try state(migrated, "/books/atlas.pdf").info == ["pages": "463", "scanned_pages": "4", "read_to": "30",
                                                                 "read_end": "463"])
        #expect(try state(migrated, "/notes/long.txt").state == "partial")
        #expect(try state(migrated, "/notes/long.txt").info["read_to"] == "40")
        #expect(try state(migrated, "/notes/long.txt").info["read_end"] == "63")   // 100,000 characters / 1,600
        #expect(try state(migrated, "/notes/short.txt").state == "done")
        #expect(try migrated.unfinishedCount() == (2, 433 + 23))
        var vectors: [String] = []
        try migrated.db.query("SELECT f.path FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL") {
            vectors.append($0.text(0) ?? "")
        }
        #expect(vectors == ["/notes/short.txt"])   // the digits' vector went, the words' stayed
        #expect(try found(migrated, "9153") == [1])   // still found by keyword search
    }

    @Test func estimatesCountTheRest() throws {
        let book = try makePDF("Book.pdf", pages: 120)
        let short = try makePDF("Leaflet.pdf", pages: 3)
        let candidates = [book, short].map {
            Candidate(path: $0.path, kind: .pdf, size: 10, mtime: 1, inode: 1, device: 1)
        }
        let costs = Costs()
        let estimate = Estimator.estimate(candidates, options: IndexOptions(), costs: costs)
        #expect(estimate.pdfPages == 33)
        #expect(estimate.pdfPagesTotal == 123)
        #expect(estimate.longFiles == 1)
        #expect(abs(estimate.seconds - 33 * costs.pdfPage) < 1e-9)
        #expect(abs(estimate.laterSeconds - 90 * costs.pdfPage) < 1e-9)
    }

    @Test func float16VectorsScoreAcrossBlocks() throws {
        // More vectors than one block (`VectorStorage.blockRows`): every one must be scored, the last ones too.
        let store = try store()
        let rows = VectorStorage.blockRows * 2 + 300
        var target: [Float] = []
        try store.db.transaction {
            for index in 0..<rows {
                let id = try store.insert(Candidate(path: "/v/\(index).png", kind: .image, size: 1, mtime: 1,
                                                    inode: UInt64(index + 1), device: 1))
                let vector = FakeEmbedder.vector(for: "\(index)")
                if index == rows - 5 { target = vector }
                try store.addSegment(file: id, kind: .image, modality: .image, vector: vector)
            }
        }
        let searcher = try Searcher(store: store)
        #expect(searcher.vectorCount == rows)
        let hits = try searcher.search("", queryVector: target, limit: 3)
        #expect(hits.first?.path == "/v/\(rows - 5).png")
        #expect(abs((hits.first?.cosine ?? 0) - 1) < 0.002)   // float16 rounding only
    }

    #if canImport(Vision)
    @Test func aScannedPagesWordsAreFoundByKeywordSearch() throws {
        // A page that's only a picture of its text, as a scanner or a phone makes it: no text layer at all.
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try ScannedPDF.write("Invoice QXTEST87231. Payment due Friday.", to: files.appendingPathComponent("scan.pdf"))
        let store = try store()
        let indexer = try indexer(store, FakeEmbedder())
        _ = try indexer.sync([files])
        _ = try indexer.run()
        #expect(try found(store, "qxtest87231") == [1])   // OCR's words, for keyword search; its meaning stays the picture's
        var kinds: [String] = []
        try store.db.query("SELECT kind FROM segments WHERE kind != 'name'") { kinds.append($0.text(0) ?? "") }
        #expect(kinds == ["page_image"])

        // An index made before scans had words reads them once more, and only once.
        try store.setMeta("scans_ocr", nil)
        #expect(try store.readAgainOnce() == 1)
        #expect(try store.pendingCount() == 1)
        #expect(try store.readAgainOnce() == 0)
    }
    #endif

    // MARK: Files

    /// A text PDF with `pages` pages of a few sentences each; `special` puts a word on a page (from 1).
    @discardableResult
    func makePDF(_ name: String, pages: Int, special: [Int: String] = [:]) throws -> URL {
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let url = files.appendingPathComponent(name)
        try TextPDF.write((1...pages).map {
            "Page \($0). " + prose(characters: 600, seed: $0) + (special[$0].map { " The \($0) lives here." } ?? "")
        }, to: url)
        return url
    }

    /// Plain English-looking sentences, the same for the same seed; `special`'s word goes in once, past `at`.
    func prose(characters: Int, seed: Int = 1, special: (at: Int, word: String)? = nil) -> String {
        let words = ["river", "garden", "morning", "letter", "window", "harbour", "kitchen", "mountain", "station",
                     "market", "evening", "bridge", "orchard", "lantern", "meadow", "village", "library", "summer"]
        var pieces: [String] = [], count = 0, index = seed, placed = special == nil
        while count < characters {
            index = (index &* 1103515245 &+ 12345) & 0x7fffffff
            var piece = words[index % words.count] + (index % 7 == 0 ? "." : "")
            if !placed, let special, count >= special.at {
                piece = "the \(special.word) swims. " + piece
                placed = true
            }
            pieces.append(piece)
            count += piece.count + 1
        }
        return pieces.joined(separator: " ")
    }
}
