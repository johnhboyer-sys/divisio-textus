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

    @Test("Keep page resolution: a page with no scan renders at 300 DPI whatever the slider says")
    func unknownScanDPIFallsBackTo300() {
        var s = PDFExporter.Settings()
        s.dpi = 450
        s.matchScanResolution = true
        #expect(PDFExporter.renderDPI(scanDPI: nil, settings: s) == 300)
        #expect(PDFExporter.renderDPI(scanDPI: 1200, settings: s) == 600)
        #expect(PDFExporter.renderDPI(scanDPI: 72, settings: s) == 150)
        s.matchScanResolution = false
        #expect(PDFExporter.renderDPI(scanDPI: nil, settings: s) == 450)
        #expect(PDFExporter.renderDPI(scanDPI: 1200, settings: s) == 450)
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

    @Test("Progress moves as each page is read and reaches the end only once it's written")
    func progressPerPageRead() throws {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = Fixtures.writePDF("progress-src.pdf", media: letter, pages: [
            { $0.draw(Fixtures.scan(1275, 1650), in: letter) },
            { $0.draw(Fixtures.scan(1275, 1650), in: letter) }
        ])
        let doc = try #require(PDFDocument(url: url))
        let pages = (0..<2).map { BookPage(sourceIndex: $0, classification: .single, leftCrop: .full, analyzed: true) }
        let lock = NSLock()
        var ticks: [Int] = []
        _ = try PDFExporter.export(pages: pages, from: doc, to: Fixtures.url("progress-out.pdf"), settings: PDFExporter.Settings()) { done, _ in
            lock.withLock { ticks.append(done) }
        }
        #expect(ticks == [1, 1, 2])   // one read, the other read (held below the end), written
    }

    @Test("The time estimate leaves out the wait for the first page")
    func estimateSkipsStartupWait() {
        // Vision sat for a minute, then read a page every 0.7 s.
        let start = Date(timeIntervalSince1970: 0)
        let first = start.addingTimeInterval(60)
        let now = first.addingTimeInterval(0.7 * 9)   // 10 pages done
        let left = AppModel.exportTimeLeft(firstPageAt: first, now: now, done: 10, total: 34)
        #expect(abs((left ?? 0) - 0.7 * 24) < 0.01)
        // Too few pages to tell: no estimate.
        #expect(AppModel.exportTimeLeft(firstPageAt: first, now: first, done: 3, total: 34) == nil)
        #expect(AppModel.exportTimeLeft(firstPageAt: first, now: now, done: 34, total: 34) == nil)
        #expect(AppModel.exportTimeLeft(firstPageAt: nil, now: now, done: 10, total: 34) == nil)
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

    /// A w x h image, 8-bit gray or RGB, filled by `value(x, y)`.
    private func image(_ w: Int, _ h: Int, gray: Bool, _ value: (Int, Int) -> [UInt8]) -> CGImage {
        let n = gray ? 1 : 4
        var px = [UInt8](repeating: 0, count: w * h * n)
        for y in 0..<h { for x in 0..<w {
            let v = value(x, y)
            for c in 0..<n { px[(y * w + x) * n + c] = v[min(c, v.count - 1)] }
        } }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * n, bytesPerRow: w * n,
                       space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: gray ? 0 : CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test("A pure black-and-white gray page packs to 1 bit and draws the same")
    func blackAndWhitePacks() throws {
        let src = image(13, 5, gray: true) { x, y in [(x + y) % 3 == 0 ? 0 : 255] }   // width not a multiple of 8
        let bits = try #require(PDFExporter.blackAndWhiteBits(src))
        #expect(bits.bitsPerComponent == 1)
        #expect(HillClimb.gray(bits) == HillClimb.gray(src))
    }

    @Test("A page with any other gray, or with color, is not packed")
    func otherPagesNotPacked() {
        let grayish = image(16, 4, gray: true) { x, y in [x == 3 && y == 2 ? 254 : 255] }
        #expect(PDFExporter.blackAndWhiteBits(grayish) == nil)
        // Red ink on white: color stays color.
        let red = image(16, 4, gray: false) { x, y in x == 3 && y == 2 ? [255, 0, 0] : [255, 255, 255] }
        #expect(PDFExporter.blackAndWhiteBits(red) == nil)
    }

    /// A turned page in black and white, its scan claiming `ppi`: the DPI its export was made at.
    private func turnedBlackAndWhiteDPI(ppi: Double, _ name: String) throws -> Double {
        let media = CGRect(x: 0, y: 0, width: 600 * 72 / ppi, height: 800 * 72 / ppi)
        let url = Fixtures.writePDF(name + "-src.pdf", media: media, pages: [{ $0.draw(Fixtures.scan(600, 800), in: media) }])
        let doc = try #require(PDFDocument(url: url))
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, leftSkew: 0.5, analyzed: true)
        var s = noOCR
        s.enhanceMode = .blackAndWhite
        let out = Fixtures.url(name + "-out.pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: s)
        let made = try #require(PDFDocument(url: out)?.page(at: 0))
        return try #require(PDFRenderer.scanDPI(of: made))
    }

    @Test("A turned page's black and white is made twice as fine, but not past two pixels to the scan's one")
    func fineRenderStopsAtTwiceTheScan() throws {
        // 150 ppi: the render holds the scan's own pixels, so it is made at 300.
        #expect(abs(try turnedBlackAndWhiteDPI(ppi: 150, "fine150") - 300) < 1)
        // 72 ppi (Cherniss claims this): the 150 DPI render already holds two pixels to one.
        #expect(abs(try turnedBlackAndWhiteDPI(ppi: 72, "fine72") - 150) < 1)
    }

    /// Bits per component of the first image the exported page draws.
    private func imageBits(_ url: URL) throws -> Int {
        let doc = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(doc.page(at: 1)?.dictionary)
        var res: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(page, "Resources", &res))
        #expect(CGPDFDictionaryGetDictionary(try #require(res), "XObject", &xobjects))
        var bits = -1
        CGPDFDictionaryApplyBlock(try #require(xobjects), { _, object, _ in
            var stream: CGPDFStreamRef?
            guard bits < 0, CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return true }
            var n: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &n) { bits = n }
            return true
        }, nil)
        return bits
    }

    /// A turned letter page in `mode`, its scan black bars on white, with a gray patch if `toned`.
    private func turnedExportBits(_ mode: EnhanceMode, toned: Bool, _ name: String) throws -> Int {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let scan = Fixtures.image(2550, 3300, gray: true) { c in
            c.draw(Fixtures.scan(2550, 3300), in: CGRect(x: 0, y: 0, width: 2550, height: 3300))
            if toned { c.setFillColor(CGColor(gray: 0.5, alpha: 1)); c.fill(CGRect(x: 600, y: 600, width: 900, height: 600)) }
        }
        let url = Fixtures.writePDF(name + "-src.pdf", media: letter, pages: [{ $0.draw(scan, in: letter) }])
        let doc = try #require(PDFDocument(url: url))
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, leftSkew: 0.5, analyzed: true)
        var s = noOCR
        s.enhanceMode = mode
        let out = Fixtures.url(name + "-out.pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: s)
        return try imageBits(out)
    }

    @Test("A black and white scan stays 1 bit in Color and Gray when straightened; a toned one keeps its grays")
    func bitonalScanStaysBitonal() throws {
        #expect(try turnedExportBits(.color, toned: false, "bitonal-color") == 1)
        #expect(try turnedExportBits(.grayscale, toned: false, "bitonal-gray") == 1)
        #expect(try turnedExportBits(.color, toned: true, "toned-color") == 8)
    }

    @Test("A 1-bit scan claiming 72 ppi stays 1 bit in Color though its drawing blurs it")
    func lowResolutionBitonalScanStaysBitonal() throws {
        // Drawn at 150 DPI from 72 ppi, the render holds grays; the scan's own image is 1 bit.
        let w = 600, h = 800, rowBytes = (w + 7) / 8
        var bits = [UInt8](repeating: 0xFF, count: rowBytes * h)
        for y in stride(from: 100, to: 700, by: 20) { for x in 60..<540 where (x / 7) % 3 != 0 { bits[y * rowBytes + x / 8] &= ~(0x80 >> UInt8(x % 8)) } }
        let provider = try #require(CGDataProvider(data: Data(bits) as CFData))
        let scan = try #require(CGImage(width: w, height: h, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let media = CGRect(x: 0, y: 0, width: w, height: h)      // 72 ppi
        let url = Fixtures.writePDF("bitonal72-src.pdf", media: media, pages: [{ $0.draw(scan, in: media) }])
        let doc = try #require(PDFDocument(url: url))
        #expect(PDFRenderer.isBitonalScan(try #require(doc.page(at: 0))))
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, leftSkew: 0.5, analyzed: true)
        let out = Fixtures.url("bitonal72-out.pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: noOCR)
        #expect(try imageBits(out) == 1)
    }

    @Test("A page claiming 20 inches or more is drawn at the scan's own pixels, in Color and in black and white")
    func oversizeClaimKeepsScanPixels() throws {
        // Cherniss: 72 ppi claimed, 36 inches tall. Its real resolution is about four times that.
        let w = 1800, h = 2600, rowBytes = (w + 7) / 8
        var bits = [UInt8](repeating: 0xFF, count: rowBytes * h)
        for y in stride(from: 200, to: 2400, by: 40) { for x in 200..<1600 where (x / 9) % 4 != 0 { bits[y * rowBytes + x / 8] &= ~(0x80 >> UInt8(x % 8)) } }
        let provider = try #require(CGDataProvider(data: Data(bits) as CFData))
        let scan = try #require(CGImage(width: w, height: h, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let media = CGRect(x: 0, y: 0, width: w, height: h)
        let url = Fixtures.writePDF("oversize-src.pdf", media: media, pages: [{ $0.draw(scan, in: media) }])
        let doc = try #require(PDFDocument(url: url))
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, leftSkew: 0.5, analyzed: true)
        for mode in [EnhanceMode.color, .blackAndWhite] {
            var s = noOCR
            s.enhanceMode = mode
            let out = Fixtures.url("oversize-\(mode)-out.pdf")
            _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: s)
            let made = try #require(PDFDocument(url: out)?.page(at: 0))
            #expect(abs(try #require(PDFRenderer.scanDPI(of: made)) - 72) < 1, "\(mode)")
        }
        // A page of ordinary size at 72 ppi keeps the 150 DPI floor.
        #expect(abs(try turnedBlackAndWhiteDPI(ppi: 72, "floor72") - 150) < 1)
    }

    @Test("Batches stop at the byte budget but keep small pages together")
    func batchPlanner() {
        let big = 12_000 * 12_000 * 4          // one 600 DPI scan: about 576 MB
        let budget = PDFExporter.batchByteBudget
        let huge = PDFExporter.planBatches(sizes: Array(repeating: big, count: 8), maxPages: 8)
        #expect(huge == [0..<2, 2..<4, 4..<6, 6..<8])
        for r in huge.dropLast() { #expect(r.count * big >= budget && (r.count - 1) * big < budget) }
        // One page over the budget still goes alone.
        #expect(PDFExporter.planBatches(sizes: [3 * budget, 1, 1], maxPages: 8) == [0..<1, 1..<3])
        // Small pages group up to the page cap, in order.
        let small = PDFExporter.planBatches(sizes: Array(repeating: 10_000_000, count: 20), maxPages: 8)
        #expect(small == [0..<8, 8..<16, 16..<20])
        #expect(PDFExporter.planBatches(sizes: [], maxPages: 8).isEmpty)
    }
}
