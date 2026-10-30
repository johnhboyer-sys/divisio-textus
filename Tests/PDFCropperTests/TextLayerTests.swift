import Testing
import Foundation
import PDFKit
import CoreText
@testable import PDFCropper

@Suite("Searchable text layer")
struct TextLayerTests {

    @Test("Lines of many sizes embed the font once and copy out cleanly")
    func oneFontCleanText() throws {
        let out = Fixtures.url("textlayer-\(UUID().uuidString).pdf")
        var page = CGRect(x: 0, y: 0, width: 400, height: 600)
        let ctx = try #require(CGContext(consumer: CGDataConsumer(url: out as CFURL)!, mediaBox: &page, nil))
        let font = PDFExporter.makeTextLayerFont()
        let texts = (0..<40).map { "Line \($0): the cause of the motion" }
        for _ in 0..<3 {                                        // three pages
            ctx.beginPage(mediaBox: &page)
            let lines = texts.enumerated().map { i, t in
                // Heights vary per line, as OCR boxes do.
                OCRService.Line(text: t, box: CGRect(x: 0.1, y: 0.95 - Double(i) * 0.022,
                                                     width: 0.8, height: 0.012 + Double(i % 7) * 0.001))
            }
            PDFExporter.drawTextLayer(lines, in: ctx, pageSize: page.size, font: font)
            ctx.endPage()
        }
        ctx.closePDF()

        let data = try Data(contentsOf: out)
        let descriptors = data.ranges(of: Data("/Type /FontDescriptor".utf8)).count
        #expect(descriptors == 1)
        let text = try #require(PDFDocument(url: out)?.page(at: 1)?.string)
        #expect(text.contains("Line 7: the cause of the motion"))
        #expect(!text.contains("c a u s e"))
    }

    /// Draws `lines` on one 400 × 600 page and opens it.
    private func layerPage(_ lines: [OCRService.Line]) throws -> PDFPage {
        let out = Fixtures.url("textlayer-\(UUID().uuidString).pdf")
        var media = CGRect(x: 0, y: 0, width: 400, height: 600)
        let ctx = try #require(CGContext(consumer: CGDataConsumer(url: out as CFURL)!, mediaBox: &media, nil))
        ctx.beginPage(mediaBox: &media)
        PDFExporter.drawTextLayer(lines, in: ctx, pageSize: media.size, font: PDFExporter.makeTextLayerFont())
        ctx.endPage()
        ctx.closePDF()
        return try #require(PDFDocument(url: out)?.page(at: 0))
    }

