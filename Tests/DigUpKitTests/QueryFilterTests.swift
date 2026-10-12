import Foundation
import Testing
@testable import DigUpKit

/// Plain-language filters: what's taken out of a query as dates, kinds and "duplicates", and what's left to search.
@Suite struct QueryFilterTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Sunday, October 11, 2026, 15:00 UTC
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15))! }

    func filter(_ query: String) -> QueryFilter { QueryFilter(query, now: now, calendar: calendar) }

    func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func datesKindsAndWhatsLeft() {
        let lease = filter("PDFs from March about the lease")
        #expect(lease.text == "about the lease")
        #expect(lease.kinds == [.pdf])
        #expect(lease.dates == DateInterval(start: day(2026, 3, 1), end: day(2026, 4, 1)))
        #expect(!lease.isListing)

        let summer = filter("photos from last summer")
        #expect(summer.text.isEmpty && summer.isListing)
        #expect(summer.kinds == [.image])
        #expect(summer.dates == DateInterval(start: day(2026, 6, 1), end: day(2026, 9, 1)))

        #expect(filter("my screenshots from yesterday").dates == DateInterval(start: day(2026, 10, 10),
                                                                               end: day(2026, 10, 11)))
        #expect(filter("videos taken in 2024").dates == DateInterval(start: day(2024, 1, 1), end: day(2025, 1, 1)))
        #expect(filter("notes since September").dates == DateInterval(start: day(2026, 9, 1), end: now))
        #expect(filter("photos before 2020").dates == DateInterval(start: .distantPast, end: day(2020, 1, 1)))
        #expect(filter("receipt last month").dates == DateInterval(start: day(2026, 9, 1), end: day(2026, 10, 1)))
        #expect(filter("receipt last month").text == "receipt")
        let slides = filter("slides from the last 3 days")
        #expect(slides.text == "slides")
        #expect(slides.dates == DateInterval(start: day(2026, 10, 8).addingTimeInterval(15 * 3600), end: now))
        #expect(filter("whiteboard 2 weeks ago").dates?.start == day(2026, 9, 27))   // that week, from Sunday
        #expect(filter("invoice on Friday").dates == DateInterval(start: day(2026, 10, 9), end: day(2026, 10, 10)))
        #expect(filter("receipt March 3").dates == DateInterval(start: day(2026, 3, 3), end: day(2026, 3, 4)))
        #expect(filter("trip from December").dates?.start == day(2025, 12, 1))   // the latest that has begun
        #expect(filter("ski trip winter 2025").dates == DateInterval(start: day(2024, 12, 1), end: day(2025, 3, 1)))
    }

    @Test func wordsThatOnlyLookLikeDatesStay() {
        for query in ["tax return 2023", "march for science", "notes on March Madness", "may the force",
                      "the last supper", "screenshot of the error"] {
            let parsed = filter(query)
            #expect(parsed.text == query && parsed.dates == nil && parsed.kinds == nil, "\(query)")
        }
        #expect(filter("video call with grandma").kinds == nil)   // a kind word with more to search: a hint
        #expect(filter("screenshots").kinds == [.screenshot] && filter("screenshots").isListing)
        #expect(filter("from yesterday").isListing && filter("from yesterday").kinds == nil)
    }

    @Test func duplicates() {
        let photos = filter("duplicate photos")
        #expect(photos.duplicates && photos.kinds == [.image] && photos.text.isEmpty && !photos.isListing)
        let lease = filter("copies of the lease")
        #expect(lease.duplicates && lease.text == "the lease" && lease.kinds == nil)
        let near = filter("near duplicates from 2025")
        #expect(near.duplicates && near.text.isEmpty && near.dates?.start == day(2025, 1, 1))
    }
}

/// What a filter does to search: dates and kinds narrow it, a query that's all filter lists files newest first, and
/// "duplicates" finds the files whose vectors are nearly the same.
@Suite final class ListingAndDuplicatesTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A unit vector from a seed; `toward`/`weight` mix in another, for vectors that are close but not the same.
    func vector(_ seed: UInt64, toward other: UInt64? = nil, weight: Float = 0) -> [Float] {
        func raw(_ seed: UInt64) -> [Float] {
            var state = seed &* 6364136223846793005 &+ 1442695040888963407
            return (0..<Vectors.dimension).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
            }
        }
        var v = raw(seed)
        if let other { v = zip(v, raw(other)).map { (1 - weight) * $0 + weight * $1 } }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }

    @Test func filtersListingsAndDuplicates() throws {
        let store = try IndexStore(directory: folder)
        let now = Date().timeIntervalSince1970
        var inode: UInt64 = 0
        func add(_ name: String, _ kind: FileKind, _ vector: [Float], size: Int64 = 100, mtime: Double? = nil,
                 taken: String? = nil) throws {
            inode += 1
            let id = try store.insert(Candidate(path: "/x/\(name)", kind: kind, size: size, mtime: mtime ?? now,
                                                inode: inode, device: 1))
            try store.addSegment(file: id, kind: kind == .pdf ? .page : .image, modality: kind == .pdf ? .text : .image,
                                 vector: vector)
            try store.finish(id, state: "done", info: taken.map { ["taken": $0] } ?? [:])
        }
        try add("beach.jpg", .image, vector(1), size: 3_000, taken: "2025:07:14 10:03:22")
        try add("beach small.jpg", .image, vector(1, toward: 9, weight: 0.05), size: 800)        // resized: a near copy
        try add("Screenshot beach.png", .screenshot, vector(1, toward: 8, weight: 0.08), size: 900)  // and a capture of it
        try add("forest.jpg", .image, vector(2), taken: "2025:08:02 18:00:00")
        try add("lease.pdf", .pdf, vector(3), size: 5_000, mtime: now - 86_400)
        try add("lease copy.pdf", .pdf, vector(3), size: 5_000)
        try add("lease.png", .image, vector(3))     // the same vector, but a picture is no copy of a PDF
        try add("tiny.png", .image, vector(4))
        try store.db.run("UPDATE files SET state = 'skipped' WHERE path = '/x/tiny.png'")
        let searcher = try Searcher(store: store)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let summer = DateInterval(start: calendar.date(from: DateComponents(year: 2025, month: 6, day: 1))!,
                                  end: calendar.date(from: DateComponents(year: 2025, month: 9, day: 1))!)
        #expect(try searcher.listing(kinds: [.image], dates: summer).map(\.path) == ["/x/forest.jpg", "/x/beach.jpg"])
        #expect(try searcher.listing(kinds: [.pdf], dates: nil).map(\.path) == ["/x/lease copy.pdf", "/x/lease.pdf"])
        #expect(try !searcher.listing(kinds: nil, dates: nil, limit: 100).map(\.path).contains("/x/tiny.png"))
        #expect(try searcher.search("", queryVector: vector(1), dates: summer, zGate: -10).map(\.path)
                == ["/x/beach.jpg", "/x/forest.jpg"])

        let sets = try searcher.duplicates(kinds: nil, dates: nil).map { $0.map(\.path) }
        // The most room taken twice first; each oldest first (a photo by when it was taken).
        #expect(sets == [["/x/lease.pdf", "/x/lease copy.pdf"],
                         ["/x/beach.jpg", "/x/beach small.jpg", "/x/Screenshot beach.png"]])
        #expect(try searcher.duplicates(kinds: [.pdf], dates: nil).count == 1)
        #expect(try searcher.duplicates(kinds: nil, dates: nil, among: ["/x/beach.jpg", "/x/forest.jpg"]).isEmpty)
    }
}
