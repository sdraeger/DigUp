import Foundation
import Testing
@testable import DigUpKit

@Suite final class RelevantChangesTests {
    let root: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        for folder in ["proj", "Some.app/Contents", "Excluded/Kept"] {
            try? FileManager.default.createDirectory(at: url.appendingPathComponent(folder),
                                                     withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: url.appendingPathComponent("proj/package.json").path, contents: nil)
        return FolderSelection.realPath(url.path)   // /private/var/…, as FSEvents reports it
    }()

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func kept(_ paths: [String], folders: Set<String> = [], roots: [String]? = nil,
              excluded: [String] = []) -> [String] {
        var options = IndexOptions()
        options.excludedFolders = excluded.map { root + "/" + $0 }
        let changes = paths.map { (path: root + "/" + $0, isFolder: folders.contains($0)) }
        return Crawler.relevant(changes, roots: roots ?? [root], options: options)
            .map { String($0.dropFirst(root.count + 1)) }
    }

    @Test func onlyFilesTheCrawlWouldIndex() {
        #expect(kept(["a.pdf", "notes.json", "Set.db-shm", ".DS_Store", "photo.png"]) == ["a.pdf", "photo.png"])
    }

    @Test func notInFoldersTheCrawlSkips() {
        #expect(kept(["node_modules/x.png", "old.noindex/a.pdf", ".hidden/a.pdf", "Some.app/Contents/x.png",
                      "Excluded/a.pdf"], excluded: ["Excluded"]).isEmpty)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(Crawler.relevant([(home + "/Library/Caches/x.png", false)], roots: [home], options: IndexOptions())
            .isEmpty)
    }

    @Test func aChosenFolderInsideAnExcludedOneCounts() {
        #expect(kept(["Excluded/a.pdf", "Excluded/Kept/a.pdf"], roots: [root, root + "/Excluded/Kept"],
                     excluded: ["Excluded"]) == ["Excluded/Kept/a.pdf"])
    }

    @Test func onlyPicturesInsideACodeProject() {
        #expect(kept(["proj/README.md", "proj/docs/guide.pdf", "proj/shot.png"]) == ["proj/shot.png"])
    }

    @Test func foldersCountUnlessSkipped() {
        let folders: Set = ["Moved in", "node_modules", "proj/src", "proj"]
        #expect(kept(["Moved in", "node_modules", "proj/src", "proj"], folders: folders) == ["Moved in", "proj"])
    }

    @Test func changesOutsideTheRootsAreKept() {
        #expect(Crawler.relevant([("/elsewhere/a.json", false)], roots: [root], options: IndexOptions()).count == 1)
    }
}
