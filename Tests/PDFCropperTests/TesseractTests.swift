import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import PDFCropper

@Suite("Tesseract", .serialized)
struct TesseractTests {
    private static let tessdata = URL(fileURLWithPath: "/opt/homebrew/share/tessdata", isDirectory: true)
    private static var integrationAvailable: Bool {
        TesseractService.executableURL() != nil && FileManager.default.fileExists(atPath: tessdata.appendingPathComponent("grc.traineddata").path)
    }

    /// Makes a word at a fixed row for overlap tests.
    private func word(_ text: String, _ x: CGFloat, _ width: CGFloat) -> OCRService.Word {
        OCRService.Word(text: text, box: CGRect(x: x, y: 0.5, width: width, height: 0.1))
    }

    /// Makes a line from its word boxes.
    private func line(_ words: [OCRService.Word]) -> OCRService.Line {
        OCRService.Line(text: words.map(\.text).joined(separator: " "),
                        box: words.reduce(.null) { $0.union($1.box) }, words: words)
    }

    @Test("TSV words group by page, block, paragraph and line in first-seen order")
    func parseTSV() {
        let header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext"
        let tsv = [header,
                   "4\t1\t1\t1\t1\t0\t0\t0\t100\t100\t-1\t",
                   "5\t1\t1\t1\t1\t1\t100\t20\t200\t40\t90\t  The  ",
                   "5\t1\t1\t1\t2\t1\t50\t100\t80\t20\t90\tNext",
                   "5\t1\t1\t1\t1\t2\t320\t20\t100\t40\t90\tword",
                   "5\t1\t1\t1\t1\t3\t0\t0\t10\t10\t90\t   ",
                   "5\t1\t2\t1\t1\t1\t20\t10\t10\t10\t90\tBlock",
                   "5\t1\t1\t2\t1\t1\t20\t10\t10\t10\t90\tParagraph",
                   "5\t2\t1\t1\t1\t1\t20\t10\t10\t10\t90\tPage",
                   "5\tbroken", "5\t1\t1\t1\t3\t1\tnan\t0\t10\t10\t90\tbad"].joined(separator: "\n")
        let lines = TesseractService.parseTSV(tsv, imageSize: CGSize(width: 1000, height: 200))
        #expect(lines.map(\.text) == ["The word", "Next", "Block", "Paragraph", "Page"])
        #expect(lines[0].words.map(\.text) == ["The", "word"])
        #expect(lines[0].words[0].box == CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2))
        #expect(abs(lines[0].box.minX - 0.1) < 0.000001)
        #expect(abs(lines[0].box.width - 0.32) < 0.000001)
        #expect(abs(lines[0].box.minY - 0.7) < 0.000001)
        #expect(TesseractService.parseTSV(header, imageSize: CGSize(width: 100, height: 100)).isEmpty)
        #expect(TesseractService.parseTSV(tsv, imageSize: .zero).isEmpty)
    }

    @Test("Greek fills junk words while known words and one Greek scalar stay")
    func fillIn() {
        let apple = line([word("The", 0.05, 0.1), word("Aoyoc", 0.2, 0.2), word("and", 0.5, 0.1), word("à", 0.7, 0.1)])
        // Each Tesseract word on a line of its own: none has a Greek neighbour.
        let tess = [line([word("λόγος", 0.2, 0.2)]), line([word("καί", 0.5, 0.1)]),
                    line([word("ἃ", 0.7, 0.1)]), line([word("θεός", 0.85, 0.1)])]
        let result = OCRService.fillIn([apple], from: tess, scripts: [.greek], keep: { ["The", "and"].contains($0) })
        #expect(result[0].text == "The λόγος and à")
        #expect(result[0].words[1].box == tess[0].words[0].box)
        #expect(result[0].words.count == 4)
        #expect(OCRService.fillIn([apple], from: tess, scripts: [.hebrew], keep: { _ in false })[0].text == apple.text)
        let unboxed = OCRService.Line(text: "Leave this", box: apple.box)
        #expect(OCRService.fillIn([unboxed], from: tess, scripts: [.greek], keep: { _ in false })[0].text == "Leave this")
    }