    @Test("fi and fl read back in place, inside their words")
    func noLigatures() throws {
        // On Wallace 1957 the fi and fl glyphs landed at the page's bottom edge,
        // so "scientific" read back as "scienti c".
        let text = "the scientific method reflects first principles"
        let page = try layerPage([OCRService.Line(text: text, box: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.02))])
        let string = try #require(page.string) as NSString
        #expect(string as String == text, "\(string)")
        let line = try wordBox("method", on: page)
        for k in 0..<string.length where string.character(at: k) != 32 {
            let box = page.characterBounds(at: k)
            #expect(box.height > 1 && abs(box.midY - line.midY) < 2,
                    "\(string.substring(with: NSRange(location: k, length: 1))) at \(k): \(box) vs \(line)")
        }
    }

    private func wordBox(_ word: String, on page: PDFPage) throws -> CGRect {
        let range = ((page.string ?? "") as NSString).range(of: word)
        try #require(range.location != NSNotFound, "\(word) missing")
        return try #require(page.selection(for: range)).bounds(for: page)
    }

    @Test("Tightly spaced lines stay apart when read back")
    func tightLinesStayApart() throws {
        // Two footnote lines as OCR boxed them on Wallace 1957 (export page 15):
        // each box is taller than the gap between the two baselines.
        func line(_ text: String, x: Double, baseline: Double, height: Double) -> OCRService.Line {
            OCRService.Line(text: text, box: CGRect(x: x / 400, y: (baseline - 0.18 * height) / 600,
                                                    width: 0.85, height: height / 600))
        }
        let first = line("1 Phys., lect. 13, nn. 2-3; cf. lect. 10, n. 1. Note that in this and all subsequent",
                         x: 64.6, baseline: 120.2, height: 8.30)
        let second = line("demonstrations, no attempt is made to prove the premises or to indicate the",
                          x: 57.6, baseline: 112.4, height: 8.99)
        let page = try layerPage([first, second])

        let text = try #require(page.string)
        #expect(!text.contains("subsequentdemonstrations"))
        // Each line reads back whole, with its spaces.
        let read = try #require(page.selection(for: page.bounds(for: .mediaBox))).selectionsByLine()
            .map { ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(read == [first.text, second.text], "\(read)")
        let end = try wordBox("subsequent", on: page), start = try wordBox("demonstrations", on: page)
        #expect(end.height < 10 && start.height < 10, "\(end) \(start)")
        #expect(end.minY >= start.maxY - 0.01, "the lines' boxes overlap: \(end) \(start)")

        // Nothing moves sideways: each word sits where it does when its line is drawn alone.
        let alone = try wordBox("subsequent", on: try layerPage([first]))
        #expect(abs(end.minX - alone.minX) < 0.5 && abs(end.maxX - alone.maxX) < 0.5, "\(end) vs \(alone)")
    }

    /// A line from Vision's boxes in pixels (top-left origin) on a 1101 × 1668
    /// page image, drawn on the 400 × 600 test page.
    private func pixelLine(_ words: [(String, Double, Double, Double, Double)]) -> OCRService.Line {
        func box(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> CGRect {
            CGRect(x: x0 / 1101, y: 1 - y1 / 1668, width: (x1 - x0) / 1101, height: (y1 - y0) / 1668)
        }
        let ws = words.map { OCRService.Word(text: $0.0, box: box($0.1, $0.2, $0.3, $0.4)) }
        return OCRService.Line(text: ws.map(\.text).joined(separator: " "),
                               box: ws.map(\.box).reduce(.null) { $0.union($1) }, words: ws)
    }

    @Test("Each word lands on its own printed word")
    func wordsOnTheirBoxes() throws {
        // A table row on Wallace 1957 (export page 18): Helvetica set the line
        // wider than the print, so "motion" ran into the next cell's "is".
        let line = pixelLine([("local", 143, 207, 128, 158), ("motion", 210, 311, 128, 158),
                              ("is", 431, 459, 128, 158), ("Regular", 462, 557, 128, 158)])
        let page = try layerPage([line])
        #expect(page.string == line.text, "\(page.string ?? "")")
        for w in line.words {
            let got = try wordBox(w.text, on: page), want = w.box.applying(CGAffineTransform(scaleX: 400, y: 600))
            #expect(abs(got.minX - want.minX) < 0.5 && abs(got.maxX - want.maxX) < 0.5, "\(w.text): \(got) vs \(want)")
        }
    }

    @Test("A word narrower than a point still reads back")
    func narrowWord() throws {
        // Trimmed to its ink, an "I" at 600 DPI is under a point wide.
        let line = pixelLine([("I", 200, 202, 226, 256), ("agree", 212, 290, 226, 256)])
        #expect(try layerPage([line]).string == "I agree")
    }

    @Test("Table cells side by side read as separate words")
    func cellsApart() throws {
        // Wallace 1957, export page 25: two cells of a table row, OCR'd as
        // separate lines, with the print's gap (a third of the line's height).
        let left = pixelLine([("The", 200, 248, 226, 256), ("soul", 258, 312, 226, 256), ("is", 400, 420, 226, 256)])
        let right = pixelLine([("That", 430, 482, 226, 256), ("by", 492, 518, 226, 256)])
        let text = try #require(try layerPage([left, right]).string)
        #expect(text.contains("is That"), "\(text)")

        // Export page 19: "over" has no tall letters, so Vision boxed it half as
        // tall as the word before it, and a reader took it for a superscript.
        let word = pixelLine([("perpendicularly", 455, 615, 438, 467)]), over = pixelLine([("over", 639, 681, 442, 456)])
        let row = try #require(try layerPage([word, over]).string)
        #expect(row.contains("perpendicularly over"), "\(row)")
    }

    @Test("A drop cap's line stays on its own row")
    func dropCapLine() throws {
        // Wallace 1957, export page 4: Vision tilts the opening line to take in
        // the drop cap "A", so each of its words is boxed nearly two lines tall.
        let first = pixelLine([("AT", 168, 234, 512, 572), ("PRESENT", 240, 377, 507, 569), ("it", 382, 420, 506, 564),
                               ("is", 425, 448, 505, 563), ("generally", 453, 569, 501, 562), ("agreed", 574, 662, 497, 557),
                               ("that", 667, 719, 496, 554), ("modern", 724, 825, 492, 552),
                               ("science", 831, 925, 488, 549), ("differs", 930, 1019, 485, 546)])
        let second = pixelLine([("radically", 216, 343, 550, 581), ("from", 346, 416, 550, 579), ("the", 419, 466, 550, 579),
                                ("science", 470, 564, 549, 579), ("of", 568, 600, 549, 578), ("nature", 604, 695, 548, 578),
                                ("developed", 698, 832, 547, 577), ("in", 836, 869, 547, 576), ("the", 872, 923, 546, 576),
                                ("Aristo-", 926, 1016, 546, 576)])
        let third = pixelLine([("telian-Thomistic", 170, 380, 580, 610), ("tradition.", 384, 514, 579, 609)])
        let page = try layerPage([first, second, third])
        let read = try #require(page.selection(for: page.bounds(for: .mediaBox))).selectionsByLine()
            .map { ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(read == [first.text, second.text, third.text], "\(read)")

        // A drop cap read as a line of its own, as tall as the three lines it
        // sits beside, still reads back.
        let cap = pixelLine([("A", 150, 230, 500, 610)])
        let text = try #require(try layerPage([cap, first, second, third]).string)
        #expect(text.split(whereSeparator: \.isWhitespace).contains("A"), "\(text)")

        // Where a box gives way doesn't depend on the order the lines come in.
        let tall = pixelLine([("cap", 150, 230, 500, 600)])
        let upper = pixelLine([("upper", 150, 400, 500, 540)]), lower = pixelLine([("lower", 150, 400, 540, 570)])
        let one = try wordBox("cap", on: try layerPage([tall, upper, lower]))
        let other = try wordBox("cap", on: try layerPage([tall, lower, upper]))
        #expect(abs(one.minY - other.minY) < 0.1 && abs(one.maxY - other.maxY) < 0.1, "\(one) vs \(other)")
    }

    @Test("A line over several pieces of one row shrinks once, not once per piece")
    func lineOverPieces() throws {
        let wide = OCRService.Line(text: "all subsequent demonstrations of the science of nature",
                                   box: CGRect(x: 0.1, y: (120.2 - 0.18 * 9) / 600, width: 0.8, height: 9.0 / 600))
        // The row below, read as separate pieces (or duplicates), 7.8 pt lower.
        let pieces = [0.1, 0.35, 0.6].map { x in
            OCRService.Line(text: "piece", box: CGRect(x: x, y: (112.4 - 0.18 * 9) / 600, width: 0.2, height: 9.0 / 600))
        }
        let one = try wordBox("subsequent", on: try layerPage([wide, pieces[0]]))
        let three = try wordBox("subsequent", on: try layerPage([wide] + pieces))
        #expect(abs(one.height - three.height) < 0.5, "\(one) vs \(three)")
    }
}

@Suite("Existing text")
struct ExistingTextTests {

    /// Page 1 has real text; page 2 is a scan without any.
    private func mixedPDF(_ name: String) throws -> PDFDocument {
        let media = CGRect(x: 0, y: 0, width: 400, height: 600)
        let url = Fixtures.writePDF(name, media: media, pages: [
            { Fixtures.drawText("Existing words", in: $0, at: CGPoint(x: 40, y: 500)) },
            { $0.draw(Fixtures.scan(1000, 1500), in: media) },
        ])
        return try #require(PDFDocument(url: url))
    }

    private func scanOnlyPDF(_ name: String) throws -> PDFDocument {
        let media = CGRect(x: 0, y: 0, width: 400, height: 600)
        let url = Fixtures.writePDF(name, media: media, pages: [{ $0.draw(Fixtures.scan(1000, 1500), in: media) }])
        return try #require(PDFDocument(url: url))
    }

    @Test("A PDF with a text layer is noticed; a plain scan isn't")
    func detectsText() throws {
        #expect(PDFExporter.hasText(try mixedPDF("has-text-\(UUID().uuidString).pdf")))
        #expect(!PDFExporter.hasText(try scanOnlyPDF("no-text-\(UUID().uuidString).pdf")))
    }

    @Test("Opening a PDF with text says so; the sample book doesn't")
    @MainActor
    func loadSaysSo() async throws {
        let doc = try mixedPDF("load-text-\(UUID().uuidString).pdf")
        let m = testModel()
        m.load(url: try #require(doc.documentURL)); await waitUntilIdle(m)
        await m.textCheck?.value   // runs in the background, apart from analysis
        #expect(m.sourceHasText)
        #expect(m.statusText.contains("already has text"), "\(m.statusText)")
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        await m.textCheck?.value
        #expect(!m.sourceHasText)
        #expect(!m.statusText.contains("already has text"))
    }
}
