import AppKit
import DigUpKit
import UserNotifications

/// Saved searches: queries kept (⌘S in the panel) and watched. When indexing brings in new files (not a folder's
/// first pass) that are strong results of one, a notification says so, and clicking it runs that search in the panel.
extension AppController {
    /// Saves the query, or forgets it if it was saved. True: it's saved now.
    @discardableResult
    func toggleSaved(_ query: String) -> Bool {
        var saved = model.settings.savedSearches
        if let index = saved.firstIndex(of: query) { saved.remove(at: index) } else { saved.append(query) }
        model.settings.savedSearches = saved
        AppSettings.save(savedSearches: saved)
        let isSaved = saved.contains(query)
        // Asked when there's first something to tell (macOS asks once).
        if isSaved { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        log("saved searches: \(saved.count)")
        return isSaved
    }

    /// Files just indexed as new (`Engine.onNewFiles`): the saved searches they're strong results of get a
    /// notification. Searches of code aren't checked: new code goes to the code index, not among these.
    func checkSavedSearches(_ paths: [String]) {
        let saved = model.settings.savedSearches.filter { CodeQuery.text(of: $0) == nil }
        guard !saved.isEmpty else { return }
        let new = Set(paths)
        Task {
            for query in saved {
                let hits = if let path = LikeQuery.path(of: query) {
                    await engine.similar(to: path)
                } else {
                    await engine.search(query, vector: await engine.embed(query), prefixLast: false)
                }
                let found = hits.prefix(Searcher.strongCount(hits)).filter { new.contains($0.path) }
                    .map { ($0.path as NSString).lastPathComponent }
                log("saved search \"\(query)\": \(found.count) of \(paths.count) new files match"
                    + (found.isEmpty ? "" : " (\(found.joined(separator: ", ")))"))
                if !found.isEmpty { notify(query, found) }
            }
        }
    }

    private func notify(_ query: String, _ names: [String]) {
        let content = UNMutableNotificationContent()
        content.title = LikeQuery.path(of: query).map { "New files like \(($0 as NSString).lastPathComponent)" }
            ?? "New for “\(query)”"
        content.body = names.count <= 3 ? names.joined(separator: ", ")
            : names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        content.userInfo = ["query": query]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                                     trigger: nil))
    }

    /// A saved search's notification, clicked: that search in the panel.
    func searchInPanel(_ query: String) {
        panel.show()
        panel.query = query
    }
}
