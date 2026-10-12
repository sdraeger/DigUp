#if canImport(CoreServices)   // Spotlight: macOS only
import Foundation
import Testing
@testable import DigUpKit

/// Counting a folder from Spotlight's list by the crawl's rules, without opening anything in it.
@Suite struct CensusTests {
    @Test func spotlightsListGoesThroughTheCrawlsRules() {
        var options = IndexOptions()
        options.excludedFolders = ["/x/skipped"]
        let items: [Census.Item] = [
            .init(path: "/x/beach.jpg", type: "public.jpeg"),
            .init(path: "/x/Screenshot 2026-10-11.png", type: "public.png"),
            .init(path: "/x/notes.md"),
            .init(path: "/x/main.swift", type: "public.swift-source"),
            .init(path: "/x/clip.ts", type: "public.mpeg-2-transport-stream"),
            .init(path: "/x/.hidden/a.jpg", type: "public.jpeg"),
            .init(path: "/x/web/node_modules/pkg/c.png", type: "public.png"),
            .init(path: "/x/skipped/d.pdf", type: "com.adobe.pdf"),
            // A code project: only its screenshots count.
            .init(path: "/x/app/package.json"),
            .init(path: "/x/app/assets/logo.png", type: "public.png"),
            .init(path: "/x/app/docs/shot.png", type: "public.png", captured: true),
        ] + (1...300).map { .init(path: "/x/data/frame_\(1000 + $0).jpg", type: "public.jpeg") }   // a dataset
        #expect(Census.tally(items, in: "/x", options: options) == [.image: 1, .screenshot: 2, .doc: 1])
        // The root itself is never a project (as in the crawl), and a dataset only below it.
        #expect(Census.tally([.init(path: "/x/package.json"), .init(path: "/x/logo.png", type: "public.png")],
                             in: "/x", options: options) == [.image: 1])
    }
}
#endif
