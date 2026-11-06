import Testing
import Foundation
@testable import PDFCropper

/// The language-pack list, the file steps behind it, and the saved choices.
@Suite("Language packs", .serialized)
@MainActor
struct LanguagePackTests {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("packs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Adding a pack copies it into the folder and returns its code")
    func addPack() throws {
        let source = try tempFolder(), folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: folder) }
        let file = source.appendingPathComponent("xyz.traineddata")
        try Data(repeating: 7, count: 2000).write(to: file)
        #expect(try TesseractService.addPack(from: file, folder: folder, check: { _, _ in true }) == "xyz")
        // Again, with new contents: replaces.
        try Data(repeating: 9, count: 3000).write(to: file)
        #expect(try TesseractService.addPack(from: file, folder: folder, check: { _, _ in true }) == "xyz")
        #expect(TesseractService.installedPacks(in: folder) == ["xyz"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("xyz.traineddata")).count == 3000)
        #expect(throws: (any Error).self) {
            try TesseractService.addPack(from: source.appendingPathComponent("a.txt"), folder: folder)
        }
    }

    @Test("A pack Tesseract can't load is turned away; a real one passes",
          .enabled(if: TesseractService.executableURL() != nil
                   && FileManager.default.fileExists(atPath: "/opt/homebrew/share/tessdata/eng.traineddata")))
    func packMustLoad() throws {
        let source = try tempFolder(), folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: folder) }
        let real = try Data(contentsOf: URL(fileURLWithPath: "/opt/homebrew/share/tessdata/eng.traineddata"))
        let file = source.appendingPathComponent("eng.traineddata")
        try real.write(to: file)
        #expect(try TesseractService.addPack(from: file, folder: folder) == "eng")
        // Cut short: the working copy stays.
        try real.prefix(200_000).write(to: file)
        #expect(throws: (any Error).self) { try TesseractService.addPack(from: file, folder: folder) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("eng.traineddata")).count == real.count)
    }

    @Test("A download needs HTTP 200 and over 1 KB, and replaces an old pack")
    func acceptDownload() throws {
        let folder = try tempFolder(), scratch = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: scratch) }
        let url = TesseractLanguage.downloadURL("grc")
        func response(_ status: Int) -> URLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        func file(_ size: Int) throws -> URL {
            let f = scratch.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 1, count: size).write(to: f)
            return f
        }
        #expect(throws: (any Error).self) { try TesseractService.accept(download: try file(5000), response: response(404), code: "grc", folder: folder, check: { _, _ in true }) }
        #expect(throws: (any Error).self) { try TesseractService.accept(download: try file(500), response: response(200), code: "grc", folder: folder, check: { _, _ in true }) }
        #expect(TesseractService.installedPacks(in: folder).isEmpty)
        try TesseractService.accept(download: try file(5000), response: response(200), code: "grc", folder: folder, check: { _, _ in true })
        try TesseractService.accept(download: try file(6000), response: response(200), code: "grc", folder: folder, check: { _, _ in true })
        #expect(try Data(contentsOf: folder.appendingPathComponent("grc.traineddata")).count == 6000)
    }

    @Test("Under Apple the list offers only packs that fill in a script; Tesseract lists all and extras by code")
    func choices() {
        let apple = LanguagePacksView.choices(reader: .apple, installed: ["zzz"]).map(\.code)
        #expect(apple.contains("grc") && !apple.contains("fra") && !apple.contains("eng"))
        #expect(!apple.contains("zzz") && !apple.contains("equ") && !apple.contains("osd"))
        let tess = LanguagePacksView.choices(reader: .tesseract, installed: ["zzz"])
        #expect(tess.count == TesseractLanguage.all.count + 1 && tess.contains { $0.code == "fra" } && tess.contains { $0.code == "zzz" })
    }

    @Test("The list runs in name order")
    func choicesByName() {
        for reader in [OCRReader.apple, .tesseract] {
            let names = LanguagePacksView.choices(reader: reader, installed: ["aaa", "zzz"]).map(\.name)
            #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
    }

    @Test("The reader and ticked packs survive a new model")
    func defaultsRoundTrip() throws {
        let name = "LanguagePackTests-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let first = AppModel(defaults: suite)
        #expect(first.ocrReader == .apple && first.ocrPacks.isEmpty)
        first.ocrReader = .tesseract
        first.ocrPacks = ["grc", "heb"]
        let second = AppModel(defaults: suite)
        #expect(second.ocrReader == .tesseract)
        #expect(second.ocrPacks == ["grc", "heb"])
    }
}
