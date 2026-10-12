import AppKit
import DigUpKit
import SwiftUI

/// Settings → Folders → Coverage: the Mac's folders as a tree (the startup disk, iCloud Drive, other drives), each
/// marked searched, partly searched, skipped or not, opening a level at a time. A folder of yours that isn't searched
/// shows about what DigUp would find in it (`Census`, from Spotlight's index), so one worth adding stands out. A
/// folder is listed only once it's opened, and nothing is kept after the popover closes.
@Observable
final class Coverage {
    enum Mark {
        case searched, partly, skipped, unsearched

        var title: String {
            switch self {
            case .searched: "Searched"
            case .partly: "Partly searched"
            case .skipped: "Skipped"
            case .unsearched: "Not searched"
            }
        }

        var symbol: String {
            switch self {
            case .searched: "checkmark.circle.fill"
            case .partly: "circle.lefthalf.filled"
            case .skipped: "minus.circle"
            case .unsearched: "circle"
            }
        }

        var style: AnyShapeStyle {
            switch self {
            case .searched, .partly: AnyShapeStyle(Color.accentColor)
            case .skipped: AnyShapeStyle(.secondary)
            case .unsearched: AnyShapeStyle(.tertiary)
            }
        }
    }

    struct Row: Identifiable {
        let path: String
        let name: String
        let depth: Int
        let mark: Mark
        let isOpen: Bool
        /// It has subfolders, or isn't listed yet.
        let canOpen: Bool
        var id: String { path }
    }

    private(set) var rows: [Row] = []
    /// About what DigUp would find in the folders shown that aren't searched (yours: in /Users or on a drive).
    private(set) var counts: [String: [FileKind: Int]] = [:]
    @ObservationIgnored private let selection: FolderSelection
    @ObservationIgnored private let options: IndexOptions
    @ObservationIgnored private let tops: [(path: String, name: String)]
    @ObservationIgnored private var expanded: Set<String>
    @ObservationIgnored private var subfolders: [String: [String]] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var counting: [Task<Void, Never>] = []

    init(settings: AppSettings) {
        selection = FolderSelection(chosen: settings.roots.map(\.path), skipped: settings.excludedFolders.map(\.path))
        var options = IndexOptions()   // as the helper's (`Engine.startHelper`)
        options.excludedFolders = settings.excludedFolders.map(\.path)
        options.excludedExtensions = IndexOptions.extensions(settings.excludedTypes.joined(separator: ","))
        self.options = options
        tops = Self.tops()
        // Open down to the home folder and to each searched folder, so the tree starts where they are.
        expanded = Set(([NSHomeDirectory()] + selection.folders.map(FolderSelection.parent)).flatMap { path in
            sequence(first: path) { $0 == "/" ? nil : FolderSelection.parent($0) }
        })
        layout()
    }

    /// Still counting what's in folders shown.
    var isCounting: Bool { counts.count < asked.count }

    func toggle(_ row: Row) {
        if expanded.contains(row.path) { expanded.remove(row.path) } else { expanded.insert(row.path) }
        layout()
    }

    func close() {
        counting.forEach { $0.cancel() }
    }

