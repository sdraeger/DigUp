import Foundation

/// A file the crawler decided to index.
public struct Candidate: Sendable {
    public let path: String
    public let kind: FileKind
    public let size: Int64
    public let mtime: Double
    public let inode: UInt64
    public let device: UInt64
}

public struct CrawlReport: Sendable {
    public var candidates: [Candidate] = []
    public var skipped: [String: Int] = [:]          // reason → files
    public var skippedFolders: [String: Int] = [:]   // reason → folders not walked into
    public var datasets: [String: Int] = [:]         // folder → files skipped as a dataset
    /// What the walk couldn't see but is still there: folders it couldn't read (no permission, or macOS hasn't asked
    /// yet) and files only in the cloud. A sync keeps their rows rather than take them for deleted, which would
    /// embed them all again once they're back.
    public var unreadable: [String] = []
    public var inCloud: [String] = []
}

/// Walks the chosen folders and applies `Rules`. Reads metadata only, never file contents (except the 600-byte
/// sniff that tells a real MPEG-TS video from a TypeScript file).
///
/// For the code index (`IndexOptions.code`) it walks the code folders instead: code files only (`Rules.classifyCode`),
/// in a git repo only those git keeps (`GitFiles`), and none in vendored or built folders.
public enum Crawler {
    public static func crawl(_ roots: [URL], options: IndexOptions) -> CrawlReport {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let keys = FileSystem.crawlKeys
        var report = CrawlReport()
        var projectRoots = Set<String>()
        var repos = GitRepos()
        var found: [Candidate] = []
        var foundPaths = Set<String>()   // a folder inside another root would be walked twice
        let unreadable = NSMutableArray()   // the walk's error handler escapes
        // Each root as the walk reports its files: symlinks resolved, letters as on disk (/private/tmp for /tmp).
        let roots = roots.map { URL(fileURLWithPath: FolderSelection.realPath($0.standardizedFileURL.path)) }
        let rootPaths = Set(roots.map(\.path))

        for root in roots {
            if options.code {
                repos.enterRoot(root.path)
            } else if Rules.isProjectRoot(root.path) {
                projectRoots.insert(root.path)
            }
            // A skip applies inside the chosen folders that contain it: a folder chosen inside a skipped one is
            // walked whole (`FolderSelection`). The walk reports real paths (/private/var, where a skip says /var).
            let skips = options.excludedFolders.map(FolderSelection.realPath)
                .filter { FolderSelection.isInside($0, root.path) }
            #if os(Windows)
            guard let walker = FileSystem.walk(root, keys: keys) else { continue }
            #else
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { url, _ in unreadable.add(url.path); return true })
            else { continue }
            #endif
            func visit(_ url: URL) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isPackage = FileSystem.isPackage(url, values)
                if values?.isDirectory == true, !isPackage {
                    if let reason = Rules.skipReason(forFolder: url, home: home, excluded: skips)
                        ?? (options.code ? Rules.codeSkipReason(forFolder: url) : nil) {
                        walker.skipDescendants()
                        report.skippedFolders[reason, default: 0] += 1
                    } else if options.code {
                        repos.enter(url.path)
                    } else if Rules.isProjectRoot(url.path) {
                        projectRoots.insert(url.path)
                    }
                    return
                }
                if isPackage {
                    walker.skipDescendants()   // macOS's enumerator never enters one; elsewhere it would
                    report.skipped["app or bundle", default: 0] += 1
                    return
                }
                let classification = options.code ? Rules.classifyCode(url, options: options)
                    : Rules.classify(url, values: values, options: options)
                switch classification {
                case .ignore:
                    report.skipped["other type", default: 0] += 1
                case .skip(let reason):
                    report.skipped[reason, default: 0] += 1
                case .index(let kind):
                    guard let info = FileSystem.info(of: url.path), info.isRegular else {
                        report.skipped["link or special file", default: 0] += 1
                        return
                    }
                    // Reading a dataless placeholder (iCloud "Optimize Mac Storage", File Providers) downloads it.
                    if info.dataless || FileSystem.isInCloud(values) {
                        report.skipped["in the cloud, not downloaded", default: 0] += 1
                        report.inCloud.append(url.path)
                        return
                    }
                    if options.code {
                        // Too big to be written by hand; a notebook's file holds its outputs too.
                        let limit = url.pathExtension.lowercased() == "ipynb" ? options.maxNotebookBytes
                            : options.maxCodeBytes
                        if info.size > limit {
                            report.skipped["too big to be written by hand", default: 0] += 1
                            return
                        }
                        if repos.ignores(url.path) {
                            report.skipped["ignored by git", default: 0] += 1
                            return
                        }
                    }
                    guard foundPaths.insert(url.path).inserted else { return }
                    found.append(Candidate(path: url.path, kind: kind, size: info.size, mtime: info.mtime,
                                           inode: info.inode, device: info.device))
                }
            }