    @Test("Beside other Greek, a Greek word replaces even a real-looking word, and one letter counts")
    func fillInNeighbours() {
        // Owens p. 250: "περὶ αὐτῶν" read "regi airwv"; "ὃν ἦ ὄν" read "öv y öv".
        let apple = line([word("regi", 0.1, 0.1), word("airwv", 0.25, 0.15), word("at", 0.45, 0.05),
                          word("öv", 0.55, 0.05), word("y", 0.62, 0.03), word("öv", 0.7, 0.05)])
        let tess = line([word("περὶ", 0.1, 0.1), word("αὐτῶν", 0.25, 0.15), word("at", 0.45, 0.05),
                         word("ὃν", 0.55, 0.05), word("ἦ", 0.62, 0.03), word("ὄν", 0.7, 0.05)])
        let real: (String) -> Bool = { ["regi", "at", "y"].contains($0) }
        let result = OCRService.fillIn([apple], from: [tess], scripts: [.greek], keep: real)
        #expect(result[0].text == "περὶ αὐτῶν at ὃν ἦ ὄν")
        // One Greek letter with Greek on one side only stays Apple's.
        let edge = line([word("ὃν", 0.55, 0.05), word("ἦ", 0.62, 0.03), word("at", 0.7, 0.05)])
        let kept = OCRService.fillIn([apple], from: [edge], scripts: [.greek], keep: real)
        #expect(kept[0].words.map(\.text) == ["regi", "airwv", "at", "ὃν", "y", "öv"])
    }

    @Test("Two invented Greek words side by side don't vouch for each other")
    func fillInInventedPair() {
        // Tesseract reads "is n." as "ἐς τι.": both Apple words are real.
        let apple = line([word("This", 0.1, 0.1), word("is", 0.25, 0.05), word("n.", 0.35, 0.05)])
        let tess = line([word("This", 0.1, 0.1), word("ἐς", 0.25, 0.05), word("τι.", 0.35, 0.05)])
        let result = OCRService.fillIn([apple], from: [tess], scripts: [.greek], keep: { _ in true })
        #expect(result[0].text == "This is n.")
        // The Greek question mark is not a letter: "τι;" is still two.
        let question = line([word("This", 0.1, 0.1), word("ἐς", 0.25, 0.05), word("τι\u{037E}", 0.35, 0.05)])
        #expect(OCRService.fillIn([apple], from: [question], scripts: [.greek], keep: { _ in true })[0].text == "This is n.")
        // A longer run is Greek even over real-looking words: "roos &" is "πρὸς ἕν".
        let real = line([word("among", 0.1, 0.1), word("roos", 0.25, 0.05), word("&", 0.35, 0.05)])
        let greek = line([word("among", 0.1, 0.1), word("πρὸς", 0.25, 0.05), word("ἕν", 0.35, 0.05)])
        #expect(OCRService.fillIn([real], from: [greek], scripts: [.greek], keep: { _ in true })[0].text == "among πρὸς ἕν")
    }

