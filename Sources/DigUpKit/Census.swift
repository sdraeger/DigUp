#if canImport(CoreServices)   // Spotlight: macOS only
import CoreServices
import Foundation
import UniformTypeIdentifiers

/// About what searching a folder would bring, by kind, without walking it: the files Spotlight's index lists there
/// (never any inside apps and bundles), put through the crawl's rules by their paths alone. Nothing in the folder is
/// opened, so it costs one query, and a folder macOS hasn't let DigUp read yet asks nothing. Rougher than
/// `Crawler.crawl`: what Spotlight doesn't index is missing, a code project is known by its manifest (package.json,
/// Cargo.toml…; a repo with only .git isn't), and files only in iCloud count.
public enum Census {
    /// A file as Spotlight lists it: its content type, and whether macOS marked it a screenshot.
    struct Item {
        let path: String
        var type: String? = nil
        var captured = false
    }

    public static func counts(of folder: String, options: IndexOptions) -> [FileKind: Int] {
        let root = FolderSelection.realPath(folder)   // Spotlight lists real paths
        return tally(spotlight(root), in: root, options: options)
    }

    static func tally(_ items: [Item], in root: String, options: IndexOptions) -> [FileKind: Int] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let skips = options.excludedFolders.map(FolderSelection.realPath).filter { FolderSelection.isInside($0, root) }
        func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
        // As the crawl finds them: folders below the root holding a manifest.
        let projects = Set(items.filter { item in
            let name = (item.path as NSString).lastPathComponent
            return Rules.projectMarkers.contains(name)
                || Rules.projectBundleExtensions.contains((name as NSString).pathExtension)
        }.map { parent($0.path) }).subtracting([root])
        var walked: [String: Bool] = [root: true]
        func isWalked(_ folder: String) -> Bool {
            if let known = walked[folder] { return known }
            let url = URL(fileURLWithPath: folder)
            let answer = FolderSelection.isInside(folder, root) && isWalked(parent(folder))
                && !url.lastPathComponent.hasPrefix(".")
                && Rules.skipReason(forFolder: url, home: home, excluded: skips) == nil
            walked[folder] = answer
            return answer
        }
        func isInProject(_ folder: String) -> Bool {
            projects.contains(folder) || (folder != root && FolderSelection.isInside(folder, root)
                                          && isInProject(parent(folder)))
        }
        var files: [(folder: String, stem: String, kind: FileKind)] = []
        for item in items {
            let url = URL(fileURLWithPath: item.path)
            let folder = parent(item.path)
            // shortcut: a transport stream takes a read to tell from TypeScript, so .ts/.mts/.m2ts aren't counted
            guard !url.lastPathComponent.hasPrefix("."), isWalked(folder),
                  !["ts", "mts", "m2ts"].contains(url.pathExtension.lowercased()),
                  case .index(let kind) = Rules.classify(url, type: item.type.flatMap { UTType($0) }, options: options,
                                                         captured: item.captured),
                  kind == .screenshot || !isInProject(folder)
            else { continue }
            files.append((folder, url.deletingPathExtension().lastPathComponent, kind))
        }
        let datasets = options.includeDatasets ? [:] : Rules.datasetFolders(files, roots: [root])
        var counts: [FileKind: Int] = [:]
        for file in files where datasets[file.folder] == nil || ![.image, .audio, .video].contains(file.kind) {
            counts[file.kind, default: 0] += 1
        }
        return counts
    }

    /// The files of the kinds DigUp reads, and the manifests that mark code projects.
    static func spotlight(_ folder: String) -> [Item] {
        let types = ["public.image", "com.adobe.pdf", "public.audiovisual-content"]
            .map { "kMDItemContentTypeTree == \"\($0)\"" }
        let names = (Rules.docExtensions.union(Rules.projectBundleExtensions)).map { "kMDItemFSName == \"*.\($0)\"c" }
            + Rules.projectMarkers.filter { !$0.hasPrefix(".") }.map { "kMDItemFSName == \"\($0)\"" }
        let captured = "kMDItemIsScreenCapture" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, (types + names).joined(separator: " || ") as CFString,
                                        [kMDItemContentType, captured] as CFArray, nil) else { return [] }
        MDQuerySetSearchScope(query, [folder] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        func value(_ attribute: CFString, _ index: CFIndex) -> CFTypeRef? {
            MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index)
                .map { Unmanaged<CFTypeRef>.fromOpaque($0).takeUnretainedValue() }
        }
        return (0..<MDQueryGetResultCount(query)).compactMap { index in
            // The path isn't a stored attribute, so it doesn't come in the query's value lists.
            guard let pointer = MDQueryGetResultAtIndex(query, index),
                  let path = MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue(),
                                                 kMDItemPath) as? String else { return nil }
            return Item(path: path, type: value(kMDItemContentType, index) as? String,
                        captured: value(captured, index) as? Bool ?? false)
        }
    }
}
#endif