            // URL resource values are autoreleased; draining per file keeps a big walk from piling them up (the app
            // crawls on a background queue whose pool only drains when the whole sync is done).
            while let url = autoreleasepool(invoking: { walker.nextObject() as? URL }) {
                autoreleasepool {
                    visit(url)
                }
            }
        }

        // Inside a code project only screenshots count (assets, fixtures and datasets don't).
        var inProject: [String: Bool] = [:]
        func isInProject(_ folder: String) -> Bool {
            if let known = inProject[folder] { return known }
            let parent = (folder as NSString).deletingLastPathComponent
            let answer = projectRoots.contains(folder) || (parent != folder && parent.count > 1 && isInProject(parent))
            inProject[folder] = answer
            return answer
        }
        var kept: [Candidate] = []
        for file in found {
            if !options.code, file.kind != .screenshot, isInProject((file.path as NSString).deletingLastPathComponent) {
                report.skipped["inside a code project", default: 0] += 1
            } else {
                kept.append(file)
            }
        }

        if !options.includeDatasets, !options.code {
            let datasets = Rules.datasetFolders(kept.map {
                (($0.path as NSString).deletingLastPathComponent,
                 (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension, $0.kind)
            }, roots: rootPaths)
            if !datasets.isEmpty {
                report.datasets = datasets
                kept.removeAll { file in
                    let skip = datasets[(file.path as NSString).deletingLastPathComponent] != nil
                        && [.image, .audio, .video].contains(file.kind)
                    if skip { report.skipped["dataset", default: 0] += 1 }
                    return skip
                }
            }
        }
        report.candidates = kept
        report.unreadable = unreadable.compactMap { $0 as? String }
        return report
    }
}

