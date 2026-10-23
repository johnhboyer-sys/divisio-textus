import Testing
import Foundation
import PDFKit
import ImageIO
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

    @Test("Exporting over the scan is refused and leaves it as it was")
    @MainActor
    func exportOverSource() async throws {
        let m = testModel()
        let src = Fixtures.sampleBook()
        m.load(url: src); await waitUntilIdle(m)
        m.export(to: src); await waitUntilIdle(m)
        #expect(PDFDocument(url: src)?.pageCount == 6)
        #expect(!m.isExporting && m.statusText.contains("another name"))
    }

    @Test("Exported pages carry the right book page, in reading order either way (review finding 16)")
    @MainActor
    func readingOrderByContent() async throws {
        // Two spreads; each book page has its own number of lines of "text" (3, 5,
        // 7, 9), so counting an output page's lines says which book page it is.
        let media = CGRect(x: 0, y: 0, width: 1000, height: 650)
        let lines = [[3, 5], [7, 9]]
        let url = Fixtures.writePDF("order-\(UUID().uuidString).pdf", media: media, pages: lines.map { pair in
            { c in
                c.setFillColor(CGColor(gray: 0.1, alpha: 1))
                for (k, n) in pair.enumerated() {
                    for r in 0..<n { c.fill(CGRect(x: 80 + Double(k) * 480, y: 560 - Double(r) * 40, width: 360, height: 12)) }
                }
            }
        })
        let m = testModel()
        m.load(url: url); await waitUntilIdle(m)
        #expect(m.pages.allSatisfy { $0.classification == .spread })
        func order(_ d: PDFDocument) -> [Int] {
            (0..<d.pageCount).map { i in
                let cg = PDFRenderer.renderCGImage(page: d.page(at: i)!, dpi: 72)!
                let g = GrayBuffer(cgImage: cg, maxDim: max(cg.width, cg.height))!
                // Runs of rows with ink across the middle of the page.
                var runs = 0, inRun = false
                for y in 0..<g.height {
                    let ink = Double(g.value(g.width / 2, y)) < 128
                    if ink && !inRun { runs += 1 }
                    inRun = ink
                }
                return [3, 5, 7, 9].firstIndex(of: runs) ?? -runs
            }
        }
        let ltr = try #require(await exportAndOpen(m, "order-ltr.pdf"))
        #expect(order(ltr) == [0, 1, 2, 3], "\(order(ltr))")
        m.direction = .rightToLeft
        let rtl = try #require(await exportAndOpen(m, "order-rtl.pdf"))
        #expect(order(rtl) == [1, 0, 3, 2], "\(order(rtl))")
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

    /// Three unlike pages: a JPEG scan, vector drawing at another size, and a page
    /// turned a quarter with a crop box inside its media box.
    private func mixedSource() throws -> PDFDocument {
        let tall = CGRect(x: 0, y: 0, width: 400, height: 600)
        let jpeg = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, Fixtures.scan(800, 1200), [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let photo = try #require(CGImage(jpegDataProviderSource: CGDataProvider(data: jpeg)!, decode: nil,
                                         shouldInterpolate: true, intent: .defaultIntent))
        let drawn = Fixtures.writePDF("mixed-drawn-\(UUID().uuidString).pdf", media: tall, pages: [
            { $0.draw(photo, in: tall) },
            { c in
                c.setFillColor(CGColor(gray: 0.2, alpha: 1))
                c.fill(CGRect(x: 30, y: 40, width: 200, height: 20))
                c.fill(CGRect(x: 30, y: 200, width: 400, height: 60))
            },
            { c in
                c.setFillColor(CGColor(gray: 0, alpha: 1))
                c.fill(CGRect(x: 40, y: 480, width: 80, height: 80))       // marker, top left
                for i in 0..<10 { c.fill(CGRect(x: 60, y: 80 + Double(i) * 30, width: 280, height: 8)) }
            },
        ])
        // Page sizes and turns are set with PDFKit, as other apps write them.
        let doc = try #require(PDFDocument(url: drawn))
        doc.page(at: 1)?.setBounds(CGRect(x: 0, y: 0, width: 500, height: 300), for: .mediaBox)
        doc.page(at: 2)?.rotation = 90
        doc.page(at: 2)?.setBounds(CGRect(x: 20, y: 30, width: 360, height: 540), for: .cropBox)
        let url = Fixtures.url("mixed-src-\(UUID().uuidString).pdf")
        #expect(doc.write(to: url))
        return try #require(PDFDocument(url: url))
    }

    @Test("Add text only keeps every page as it is: count, size, turn, images and vectors")
    func textOnlyKeepsPages() throws {
        let src = try mixedSource()
        let out = Fixtures.url("text-only-\(UUID().uuidString).pdf")
        let report = try PDFExporter.addTextLayer(from: src, to: out, settings: noOCR)
        let result = try #require(PDFDocument(url: out))
        #expect(report.pageCount == 3 && result.pageCount == 3)
        for i in 0..<3 {
            let a = try #require(src.page(at: i)), b = try #require(result.page(at: i))
            let sa = PDFRenderer.displaySize(of: a), sb = PDFRenderer.displaySize(of: b)
            #expect(abs(sa.width - sb.width) < 0.5 && abs(sa.height - sb.height) < 0.5, "page \(i + 1): \(sa) vs \(sb)")
            let ra = try #require(PDFRenderer.renderCGImage(page: a, dpi: 72))
            let rb = try #require(PDFRenderer.renderCGImage(page: b, dpi: 72))
            #expect(Fixtures.difference(ra, rb) < 2, "page \(i + 1) looks different")
        }
        // The JPEG goes in byte for byte, not decoded and encoded again.
        let before = Fixtures.imageStreams(try #require(src.page(at: 0)?.pageRef))
        let after = Fixtures.imageStreams(try #require(result.page(at: 0)?.pageRef))
        #expect(before.count == 1 && after.count == 1)
        #expect(after.first?.format == .jpegEncoded && after.first?.data == before.first?.data)
        // Vector drawing stays vector: no image appears on that page.
        #expect(Fixtures.imageStreams(try #require(result.page(at: 1)?.pageRef)).isEmpty)
    }

    @Test("Add text only from the app: one page per source page, never over the scan")
    @MainActor
    func textOnlyFromModel() async throws {
        let m = testModel()
        let src = Fixtures.sampleBook()
        m.load(url: src); await waitUntilIdle(m)
        m.exportMode = .textOnly
        m.setClassification(.skip, for: m.pages[1].id)       // doesn't apply to this export
        #expect(m.outputPageCount == 6 && m.canExport)
        let doc = try #require(await exportAndOpen(m, "text-only-model.pdf"))
        #expect(doc.pageCount == 6)
        #expect(m.statusText.hasPrefix("Exported"), "\(m.statusText)")
        m.export(to: src); await waitUntilIdle(m)
        #expect(PDFDocument(url: src)?.pageCount == 6)
        #expect(m.statusText.contains("another name"))
    }

    @Test("Add text only keeps what notes and marks show on a page (Codex review)")
    func textOnlyKeepsAnnotations() throws {
        let media = CGRect(x: 0, y: 0, width: 400, height: 600)
        let drawn = Fixtures.writePDF("note-drawn-\(UUID().uuidString).pdf", media: media, pages: [{ $0.draw(Fixtures.scan(400, 600), in: media) }])
        let doc = try #require(PDFDocument(url: drawn))
        let mark = PDFAnnotation(bounds: CGRect(x: 100, y: 200, width: 200, height: 200), forType: .square, withProperties: nil)
        mark.color = .red
        mark.interiorColor = .red
        doc.page(at: 0)?.addAnnotation(mark)
        let srcURL = Fixtures.url("note-src-\(UUID().uuidString).pdf")
        #expect(doc.write(to: srcURL))
        let src = try #require(PDFDocument(url: srcURL))
        let out = Fixtures.url("note-out-\(UUID().uuidString).pdf")
        _ = try PDFExporter.addTextLayer(from: src, to: out, settings: noOCR)
        let srcPage = try #require(src.page(at: 0)), outPage = try #require(PDFDocument(url: out)?.page(at: 0))
        let a = try #require(PDFRenderer.renderCGImage(page: srcPage, dpi: 72))
        let b = try #require(PDFRenderer.renderCGImage(page: outPage, dpi: 72))
        #expect(Fixtures.difference(a, b) < 2)
    }

    @Test("Add text only puts the text where it was read, however the page is turned or cropped (Codex review)",
          arguments: [(90, CGRect(x: 20, y: 30, width: 360, height: 540)), (180, nil), (270, CGRect(x: 20, y: 30, width: 360, height: 540)),
                      (-90, nil), (0, CGRect(x: -100, y: -50, width: 600, height: 700))] as [(Int, CGRect?)])
    func textOnlyTextLandsOnPrint(rotation: Int, crop: CGRect?) throws {
        let media = CGRect(x: 0, y: 0, width: 400, height: 600)
        let drawn = Fixtures.writePDF("turn-drawn-\(UUID().uuidString).pdf", media: media, pages: [{ c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 60, y: 450, width: 80, height: 80))
        }])
        let doc = try #require(PDFDocument(url: drawn))
        doc.page(at: 0)?.rotation = rotation
        if let crop { doc.page(at: 0)?.setBounds(crop, for: .cropBox) }
        let srcURL = Fixtures.url("turn-src-\(UUID().uuidString).pdf")
        #expect(doc.write(to: srcURL))
        let src = try #require(PDFDocument(url: srcURL))

        /// The dark square's box in an image, as Vision gives boxes: 0–1, origin bottom left.
        func dark(_ image: CGImage) -> CGRect? {
            let g = GrayBuffer(cgImage: image, maxDim: max(image.width, image.height))!
            var x0 = g.width, y0 = g.height, x1 = -1, y1 = -1
            for y in 0..<g.height { for x in 0..<g.width where g.value(x, y) < 128 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            } }
            guard x1 >= 0 else { return nil }
            let w = Double(g.width), h = Double(g.height)
            return CGRect(x: Double(x0) / w, y: 1 - Double(y1 + 1) / h, width: Double(x1 - x0 + 1) / w, height: Double(y1 - y0 + 1) / h)
        }
        // "OCR" that reads the square as a word where it sees it.
        let out = Fixtures.url("turn-out-\(UUID().uuidString).pdf")
        _ = try PDFExporter.addTextLayer(from: src, to: out, settings: PDFExporter.Settings(), recognize: { image in
            OCRService.Recognition(lines: dark(image).map { [OCRService.Line(text: "MARKER", box: $0)] } ?? [], complete: true)
        })
        let page = try #require(PDFDocument(url: out)?.page(at: 0))
        let size = PDFRenderer.displaySize(of: page)
        let shown = PDFRenderer.displaySize(of: try #require(src.page(at: 0)))
        #expect(abs(size.width - shown.width) < 0.5 && abs(size.height - shown.height) < 0.5, "\(size) vs \(shown)")
        let render = try #require(PDFRenderer.renderCGImage(page: page, dpi: 72))
        let seen = try #require(dark(render))
        let square = CGRect(x: seen.minX * size.width, y: seen.minY * size.height,
                            width: seen.width * size.width, height: seen.height * size.height)
        let range = try #require(page.string?.range(of: "MARKER"))
        let text = try #require(page.selection(for: NSRange(range, in: page.string!))).bounds(for: page)
        #expect(square.contains(CGPoint(x: text.midX, y: text.midY)), "text at \(text), square at \(square)")
    }
}
