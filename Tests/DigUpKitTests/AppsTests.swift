import Foundation
import Testing
@testable import DigUpKit

@Suite struct AppsTests {
    let apps = ["Visual Studio Code", "Notes", "Notability", "Numbers", "zoom.us", "Café"].map {
        InstalledApp(path: "/Applications/\($0).app", name: $0, category: nil)
    }

    @Test func findsByTheStartOfTheNameOrOfAWord() {
        #expect(Apps.named("not", in: apps).map(\.name) == ["Notes", "Notability"])   // shorter first
        #expect(Apps.named("code", in: apps).map(\.name) == ["Visual Studio Code"])
        #expect(Apps.named("studio co", in: apps).map(\.name) == ["Visual Studio Code"])
        #expect(Apps.named("us", in: apps).map(\.name) == ["zoom.us"])
        #expect(Apps.named("CAFE", in: apps).map(\.name) == ["Café"])
        #expect(Apps.named("otes", in: apps).isEmpty)   // not inside a word
        #expect(Apps.named("notes about sleep", in: apps).isEmpty)
        #expect(Apps.named(" ", in: apps).isEmpty)
    }

    @Test func findsByWhatItsForOnlyWhenItStandsOut() {
        // Twenty apps far from the query, one close to it.
        let vectors = (0..<20).map { [Float(0.1 * Double($0 % 3)), 1] } + [[1, 0]]
        let many = (0...20).map { InstalledApp(path: "/A/\($0).app", name: "\($0)", category: nil) }
        #expect(Apps.meant([1, 0], apps: many, vectors: vectors).map(\.name) == ["20"])
        #expect(Apps.meant([0, 1], apps: many, vectors: vectors).isEmpty)
        #expect(Apps.meant([1, 0], apps: [], vectors: []).isEmpty)
    }

    @Test func listsAppsWithTheirCategoryAndSkipsBackgroundOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpApps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, info) in [("Darkroom", ["LSApplicationCategoryType": "public.app-category.photography"]),
                             ("Helper", ["LSBackgroundOnly": true]), ("Plain", [:])] as [(String, [String: Any])] {
            let contents = folder.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            #expect((info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Not an app"),
                                                withIntermediateDirectories: true)
        let found = Apps.installed(in: [folder.path])
        #expect(found.map(\.name) == ["Darkroom", "Plain"])
        #expect(found.map(\.category) == ["photography", nil])
        #expect(found[0].document == "title: Darkroom | text: Darkroom app, photography")
    }
}
