import DigUpKit
import Foundation

/// Search by a part of the screen (⌘R in the panel, or its dashed-rectangle button), like Circle to Search: macOS's
/// own crosshair picks it (`screencapture -i`: Space picks a window instead, Esc gives up), and the files most like it
/// come up, as for any file searched by (`LikeQuery`): a chart finds the report it came from. macOS asks once whether
/// DigUp may record the screen.
enum ScreenRegion {
    /// What the field says while the part of the screen is what's searched by.
    static let query = LikeQuery.prefix + " screen selection"
    /// The part last picked, kept until the next one.
    static let file = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp screen selection.png")

    /// The file a "like:" query searches by: the part of the screen picked, for `query`.
    static func path(of typed: String) -> String? {
        typed.trimmingCharacters(in: .whitespaces).lowercased() == query ? file.path : LikeQuery.path(of: typed)
    }

    /// Lets you pick a part of the screen. True when you did (Esc: false). `-debugRegion <png>` takes that picture
    /// instead, for test runs.
    static func pick() async -> Bool {
        try? FileManager.default.removeItem(at: file)
        if let picture = UserDefaults.standard.string(forKey: "debugRegion") {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: picture), to: file)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", file.path]   // interactive, without the camera sound
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    log("screen region: can't run screencapture: \(error)")
                    continuation.resume()
                }
            }
        }
        let picked = ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        log("screen region: \(picked ? "picked" : "none")")
        return picked
    }
}