extension Crawler {
    /// The changes FSEvents reported (paths, and whether each is a folder) that a crawl of `roots` could pick up, by
    /// its own rules: none in or under a folder it doesn't walk into (hidden, an app or bundle, `Rules.skipReason`'s:
    /// ~/Library, developer and .noindex folders, excluded ones), none to a file it never indexes (`Rules.classify`),
    /// and inside a code project only pictures (it keeps screenshots there, and a removed one looks like any picture).
    /// A folder counts unless it's skipped: one moved in brings its files. Not the code index's rules.
    public static func relevant(_ changes: [(path: String, isFolder: Bool)], roots: [String],
                                options: IndexOptions) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Each root as `crawl` walks it: by its path and its real path, skipping only the excluded folders inside it.
        let walks = roots.flatMap { root in
            let real = FolderSelection.realPath(root)
            let skips = options.excludedFolders.filter {
                FolderSelection.isInside($0, root) || FolderSelection.isInside($0, real)
            }.flatMap { [$0, FolderSelection.realPath($0)] }
            return [(root: root, skips: skips), (root: real, skips: skips)]
        }
        var walked: [String: Bool] = [:]
        var projects: [String: Bool] = [:]
        func isWalked(_ folder: String, _ walk: (root: String, skips: [String])) -> Bool {
            let key = walk.root + "\u{0}" + folder
            if let known = walked[key] { return known }
            let url = URL(fileURLWithPath: folder)
            let answer = !url.lastPathComponent.hasPrefix(".")
                && !FileSystem.isPackage(url, try? url.resourceValues(forKeys: [.isPackageKey]))
                && Rules.skipReason(forFolder: url, home: home, excluded: walk.skips) == nil
            walked[key] = answer
            return answer
        }
        func isProject(_ folder: String) -> Bool {
            if let known = projects[folder] { return known }
            let answer = Rules.isProjectRoot(folder)
            projects[folder] = answer
            return answer
        }
        func picksUp(_ change: (path: String, isFolder: Bool), _ walk: (root: String, skips: [String])) -> Bool {
            var folders: [String] = []   // between the root and the change (the change too, if it's a folder)
            var folder = change.isFolder ? change.path : (change.path as NSString).deletingLastPathComponent
            while FolderSelection.isInside(folder, walk.root) {
                folders.append(folder)
                folder = (folder as NSString).deletingLastPathComponent
            }
            guard folders.allSatisfy({ isWalked($0, walk) }) else { return false }
            if change.isFolder { return true }
            let url = URL(fileURLWithPath: change.path)
            guard !url.lastPathComponent.hasPrefix("."),
                  case .index(let kind) = Rules.classify(byName: url, options: options) else { return false }
            return kind == .screenshot || kind == .image || !([walk.root] + folders).contains(where: isProject)
        }
        return changes.filter { change in
            let containing = walks.filter { change.path == $0.root || FolderSelection.isInside(change.path, $0.root) }
            return containing.isEmpty || containing.contains { picksUp(change, $0) }
        }.map(\.path)
    }
}

/// The git repos a code crawl walks through, and the files each keeps (`GitFiles`): a file git ignores (a build, an
/// environment, data, a secret listed in .gitignore) isn't code search's to read. A folder that isn't in a repo, or a
/// Mac without git, has no list: everything there counts.
struct GitRepos {
    /// Repo folder → the files git keeps in it (paths relative to it), or nil when git couldn't say.
    private var files: [String: Set<String>?] = [:]
    /// Folder → the repo it's in (nil: none), as the walk found them.
    private var repoOf: [String: String?] = [:]

    /// A chosen folder: a repo itself, or inside one (a repo's subfolder chosen on its own).
    mutating func enterRoot(_ path: String) {
        var folder = path
        while true {
            if FileManager.default.fileExists(atPath: folder + "/.git") {
                files[folder] = GitFiles.list(folder)
                repoOf[path] = folder
                return
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder, parent.count > 1 else { break }
            folder = parent
        }
        repoOf[path] = .some(nil)
    }

    /// A folder the walk goes into: a repo of its own when it has a .git folder (a submodule's or a worktree's .git
    /// file keeps it out of the walk: `Rules.codeSkipReason`).
    mutating func enter(_ path: String) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isFolder), isFolder.boolValue {
            files[path] = GitFiles.list(path)
            repoOf[path] = path
        }
    }

    /// The repo `folder` is in, from the closest folder the walk has seen.
    private mutating func repo(of folder: String) -> String? {
        if let known = repoOf[folder] { return known }
        let parent = (folder as NSString).deletingLastPathComponent
        let answer = parent != folder && parent.count > 1 ? repo(of: parent) : nil
        repoOf[folder] = answer
        return answer
    }

    /// Whether git ignores the file at `path` (in a repo whose files git listed).
    mutating func ignores(_ path: String) -> Bool {
        guard let repo = repo(of: (path as NSString).deletingLastPathComponent), let kept = files[repo] ?? nil
        else { return false }
        return !kept.contains(String(path.dropFirst(repo.count + 1)))
    }
}

/// The files git keeps in a repo: tracked ones, and new ones its .gitignore doesn't leave out.
enum GitFiles {
    /// Paths relative to `repo`, or nil when git can't say (no git, not a repo, an error). The git is `FileSystem.git`.
    static func list(_ repo: String) -> Set<String>? {
        guard let git = FileSystem.git else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        // Reading only: never wait for, or take, the repo's lock (an editor's git may be busy in it).
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return Set(data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) })
    }
}
