import Foundation
import CryptoKit

/// Remembers each PDF's page edits between launches. Saved under Application
/// Support, keyed by a hash of the file's contents, so the edits follow the PDF
/// across renames and moves and never clutter the folder it sits in.
enum ProjectStore {

    struct Saved: Codable {
        var version = 1
        var pages: [BookPage]
        var direction: ReadingDirection
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
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved, key: String) {
        guard let url = fileURL(for: key), let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL(for key: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Divisio Textus/Edits/\(key).json")
    }
}