    @Test("A failed Greek pass leaves Apple's text but marks the page incomplete")
    func failedFillInIsIncomplete() throws {
        let previous = PDFExporter.tessdataOverride
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); PDFExporter.tessdataOverride = previous }
        // A broken grc pack: Tesseract (or its absence) fails on it.
        try Data(repeating: 0, count: 4096).write(to: folder.appendingPathComponent("grc.traineddata"))
        PDFExporter.tessdataOverride = folder
        let media = CGRect(x: 0, y: 0, width: 800, height: 100)
        let image = mixedImage()
        let source = Fixtures.writePDF("fillin-source-\(UUID().uuidString).pdf", media: media, pages: [{ $0.draw(image, in: media) }])
        let document = try #require(PDFDocument(url: source))
        let output = Fixtures.url("fillin-output-\(UUID().uuidString).pdf")
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        var settings = PDFExporter.Settings()
        settings.packs = ["grc"]
        settings.dpi = 144
        settings.matchScanResolution = false
        let report = try PDFExporter.export(pages: [page], from: document, to: output, settings: settings)
        #expect(report.ocrFailedPages == [1])
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("word"), "\(text)")
    }

    @Test("Mixed case is not a word, whatever the spell checker says")
    func looksLikeWord() {
        #expect(!OCRService.looksLikeWord("alTON", languages: ["en"]))
        #expect(!OCRService.looksLikeWord("newTov", languages: ["en"]))
        #expect(!OCRService.looksLikeWord("METà", languages: ["en"]))
        #expect(OCRService.looksLikeWord("is", languages: ["en"]))
        #expect(OCRService.looksLikeWord("The", languages: ["en"]))
        #expect(OCRService.looksLikeWord("odd,", languages: ["en"]))
    }

    @Test("Two junk words become one at the first replaced word's position")
    func fillRun() {
        let apple = line([word("before", 0, 0.1), word("Ao", 0.2, 0.08), word("yoc", 0.3, 0.1), word("after", 0.6, 0.1)])
        let tess = line([word("λόγος", 0.19, 0.22)])
        let result = OCRService.fillIn([apple], from: [tess], scripts: [.greek], keep: { _ in false })
        #expect(result[0].text == "before λόγος after")
        #expect(result[0].words.map(\.text) == ["before", "λόγος", "after"])
        let kept = OCRService.fillIn([apple], from: [tess], scripts: [.greek], keep: { _ in true })
        #expect(kept[0].text == apple.text)
    }

    @Test("Each Apple word goes to its largest overlap, at the half-area threshold")
    func largestOverlap() {
        let apple = line([word("junk", 0.2, 0.2)])
        let tess = line([word("μικρός", 0.19, 0.12), word("λόγος", 0.19, 0.22)])
        #expect(OCRService.fillIn([apple], from: [tess], scripts: [.greek], keep: { _ in false })[0].text == "λόγος")
        let half = line([word("λόγος", 0.3, 0.2)])
        #expect(OCRService.fillIn([apple], from: [half], scripts: [.greek], keep: { _ in false })[0].text == "λόγος")
        let small = line([word("λόγος", 0.31, 0.2)])
        #expect(OCRService.fillIn([apple], from: [small], scripts: [.greek], keep: { _ in false })[0].text == "junk")
    }

    @Test("Language codes are unique and script flags match the pack table")
    func languages() {
        let all = TesseractLanguage.all
        #expect(all.count == 125)
        #expect(Set(all.map(\.code)).count == all.count)
        for code in ["grc", "ell", "heb", "eng", "fra", "deu", "lat"] {
            #expect(all.contains { $0.code == code })
        }
        #expect(all.first { $0.code == "grc" }?.appleReads == false)
        #expect(all.first { $0.code == "eng" }?.appleReads == true)
        #expect(Script.greek.contains("α".unicodeScalars.first!))
        #expect(Script.greek.contains("ἀ".unicodeScalars.first!))
        #expect(!Script.greek.contains("a".unicodeScalars.first!))
        #expect(TesseractLanguage.downloadURL("grc").absoluteString == "https://github.com/tesseract-ocr/tessdata_best/raw/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/grc.traineddata")
    }

    @Test("Only traineddata files count as installed packs")
    func installedPacks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("eng.traineddata"))
        try Data().write(to: folder.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("fake.traineddata"), withIntermediateDirectories: true)
        #expect(TesseractService.installedPacks(in: folder) == ["eng"])
    }

    /// Draws mixed English and Greek in Times on a white page.
    private func mixedImage() -> CGImage {
        Fixtures.image(1600, 200) { context in
            let font = CTFontCreateWithName("Times" as CFString, 48, nil)
            let text = NSAttributedString(string: "The word λόγος means", attributes: [.font: font])
            context.textPosition = CGPoint(x: 80, y: 80)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
    }

    @Test("Missing executable returns nil")
    func missingExecutable() {
        #expect(TesseractService.recognize(Fixtures.image(20, 20), languages: ["eng"], tessdata: Self.tessdata, executable: nil) == nil)
    }

    /// Writes a small executable to test process handling without OCR packs.
    private func executable(_ body: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test("PGM input, thread limit and full output streams work without blocking")
    func processOutput() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = try executable("""
        test "$OMP_THREAD_LIMIT" = 1 || exit 2
        test "$(/usr/bin/head -n 3 "$1")" = 'P5
        20 30
        255' || exit 3
        /usr/bin/head -c 131072 /dev/zero >&2
        printf 'level\\tpage_num\\tblock_num\\tpar_num\\tline_num\\tword_num\\tleft\\ttop\\twidth\\theight\\tconf\\ttext\\n'
        i=0
        while test "$i" -lt 3000; do
            printf '5\\t1\\t1\\t1\\t1\\t1\\t1\\t2\\t10\\t10\\t90\\tword\\n'
            i=$((i+1))
        done
        """, in: folder)
        let result = try #require(TesseractService.recognize(Fixtures.image(20, 30), languages: ["eng"],
                                                           tessdata: folder, executable: script, timeout: 10))
        #expect(result.lines.count == 1)
        #expect(result.lines[0].words.count == 3000)
    }

    @Test("Nonzero exit, malformed output and timeout return nil")
    func processFailures() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = Fixtures.image(20, 20)
        let failure = try executable("exit 1", in: folder)
        #expect(TesseractService.recognize(image, languages: ["eng"], tessdata: folder, executable: failure) == nil)
        let malformed = try executable("printf 'not TSV'", in: folder)
        #expect(TesseractService.recognize(image, languages: ["eng"], tessdata: folder, executable: malformed) == nil)
        let slow = try executable("exec /bin/sleep 20", in: folder)
        let start = Date()
        #expect(TesseractService.recognize(image, languages: ["eng"], tessdata: folder, executable: slow, timeout: 0.1) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("Tesseract reads Greek beside English", .enabled(if: Self.integrationAvailable))
    func recognize() throws {
        let result = try #require(TesseractService.recognize(mixedImage(), languages: ["grc", "eng"], tessdata: Self.tessdata))
        let words = result.lines.flatMap(\.words).map { $0.text.trimmingCharacters(in: .punctuationCharacters) }
        #expect(result.complete)
        #expect(words.contains("λόγος"), "\(words)")
        #expect(words.contains("word"), "\(words)")
    }

    @Test("Tesseract export adds a searchable English word", .enabled(if: Self.integrationAvailable))
    func export() throws {
        let previous = PDFExporter.tessdataOverride
        PDFExporter.tessdataOverride = Self.tessdata
        defer { PDFExporter.tessdataOverride = previous }
        let media = CGRect(x: 0, y: 0, width: 800, height: 100)
        let image = mixedImage()
        let source = Fixtures.writePDF("tesseract-source-\(UUID().uuidString).pdf", media: media, pages: [{ $0.draw(image, in: media) }])
        let document = try #require(PDFDocument(url: source))
        let output = Fixtures.url("tesseract-output-\(UUID().uuidString).pdf")
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        var settings = PDFExporter.Settings()
        settings.reader = .tesseract
        settings.dpi = 144
        settings.matchScanResolution = false
        // Empty packs must default to English.
        let report = try PDFExporter.export(pages: [page], from: document, to: output, settings: settings)
        #expect(report.pageCount == 1)
        #expect(report.ocrFailedPages.isEmpty)
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("word"), "\(text)")
    }
}
