import Foundation

/// An installed app, as the panel finds it: by name, or by what it's for. Apps are never indexed: the app lists them
/// when the panel opens (`Apps.installed`), and its query encoder embeds their names and categories once.
public struct InstalledApp: Sendable, Equatable {
    public let path: String
    /// As Finder shows it: "System Settings".
    public let name: String
    /// From the bundle's LSApplicationCategoryType: "photography", "developer tools".
    public let category: String?

    public init(path: String, name: String, category: String?) {
        self.path = path
        self.name = name
        self.category = category
    }

    /// What the model reads to find it by what it's for (`Apps.meant`).
    public var document: String {
        Prompts.document(title: name, text: "\(name) app" + (category.map { ", \($0)" } ?? ""))
    }
}

public enum Apps {
    /// Where apps live: these folders, not their subfolders.
    public static let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                                 "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
    /// How far an app must stand out from the others (z over all installed apps) to be found by what it's for. Set by
    /// probing one Mac's apps (2026-10-11): searches for files ("dog on the beach") stayed well below it, "video call"
    /// and "listen to music" well above.
    public static let zGate = 3.5

    /// The apps in `folders`, minus background-only ones.
    public static func installed(in folders: [String] = folders) -> [InstalledApp] {
        let files = FileManager.default
        return folders.flatMap { folder in
            ((try? files.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }.sorted()
                .compactMap { entry -> InstalledApp? in
                    let path = folder + "/" + entry
                    let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
                    if info?["LSBackgroundOnly"] as? Bool == true { return nil }
                    let category = (info?["LSApplicationCategoryType"] as? String).map {
                        $0.replacingOccurrences(of: "public.app-category.", with: "")
                            .replacingOccurrences(of: "-", with: " ")
                    }
                    let name = files.displayName(atPath: path)   // localized; ".app" too if Finder shows extensions
                    return InstalledApp(path: path, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                                        category: category)
                }
        }
    }

    /// The apps whose name starts with `query`, or has a word that does ("code" finds Visual Studio Code): those
    /// whose name starts with it first, then shorter names first.
    public static func named(_ query: String, in apps: [InstalledApp]) -> [InstalledApp] {
        let typed = fold(query.trimmingCharacters(in: .whitespaces))
        guard !typed.isEmpty else { return [] }
        let found = apps.compactMap { app -> (rank: Int, app: InstalledApp)? in
            let name = fold(app.name)
            if name.hasPrefix(typed) { return (0, app) }
            var rest = name[...]
            while let gap = rest.firstIndex(where: { !$0.isLetter && !$0.isNumber }) {
                rest = rest[rest.index(after: gap)...]
                if rest.hasPrefix(typed) { return (1, app) }
            }
            return nil
        }
        return found.sorted { ($0.rank, $0.app.name.count, $0.app.name) < ($1.rank, $1.app.name.count, $1.app.name) }
            .map(\.app)
    }

    /// The apps that stand out for the query by what they're for (z ≥ `zGate` over all of them), best first.
    /// `vectors`: the apps' `document` embeddings in the same order, L2-normalized like `query`, so a dot product is
    /// the cosine.
    public static func meant(_ query: [Float], apps: [InstalledApp], vectors: [[Float]]) -> [InstalledApp] {
        let cosines = vectors.map { zip(query, $0).reduce(0) { $0 + Double($1.0 * $1.1) } }
        let mean = cosines.reduce(0, +) / Double(cosines.count)
        let sd = (cosines.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(cosines.count)).squareRoot()
        guard sd > 0 else { return [] }   // also no apps (NaN)
        return zip(apps, cosines).map { ($0, ($1 - mean) / sd) }.filter { $0.1 >= zGate }.sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
