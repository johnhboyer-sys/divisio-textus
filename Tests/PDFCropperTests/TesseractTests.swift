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

    @Test("A lone Greek word replaces a Latin-looking word the dictionary fails, not one it passes")
    func fillInLongLoneWord() {
        // Apple reads "ψυχή" as "vox.": no word in English, French or German.
        let apple = line([word("inward", 0.05, 0.1), word("at", 0.2, 0.05), word("the", 0.3, 0.05), word("vox.", 0.4, 0.06)])
        let tess = line([word("inward", 0.05, 0.1), word("at", 0.2, 0.05), word("the", 0.3, 0.05), word("ψυχή.", 0.4, 0.06)])
        let real: (String) -> Bool = { ["inward", "at", "the"].contains($0) }
        #expect(OCRService.fillIn([apple], from: [tess], scripts: [.greek], keep: real)[0].text == "inward at the ψυχή.")
        // Two letters stay Apple's: Tesseract reads "is" as "ἐς".
        let short = line([word("inward", 0.05, 0.1), word("at", 0.2, 0.05), word("the", 0.3, 0.05), word("ἐς", 0.4, 0.06)])
        #expect(OCRService.fillIn([apple], from: [short], scripts: [.greek],
                                  keep: { real($0) || $0 == "vox." })[0].text == apple.text)
    }

    @Test("A Tesseract line with Greek where Apple found no line is added in its place")
    func fillInMissingLine() {
        func row(_ text: String, y: CGFloat) -> OCRService.Line {
            let parts = text.split(separator: " ").map(String.init)
            return self.row(parts, x: 0.1, y: y, w: 0.1)
        }
        let apple = [row("above", y: 0.8), row("below", y: 0.2)]
        let tess = [row("above", y: 0.8), row("ὁ ἄνθρωπος φύσει πολιτικὸν ζῷον, is often", y: 0.5), row("below", y: 0.2)]
        let result = OCRService.fillIn(apple, from: tess, scripts: [.greek], keep: { _ in true })
        #expect(result.map(\.text) == ["above", "ὁ ἄνθρωπος φύσει πολιτικὸν ζῷον, is often", "below"])
        // A Tesseract line over an Apple line stays out: no duplicate.
        let over = [row("Apple line", y: 0.8)]
        #expect(OCRService.fillIn(over, from: [row("ἄνθρωπος φύσει", y: 0.8)], scripts: [.greek], keep: { _ in true }).count == 1)
        // A line with no Greek is not added.
        #expect(OCRService.fillIn(apple, from: [row("ἄνθρωπος φύσει", y: 0.8), row("plain English", y: 0.5)],
                                  scripts: [.greek], keep: { _ in false }).count == 2)
    }

    /// A Tesseract word at an exact place, size and confidence.
    private func tword(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 0.05,
                       conf: Double = 95) -> OCRService.Word {
        OCRService.Word(text: text, box: CGRect(x: x, y: y, width: w, height: h), conf: conf)
    }

    /// A line of words spaced along a row, each `w` wide.
    private func row(_ texts: [String], x: CGFloat, y: CGFloat, w: CGFloat = 0.08, h: CGFloat = 0.05,
                     conf: Double = 95) -> OCRService.Line {
        line(texts.enumerated().map { i, t in tword(t, x: x + CGFloat(i) * (w + 0.02), y: y, w: w, h: h, conf: conf) })
    }

    @Test("An uncovered Tesseract line enters only with strong evidence of Greek text")
    func fillInJunkLines() {
        let apple = [row(["English", "text", "above"], x: 0.1, y: 0.8), row(["English", "below"], x: 0.1, y: 0.2)]
        let none: (String) -> Bool = { _ in true }
        func added(_ tess: OCRService.Line) -> Bool {
            OCRService.fillIn(apple, from: [tess], scripts: [.greek], keep: none).count == 3
        }
        // A rule or plate Tesseract reads as "τι": too little Greek.
        #expect(!added(row(["τι"], x: 0.1, y: 0.5)))
        // One long Greek word is still one word.
        #expect(!added(row(["ἄνθρωπος"], x: 0.1, y: 0.5, w: 0.2)))
        // Plenty of Greek, but Tesseract is unsure of it: speckle.
        #expect(!added(row(["ἄνθρωπος", "φύσει", "πολιτικὸν"], x: 0.1, y: 0.5, w: 0.2, conf: 45)))
        // Plenty of Greek and sure, but specks far smaller or larger than the page's text.
        #expect(!added(row(["ἄνθρωπος", "φύσει", "πολιτικὸν"], x: 0.1, y: 0.5, w: 0.2, h: 0.01)))
        #expect(!added(row(["ἄνθρωπος", "φύσει", "πολιτικὸν"], x: 0.1, y: 0.3, w: 0.2, h: 0.15)))
        // The same line at the page's text size and sure of itself goes in.
        #expect(added(row(["ἄνθρωπος", "φύσει", "πολιτικὸν"], x: 0.1, y: 0.5, w: 0.2)))
    }

    @Test("A long Greek word never replaces a word Apple read that the dictionary passes")
    func fillInKeepsRealLatin() {
        // Printed italic transliteration "nous": Apple is right, Tesseract's Greek is not.
        let apple = line([word("the", 0.05, 0.05), word("nous", 0.2, 0.08)])
        let tess = line([word("the", 0.05, 0.05), tword("νους", x: 0.2, y: 0.5, w: 0.08, h: 0.1, conf: 96)])
        let result = OCRService.fillIn([apple], from: [tess], scripts: [.greek], keep: { ["the", "nous"].contains($0) })
        #expect(result[0].text == "the nous")
        // When Apple's word is no word, the long Greek one replaces it.
        let junk = OCRService.fillIn([apple], from: [tess], scripts: [.greek], keep: { $0 == "the" })
        #expect(junk[0].text == "the νους")
    }

    @Test("A Tesseract line that merges two Apple lines is not added again")
    func fillInNoDuplicate() {
        // Apple has the left and right pieces of one row; Tesseract reads the row as one line.
        let left = row(["ἄνθρωπος", "φύσει"], x: 0.10, y: 0.5, w: 0.09, h: 0.05)
        let right = row(["πολιτικὸν", "ζῷον"], x: 0.65, y: 0.5, w: 0.09, h: 0.05)
        let merged = line(left.words + [tword("ἐστί", x: 0.4, y: 0.5, w: 0.08)] + right.words)
        let apple = [left, right]
        let result = OCRService.fillIn(apple, from: [merged], scripts: [.greek], keep: { _ in true })
        #expect(result.map(\.text).joined(separator: " ").components(separatedBy: "ἄνθρωπος").count == 2)
        #expect(result.map(\.text).joined(separator: " ").components(separatedBy: "ζῷον").count == 2)
        // Only the uncovered middle word is missing, and it is too little Greek to add alone.
        #expect(result.count == 2)
    }

    @Test("A line Apple missed goes into its own column, not by height alone")
    func fillInKeepsColumnOrder() {
        func col(_ t: String, x: CGFloat, y: CGFloat) -> OCRService.Line {
            row([t, "word", "here"], x: x, y: y, w: 0.1, h: 0.05)
        }
        // Apple reads the left column, then the right one.
        let apple = [col("L1", x: 0.05, y: 0.8), col("L2", x: 0.05, y: 0.6), col("L3", x: 0.05, y: 0.4),
                     col("R1", x: 0.55, y: 0.8), col("R3", x: 0.55, y: 0.4)]
        let missing = row(["ἄνθρωπος", "φύσει", "πολιτικὸν"], x: 0.55, y: 0.6, w: 0.1, h: 0.05)
        let result = OCRService.fillIn(apple, from: [missing], scripts: [.greek], keep: { _ in true })
        #expect(result.map { String($0.text.prefix(2)) } == ["L1", "L2", "L3", "R1", "ἄν", "R3"])
    }

    @Test("A Tesseract word with no usable confidence cannot start a new line")
    func fillInUnknownConfidence() {
        let apple = [row(["English", "text", "above"], x: 0.1, y: 0.8), row(["English", "below"], x: 0.1, y: 0.2)]
        func added(_ conf: String) -> Bool {
            let header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext"
            let rows = zip(["ἄνθρωπος", "φύσει", "πολιτικὸν"], [0, 300, 600]).enumerated().map { i, pair in
                "5\t1\t1\t1\t1\t\(i + 1)\t\(pair.1)\t475\t250\t50\t\(conf)\t\(pair.0)"
            }
            let tess = TesseractService.parseTSV(([header] + rows).joined(separator: "\n"), imageSize: CGSize(width: 1000, height: 1000))
            return OCRService.fillIn(apple, from: tess, scripts: [.greek], keep: { _ in true }).count == 3
        }
        #expect(added("95"))
        #expect(added("95,3"))
        #expect(!added(""))
        #expect(!added("-1"))
        #expect(!added("abc"))
        #expect(TesseractService.parseTSV("level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n5\t1\t1\t1\t1\t1\t0\t0\t10\t10\t95,3\tx",
                                          imageSize: CGSize(width: 100, height: 100))[0].words[0].conf == 95.3)
    }

    @Test("With no Apple text to size against, no Greek line is added")
    func fillInNoHeightReference() {
        let tiny = row(["λόγος", "θεός"], x: 0.1, y: 0.5, w: 0.2, h: 0.001)
        #expect(OCRService.fillIn([], from: [tiny], scripts: [.greek], keep: { _ in true }).isEmpty)
        let page = row(["ἄνθρωπος", "φύσει", "πολιτικὸν"], x: 0.1, y: 0.5, w: 0.2)
        #expect(OCRService.fillIn([], from: [page], scripts: [.greek], keep: { _ in true }).isEmpty)
    }

    @Test("Overlapping Apple boxes count their shared area once against a missing Greek word")
    func fillInOverlappingCoverage() {
        // Two identical Apple boxes each cover the same 20% of the Greek line's middle word:
        // 20% covered, not 40%, so the line stays whole and goes in.
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat = 0.05) -> OCRService.Word {
            OCRService.Word(text: "x", box: CGRect(x: x, y: y, width: w, height: h))
        }
        // Each tall box overlaps the middle word's lower 20% and under half of itself.
        let tall = box(0.62, 0.54, 0.1, 0.1)
        let page = [line([box(0.1, 0.8, 0.1), box(0.25, 0.8, 0.1)]), line([tall, tall]),
                    line([box(0.1, 0.2, 0.1), box(0.25, 0.2, 0.1)])]
        let greek = row(["ἄνθρωπος", "φύσει", "πολιτικὸν"], x: 0.5, y: 0.5, w: 0.1)
        let result = OCRService.fillIn(page, from: [greek], scripts: [.greek], keep: { _ in true })
        #expect(result.contains { $0.text == "ἄνθρωπος φύσει πολιτικὸν" })
    }

    @Test("A full-width heading does not anchor a missing line of one column")
    func fillInHeadingNotAnAnchor() {
        func col(_ t: String, x: CGFloat, y: CGFloat) -> OCRService.Line {
            row([t, "word", "here"], x: x, y: y, w: 0.1, h: 0.05)
        }
        let heading = row(["A", "Chapter", "Heading", "Across", "The", "Whole", "Page", "Width", "Here"], x: 0.05, y: 0.9, w: 0.08, h: 0.05)
        let apple = [heading, col("L1", x: 0.05, y: 0.75), col("L2", x: 0.05, y: 0.55), col("L3", x: 0.05, y: 0.35),
                     col("R2", x: 0.55, y: 0.55), col("R3", x: 0.55, y: 0.35)]
        let missing = row(["ἄνθρωπος", "φύσει", "πολιτικὸν"], x: 0.55, y: 0.75, w: 0.1, h: 0.05)
        let result = OCRService.fillIn(apple, from: [missing], scripts: [.greek], keep: { _ in true })
        #expect(result.map { String($0.text.prefix(2)) } == ["A ", "L1", "L2", "L3", "ἄν", "R2", "R3"])
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

    @Test("A Greek word set inside a wider Apple box takes its word, a sliver does not")
    func fillInWordInsideBox() {
        // Apple's box for "te" is wider than the printed "τε" Tesseract boxes (it was 40 % of it).
        let apple = line([word("before", 0, 0.1), word("te", 0.2, 0.1)])
        let inside = line([word("τε", 0.22, 0.04)])
        #expect(OCRService.fillIn([apple], from: [inside], scripts: [.greek], keep: { _ in false })[0].text == "before τε")
        let sliver = line([word("τε", 0.2, 0.025)])
        #expect(OCRService.fillIn([apple], from: [sliver], scripts: [.greek], keep: { _ in false })[0].text == "before te")
        // A real word stays, as ever.
        #expect(OCRService.fillIn([apple], from: [inside], scripts: [.greek], keep: { _ in true })[0].text == "before te")
    }

    @Test("On a line that is nearly all Greek, Tesseract's Greek replaces every Apple word it covers")
    func fillInGreekLine() {
        // Printed "οἰωνοῖσί δ᾽ ἡ πᾶσι τε Διὸς": Apple's readings include "8" and "ý", which pass as real.
        let tess = row(["οἰωνοῖσί", "δ᾽", "ἡ", "πᾶσι", "τε", "Διὸς"], x: 0.1, y: 0.5, w: 0.08)
        let apple = row(["oiwvoiot", "8", "ý", "mao", "te", "Atos"], x: 0.1, y: 0.5, w: 0.08)
        let result = OCRService.fillIn([apple], from: [tess], scripts: [.greek], keep: { ["8", "ý", "te"].contains($0) })
        #expect(result[0].text == tess.text)
        // The same words among English are not: one Greek word and a letter or two.
        let mixed = row(["the", "ἡ", "ἡ", "mao"], x: 0.1, y: 0.5, w: 0.08)
        let english = row(["the", "n", "ý", "mao"], x: 0.1, y: 0.5, w: 0.08)
        #expect(OCRService.fillIn([english], from: [mixed], scripts: [.greek], keep: { $0 != "mao" })[0].text == english.text)
    }

    @Test("A sure, accented Greek word beats a Latin word Apple made of it, on a page with other Greek")
    func fillInAccentedWord() {
        // "ἔρις, δίκη." read "čpi, Sin."; "Sin." is a word, so the checker keeps it.
        let apple = [row(["the", "Sin.", "flow"], x: 0.1, y: 0.5, w: 0.08), row(["bog", "foo"], x: 0.1, y: 0.2, w: 0.08)]
        // Elsewhere two Greek words of four letters or more replace junk: this page has Greek.
        let elsewhere = row(["ἀρετή", "ἄδικον"], x: 0.1, y: 0.2, w: 0.08)
        let keep: (String) -> Bool = { ["the", "Sin.", "flow"].contains($0) }
        func read(_ words: [String], conf: Double = 95, page: Bool = true) -> String {
            let tess = row(words, x: 0.1, y: 0.5, w: 0.08, conf: conf)
            return OCRService.fillIn(page ? apple : [apple[0]], from: page ? [tess, elsewhere] : [tess], scripts: [.greek], keep: keep)[0].text
        }
        #expect(read(["the", "δίκη.", "flow"]) == "the δίκη. flow")
        // Tesseract unsure of it, no accent (printed "nous" or "sin"), or no Greek elsewhere: Apple's stays.
        #expect(read(["the", "δίκη.", "flow"], conf: 60) == "the Sin. flow")
        #expect(read(["the", "δικη.", "flow"]) == "the Sin. flow")
        #expect(read(["the", "δίκη.", "flow"], page: false) == "the Sin. flow")
        // Under four letters stays: "ἐς" for "is".
        #expect(read(["the", "ἐς", "flow"]) == "the Sin. flow")
    }

    @Test("Letters outside Western Latin make no word, and one letter is a word only as a, A or I")
    func looksLikeWordLetters() {
        // Apple's readings of Greek: "ἱστορίης", "ἔρις,", "ἄδικον,", "ὁ".
        for junk in ["iơtoping", "čpi,", "aıv,", "ń", "ó", "o", "&"] {
            #expect(!OCRService.looksLikeWord(junk, languages: ["en", "fr", "de"]), "\(junk)")
        }
        for word in ["a", "A", "I", "été", "œuvre", "naïve,", "1957", "(a)"] {
            #expect(OCRService.looksLikeWord(word, languages: ["en", "fr", "de"]), "\(word)")
        }
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

    @Test("The Tesseract reader always reads English, plus the ticked packs it has")
    func readerLanguages() {
        #expect(TesseractService.readerLanguages(ticked: [], installed: ["eng"]) == ["eng"])
        #expect(TesseractService.readerLanguages(ticked: ["grc", "heb"], installed: ["eng", "grc"]) == ["grc", "eng"])
        #expect(TesseractService.readerLanguages(ticked: ["eng", "grc"], installed: ["eng", "grc"]) == ["grc", "eng"])
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