    /// The startup disk, iCloud Drive (in ~/Library, which the tree doesn't show), then the other drives.
    private static func tops() -> [(path: String, name: String)] {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeIsRootFileSystemKey]
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                              options: [.skipHiddenVolumes]) ?? []).map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return (path: url.path, name: values?.volumeLocalizedName ?? url.lastPathComponent,
                    startup: values?.volumeIsRootFileSystem == true)
        }
        let cloud = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
        return volumes.filter(\.startup).map { ($0.path, $0.name) }
            + (AppSettings.isFolder(URL(fileURLWithPath: cloud)) ? [(cloud, "iCloud Drive")] : [])
            + volumes.filter { !$0.startup }.map { ($0.path, $0.name) }
    }

    private func layout() {
        var rows: [Row] = []
        func add(_ path: String, _ name: String, depth: Int) {
            let open = expanded.contains(path)
            let children = open ? list(path) : subfolders[path]
            rows.append(Row(path: path, name: name, depth: depth, mark: mark(of: path), isOpen: open,
                            canOpen: children?.isEmpty != true))
            for child in open ? children ?? [] : [] {
                add(child, FileManager.default.displayName(atPath: child), depth: depth + 1)
            }
        }
        for top in tops { add(top.path, top.name, depth: 0) }
        self.rows = rows
        countNew()
    }

    /// A folder's subfolders, by name, without apps and bundles, and without hidden ones unless a searched folder is in
    /// one (as Finder shows them).
    private func list(_ path: String) -> [String] {
        if let known = subfolders[path] { return known }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        // shortcut: listed on the main thread, which a slow network drive would hold up; move it off if one does
        let found = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                                 includingPropertiesForKeys: Array(keys))) ?? []
        let folders = found.filter { url in
            let values = try? url.resourceValues(forKeys: keys)
            let holdsSearched = selection.folders.contains { $0 == url.path || FolderSelection.isInside($0, url.path) }
            return values?.isDirectory == true && values?.isPackage != true && (values?.isHidden != true || holdsSearched)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .map(\.path)
        subfolders[path] = folders
        return folders
    }

    /// `FolderSelection`'s rule, which follows the crawl's: a folder it never walks into (node_modules, a .noindex
    /// folder, iCloud Drive in ~/Library) isn't searched unless it's chosen itself.
    private func mark(of path: String) -> Mark {
        if selection.isSearched(path) {
            return selection.effectiveSkips.contains { FolderSelection.isInside($0, path) } ? .partly : .searched
        }
        if selection.folders.contains(where: { FolderSelection.isInside($0, path) }) { return .partly }
        return selection.effectiveSkips.contains { path == $0 || FolderSelection.isInside(path, $0) }
            ? .skipped : .unsearched
    }

    /// Counts the folders newly shown that aren't searched, one query at a time, off the main thread.
    private func countNew() {
        let wanted = rows.filter { $0.mark == .unsearched && !asked.contains($0.path) }.map(\.path).filter { path in
            FolderSelection.isInside(path, "/Users") || FolderSelection.isInside(path, "/Volumes")
        }
        guard !wanted.isEmpty else { return }
        asked.formUnion(wanted)
        let (previous, options) = (counting.last, options)
        counting.append(Task.detached(priority: .utility) { [self] in
            await previous?.value
            for path in wanted {
                guard !Task.isCancelled else { return }
                let started = Date()
                let found = Census.counts(of: path, options: options)
                log("coverage: \(tildePath(path)) holds \(found.values.reduce(0, +)) files in \(ms(since: started))")
                await MainActor.run { counts[path] = found }
            }
        })
    }
}

/// The popover: the tree, and what its marks mean.
struct CoverageView: View {
    let coverage: Coverage
    /// Add Folders, with this one checked.
    let add: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(coverage.rows) { row in
                        CoverageRow(row: row, counts: coverage.counts[row.path],
                                    toggle: { coverage.toggle(row) }, add: { add(URL(fileURLWithPath: row.path)) })
                    }
                }
                .padding(6)
            }
            Divider()
            HStack(spacing: 14) {
                ForEach([Coverage.Mark.searched, .partly, .skipped, .unsearched], id: \.self) { mark in
                    HStack(spacing: 4) {
                        Image(systemName: mark.symbol).foregroundStyle(mark.style)
                        Text(mark.title)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        }
        .frame(width: 440, height: 460)
    }
}

/// A folder in the tree: name, about what's in it when it isn't searched (Add… when the pointer is on it), its mark.
private struct CoverageRow: View {
    let row: Coverage.Row
    let counts: [FileKind: Int]?
    let toggle: () -> Void
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(row.isOpen ? 90 : 0))
                .frame(width: 12)
                .opacity(row.canOpen ? 1 : 0)
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(row.name)
                .font(.system(size: 12))
                // A folder that isn't searched and has nothing for DigUp steps back; one with something stands out.
                .foregroundStyle(row.mark == .unsearched && counts?.isEmpty != false ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if row.mark == .unsearched {
                if hovering {
                    Button("Add…", action: add)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help("Add this folder to the ones DigUp searches")
                } else if let counts, !counts.isEmpty {
                    KindCounts(counts: counts)
                }
            }
            Image(systemName: row.mark.symbol)
                .font(.system(size: 12))
                .foregroundStyle(row.mark.style)
                .help(row.mark.title)
        }
        .padding(.leading, CGFloat(row.depth) * 16 + 4)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if row.canOpen { toggle() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name), \(row.mark.title)")
        .accessibilityAction(named: row.isOpen ? "Close" : "Open") { if row.canOpen { toggle() } }
    }
}
