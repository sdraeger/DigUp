import Foundation
import Testing
@testable import DigUpKit

/// Questions: what makes one, the passages they're answered from, and the citations read back.
@Suite final class QuestionTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func questionsPromptsAndCitations() {
        #expect(Question.isQuestion("when does my lease end? "))
        #expect(!Question.isQuestion("lease end date"))
        let prompt = Question.prompt("When does my lease end?", sources: [
            .init(title: "lease.pdf, page 1", text: "The lease ends on May 31."),
            .init(title: "notes.md", text: "Rent."),
        ])
        #expect(prompt == "Question: When does my lease end?\n\nSources:\n\n"
                + "[1] lease.pdf, page 1: The lease ends on May 31.\n\n[2] notes.md: Rent.")
        #expect(Question.citations(in: "It ends May 31 [2], says the lease [1][2]; see [7].", count: 2) == [1, 0])
    }

    @Test func longPassagesAreCutAroundTheirWords() {
        let page = String(repeating: "Rent is due monthly. ", count: 150) + "The LEASE ends on May 31. "
            + String(repeating: "Pets need a deposit. ", count: 150)
        let passage = Question.passage(page, terms: ["lease", "ends"])
        #expect(passage.count <= Question.passageLimit + 2)
        #expect(passage.contains("The LEASE ends on May 31.") && passage.hasPrefix("…") && passage.hasSuffix("…"))
        #expect(Question.passage("  short \n text ", terms: []) == "short text")
    }

    @Test func passagesComeFromTheMatchOrItsFile() throws {
        let store = try IndexStore(directory: folder)
        let shot = try store.insert(Candidate(path: "/x/shot.png", kind: .screenshot, size: 1, mtime: 1, inode: 1,
                                              device: 1))
        try store.addSegment(file: shot, kind: .image, modality: .image, vector: [Float](repeating: 0.036, count: 768))
        try store.addSegment(file: shot, kind: .ocr, modality: .none, text: "Payment failed: card declined")
        let pdf = try store.insert(Candidate(path: "/x/lease.pdf", kind: .pdf, size: 1, mtime: 1, inode: 2, device: 1))
        try store.addSegment(file: pdf, kind: .page, modality: .text, loc: 1, text: "Page one")
        try store.addSegment(file: pdf, kind: .page, modality: .text, loc: 2, text: "The lease ends on May 31.")
        let searcher = try Searcher(store: store, loadVectors: false)
        var ids: [Int64] = []
        try store.db.query("SELECT id FROM segments WHERE kind IN ('image', 'page') ORDER BY id") {
            ids.append($0.int(0))
        }
        #expect(try searcher.passage(near: ids[0]) == "Payment failed: card declined")   // the picture: its words
        #expect(try searcher.passage(near: ids[2]) == "The lease ends on May 31.")       // page 2 itself
    }
}
