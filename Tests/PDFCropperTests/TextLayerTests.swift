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
