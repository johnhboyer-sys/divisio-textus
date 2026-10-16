import Testing
import Foundation
import PDFKit
@testable import PDFCropper

@Suite("Export")
struct ExportTests {

    /// One full-page 300 DPI letter scan, as a single page cropped to everything.
    private func letterScan(_ name: String) throws -> (PDFDocument, [BookPage]) {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = Fixtures.writePDF(name, media: letter, pages: [{ $0.draw(Fixtures.scan(2550, 3300), in: letter) }])
        let doc = try #require(PDFDocument(url: url))
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        return (doc, [page])
    }

    private var noOCR: PDFExporter.Settings {
        var s = PDFExporter.Settings()
        s.ocr = false
        return s
    }

    @Test("Pages keep their physical size at the scan's own resolution")
    func physicalPageSize() throws {
        let (doc, pages) = try letterScan("size-src.pdf")
        let out = Fixtures.url("size-out.pdf")
        let report = try PDFExporter.export(pages: pages, from: doc, to: out, settings: noOCR)
        #expect(report.pageCount == 1)
        let box = try #require(PDFDocument(url: out)?.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - 612) < 1 && abs(box.height - 792) < 1)   // 8.5 x 11 in
    }

    @Test("Cancelling leaves an existing destination untouched")
    func cancelKeepsDestination() throws {
        let (doc, pages) = try letterScan("cancel-src.pdf")
        let out = Fixtures.url("cancel-out.pdf")
        try Data("previous".utf8).write(to: out)
        #expect(throws: PDFExporter.ExportError.self) {
            try PDFExporter.export(pages: pages, from: doc, to: out, settings: noOCR, isCancelled: { true })
        }
        #expect(try Data(contentsOf: out) == Data("previous".utf8))
    }

    @Test("Nothing to export is an error, and the model disables Export")
    @MainActor
    func nothingToExport() async throws {
        let (doc, pages) = try letterScan("empty-src.pdf")
        var skipped = pages[0]; skipped.classification = .skip
        #expect(throws: PDFExporter.ExportError.self) {
            try PDFExporter.export(pages: [skipped], from: doc, to: Fixtures.url("empty-out.pdf"), settings: noOCR)
        }
        let m = testModel()
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        #expect(m.canExport)
        for p in m.pages { m.setClassification(.skip, for: p.id) }
        #expect(m.outputPageCount == 0 && !m.canExport)
    }

    @Test("Exporting over the source file gives a valid PDF")
    @MainActor
    func exportOverSource() async throws {
        let m = testModel()
        let src = Fixtures.sampleBook()
        m.load(url: src); await waitUntilIdle(m)
        m.export(to: src); await waitUntilIdle(m)
        #expect(PDFDocument(url: src)?.pageCount == 11)
        #expect(!m.isExporting)
    }

    @Test("Right-to-left swaps each spread's pages; skipping drops them")
    @MainActor
    func readingOrderAndSkip() async throws {
        let m = testModel()
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        let ltr = try #require(await exportAndOpen(m, "ltr.pdf"))
        m.direction = .rightToLeft
        let rtl = try #require(await exportAndOpen(m, "rtl.pdf"))
        func size(_ d: PDFDocument, _ i: Int) -> CGSize { d.page(at: i)!.bounds(for: .mediaBox).size }
        #expect(ltr.pageCount == 11 && rtl.pageCount == 11)
        // Page 1 is a single; the first spread gives output pages 2 and 3.
        #expect(size(ltr, 1) == size(rtl, 2) && size(ltr, 2) == size(rtl, 1))

        m.direction = .leftToRight
        m.setClassification(.skip, for: m.pages[1].id)
        let skipped = try #require(await exportAndOpen(m, "skip.pdf"))
        #expect(skipped.pageCount == 9)
    }
}
