import Foundation
import CryptoKit

/// Remembers each PDF's page edits between launches. Saved under Application
/// Support, keyed by a hash of the file's contents, so the edits follow the PDF
/// across renames and moves and never clutter the folder it sits in.
enum ProjectStore {

    /// Bumped whenever page geometry changes meaning, so older saves are ignored
    /// (those pages get re-detected) rather than restored onto the wrong spot.
    /// 2: crops are relative to the page as displayed (crop box, rotation).
    static let currentVersion = 2

    struct Saved: Codable {
        var version = ProjectStore.currentVersion
        var pages: [BookPage]
        var direction: ReadingDirection
        /// Absent in saves made before whole-page crops existed: text block.
        var cropTarget: CropTarget?
        /// The page size typed in for Whole page crops; absent: measured.
        var pageSize: PageSize?
        /// Pages whose crops analysis set and nobody has edited since, with what
        /// it found on them (see AppModel.setByAnalysis); absent in older saves.
        var claims: [BookPage.ID: AnalysisClaim]?
    }

    /// Identifies a PDF by its size plus a hash of its first 4 MB: unique enough
    /// for scans, and fast even on very large files.
    static func key(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4 << 20),
              let size = try? handle.seekToEnd() else { return nil }
        var hasher = SHA256()
        hasher.update(data: head)
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func load(key: String) -> Saved? {
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url) else { return nil }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == currentVersion else { return nil }
        return saved
    }

    static func save(_ saved: Saved, key: String) {
        guard let url = fileURL(for: key), let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Where saves go. Tests point this at a temporary folder so they never
    /// touch real saved edits.
    static var directory: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Divisio Textus/Edits", isDirectory: true)

    private static func fileURL(for key: String) -> URL? {
        directory?.appendingPathComponent("\(key).json")
    }
}
