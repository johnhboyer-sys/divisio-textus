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
