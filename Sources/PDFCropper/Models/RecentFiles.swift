import Foundation

/// A PDF the user opened, and when.
struct RecentPDF: Identifiable, Equatable {
    var url: URL
    var opened: Date
    var id: String { url.path }
}

/// The PDFs opened lately, newest first, kept in UserDefaults. The Welcome screen lists them.
enum RecentFiles {
    /// Replaced in DEBUG screenshot runs, so they leave the user's own list alone.
    nonisolated(unsafe) static var defaults = UserDefaults.standard
    static let key = "recentPDFs"
    static let shown = 8
    /// Kept beyond what shows, so files that move or vanish don't empty the list.
    private static let kept = 30

    private struct Entry: Codable { var path: String; var opened: Date }

    private static func entries() -> [Entry] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Records that `url` was opened now.
    static func note(_ url: URL, at date: Date = Date()) {
        let path = url.standardizedFileURL.path
        var all = entries().filter { $0.path != path }
        all.insert(Entry(path: path, opened: date), at: 0)
        if let data = try? JSONEncoder().encode(Array(all.prefix(kept))) { defaults.set(data, forKey: key) }
    }

    /// Up to `shown` recent PDFs that are still on disk.
    static func list() -> [RecentPDF] {
        entries()
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(shown)
            .map { RecentPDF(url: URL(fileURLWithPath: $0.path), opened: $0.opened) }
    }
}
