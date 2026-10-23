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
        #expect(m.sourceHasText)
        #expect(m.statusText.contains("already has text"), "\(m.statusText)")
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        #expect(!m.sourceHasText)
        #expect(!m.statusText.contains("already has text"))
    }

    /// "OCR" that reads every page as one line.
    private func fakeOCR(_ calls: Counter? = nil, _ text: String = "Added by OCR") -> (CGImage) -> OCRService.Recognition? {
        { _ in
            calls?.add()
            return OCRService.Recognition(lines: [OCRService.Line(text: text, box: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.03))],
                                          complete: true)
        }
    }

    @Test("OCR only: every page is read again, and old text is replaced, not kept")
    func replacesExistingText() throws {
        let doc = try mixedPDF("redo-text-\(UUID().uuidString).pdf")
        let out = Fixtures.url("redo-text-out-\(UUID().uuidString).pdf")
        let calls = Counter()
        let report = try PDFExporter.exportAsTheyAre(from: doc, to: out, settings: PDFExporter.Settings(), recognize: fakeOCR(calls))
        #expect(calls.value == 2)
        #expect(report.pageCount == 2 && report.ocrFailedPages.isEmpty)
        let result = try #require(PDFDocument(url: out))
        for i in 0..<2 {
            let text = result.page(at: i)?.string ?? ""
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "Added by OCR", "page \(i + 1): \(text)")
        }
        // The page that had text still looks the same and keeps its size.
        let a = try #require(doc.page(at: 0)), b = try #require(result.page(at: 0))
        #expect(PDFRenderer.displaySize(of: a) == PDFRenderer.displaySize(of: b))
        let ra = try #require(PDFRenderer.renderCGImage(page: a, dpi: 72))
        let rb = try #require(PDFRenderer.renderCGImage(page: b, dpi: 72))
        #expect(Fixtures.difference(ra, rb) < 3)
    }

    @Test("OCR only: text OCRmyPDF wrote comes out as the new reading only, no junk")
    func replacesOCRmyPDFText() throws {
        let src = try #require(PDFDocument(url: Fixtures.ocrmypdfWords()))
        #expect(src.page(at: 0)?.string?.contains("Philosophical Physics") == true)   // the source reads fine
        let out = Fixtures.url("ocrmypdf-out-\(UUID().uuidString).pdf")
        _ = try PDFExporter.exportAsTheyAre(from: src, to: out, settings: PDFExporter.Settings(),
                                            recognize: fakeOCR(nil, "Philosophical Physics"))
        let text = try #require(PDFDocument(url: out)?.page(at: 0)?.string)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "Philosophical Physics", "\(text)")
    }

    @Test("OCR only: pages Vision fails on are reported")
    func reportsFailedPages() throws {
        let doc = try mixedPDF("fail-text-\(UUID().uuidString).pdf")
        let out = Fixtures.url("fail-text-out-\(UUID().uuidString).pdf")
        let report = try PDFExporter.exportAsTheyAre(from: doc, to: out, settings: PDFExporter.Settings(), recognize: { _ in nil })
        #expect(report.ocrFailedPages == [1, 2])
    }
}

/// Counts calls from several threads at once.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}
