import Foundation
import PDFKit
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Compression

/// Builds the output PDF: one page per book page, sized to its own crop (never
/// scaled, never padded). Optionally overlays an invisible OCR text layer so the
/// PDF is searchable.
enum PDFExporter {

    /// The DPI a page renders at. With "Keep page resolution" on, the scan's own
    /// (kept within 150–600), or 300 for a page with no scanned image; `settings.dpi`
    /// only applies with it off.
    static let unknownScanDPI = 300.0
    static func renderDPI(scanDPI: Double?, settings: Settings) -> Double {
        guard settings.matchScanResolution else { return settings.dpi }
        return scanDPI.map { min(600, max(150, $0)) } ?? unknownScanDPI
    }

    struct Settings {
        var dpi: Double = 300            // export resolution when not matching the scan
        var matchScanResolution = true   // use each page's own scan resolution instead
        var jpegQuality: Double = 0.7    // for pages stored as JPEG (see encodeForPDF)
        var direction: ReadingDirection = .leftToRight
        var ocr: Bool = true             // embed searchable text layer
        var ocrLanguages: [String] = ["en-US"]
        var reader: OCRReader = .apple
        var packs: [String] = []
        var enhanceMode: EnhanceMode = .color  // color, grayscale or black and white
        /// Remove the fold's shadow, band, line and streaks (see ShadowRemoval).
        var removeShadows = false
        /// A layered scan's black and white takes ink from both its layers and drops
        /// shadows (`LayeredScan.inkPages`): in Black and white, or with Remove shadows.
        /// Otherwise its text layer alone, as before those options.
        var bothLayers: Bool { enhanceMode == .blackAndWhite || removeShadows }
        /// Straighten lines of print that curve into the binding (see Flatten). A scan
        /// stored in layers is measured on its text layer, and both layers take the warp.
        var flattenPages = false
    }

    /// Lets tests read installed packs without changing the user's pack folder.
    static var tessdataOverride: URL?

    enum ExportError: Error, LocalizedError {
        case noPages
        case sourceUnreadable
        case renderFailed(Int)
        case writeFailed
        case cancelled
        var errorDescription: String? {
            switch self {
            case .noPages: return "No pages to export."
            case .sourceUnreadable: return "Could not reopen the source PDF."
            case .renderFailed(let i): return "Failed to render source page \(i + 1)."
            case .writeFailed: return "Could not write the output PDF."
            case .cancelled: return "Export cancelled."
            }
        }
    }

    /// What the export produced. `ocrFailedPages` are 1-based output page numbers
    /// where the reader failed on all or part of the page, so it isn't fully searchable.
    struct Report {
        var pageCount = 0
        var ocrFailedPages: [Int] = []
    }

    /// Source pages handled per batch. Only one batch of rendered pages is held in
    /// memory at a time (rendering a whole book first needs several GB), and OCR —
    /// the slow step — runs on the batch's pages in parallel.
    private static let batchSize = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// A batch also stops growing once its pages' renders pass this many bytes, so a few
    /// huge scans can't fill memory. At least one page always goes in.
    static let batchByteBudget = 1 << 30

    /// Splits pages, given each one's estimated render size in bytes, into runs of at
    /// most `maxPages` pages that stop once their sizes add up to `budget` or more.
    static func planBatches(sizes: [Int], maxPages: Int = batchSize, budget: Int = batchByteBudget) -> [Range<Int>] {
        var batches: [Range<Int>] = []
        var start = 0
        while start < sizes.count {
            var end = start, bytes = 0
            repeat { bytes += sizes[end]; end += 1 } while end < sizes.count && end - start < maxPages && bytes < budget
            batches.append(start..<end)
            start = end
        }
        return batches
    }

    /// Progress callback receives (completedCrops, totalCrops), possibly from several
    /// threads, one at a time. With OCR a crop counts once it's read, the slow step, so
    /// the count moves within a batch; it reaches the total only once all are written.
    static func export(pages: [BookPage],
                       from document: PDFDocument,
                       to url: URL,
                       settings: Settings,
                       isCancelled: (() -> Bool)? = nil,
                       progress: ((Int, Int) -> Void)? = nil) throws -> Report {

        let todo = pages.filter { !$0.outputCrops(direction: settings.direction).isEmpty }
        let total = todo.reduce(0) { $0 + $1.outputCrops(direction: settings.direction).count }
        guard total > 0 else { throw ExportError.noPages }

        if settings.reader == .tesseract || !settings.packs.isEmpty {
            TesseractService.installBundledPacks()
        }
        let tessdata = settings.reader == .tesseract || !settings.packs.isEmpty
            ? (tessdataOverride ?? TesseractService.packFolder) : nil
        let executable = TesseractService.executableURL()
        let installed = tessdata.map { TesseractService.installedPacks(in: $0) } ?? []
        let extraPacks = TesseractLanguage.all.filter {
            $0.fillsIn && settings.packs.contains($0.code) && installed.contains($0.code)
        }
        /// Reads one page with the chosen reader and optional script fill-in.
        func recognize(_ image: CGImage) -> OCRService.Recognition? {
            if settings.reader == .tesseract {
                guard let tessdata else { return nil }
                let languages = TesseractService.readerLanguages(ticked: settings.packs, installed: installed)
                return TesseractService.recognize(image, languages: languages,
                                                 tessdata: tessdata, executable: executable)
            }
            guard var apple = OCRService.recognizeLines(image, languages: settings.ocrLanguages) else { return nil }
            guard !extraPacks.isEmpty else { return apple }
            if let tessdata, let tess = TesseractService.recognize(image, languages: extraPacks.map(\.code) + ["eng"],
                                                                  tessdata: tessdata, executable: executable) {
                apple.lines = OCRService.fillIn(apple.lines, from: tess.lines, scripts: extraPacks.compactMap(\.script)) {
                    OCRService.looksLikeWord($0, languages: ["en", "fr", "de"])
                }
            } else {
                apple.complete = false      // Apple's text stays, but the Greek (say) is missing
            }
            return apple
        }

        // Each page's media box is its own crop (no padding, no resampling), sized at
        // its render DPI so the page keeps its physical size: a 300 DPI crop 2550 px
        // wide is 8.5 in (612 pt), not 2550 pt.
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)

        // Write to a temporary file and move it into place at the end, so exporting
        // over the source PDF never reads and writes one file at once, and a failed
        // export leaves no half-written file behind.
        let fm = FileManager.default
        guard let tmpDir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                       appropriateFor: url, create: true) else {
            throw ExportError.writeFailed
        }
        defer { try? fm.removeItem(at: tmpDir) }
        let tmpURL = tmpDir.appendingPathComponent(url.lastPathComponent)

        guard let consumer = CGDataConsumer(url: tmpURL as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw ExportError.writeFailed
        }

        /// One source page's output pages: each made already or left as work (see step 1).
        enum Kind { case ready, layered, fine }
        struct Slot { var make: () -> CGImage?; var dpi: Double }
        struct PagePlan {
            var slots: [Slot]
            var kind: Kind
            var page: BookPage
            var pdfPage: PDFPage
            var dpi: Double
            /// A layered page's color render for its picture crops failed: an error,
            /// once its black and white is known to have worked.
            var colorFailed = false
            var pictures: [Bool] = []
            /// Whether black and white failed on a crop not holding a picture.
            func inkFailed(_ done: [CGImage?]) -> Bool {
                done.indices.contains { done[$0] == nil && !(pictures.indices.contains($0) && pictures[$0]) }
            }
        }
        /// A page not stored in layers, or one whose layers failed: made from its render.
        func plainPlan(_ page: BookPage, _ pdfPage: PDFPage, dpi: Double, fine: Bool) throws -> PagePlan {
            // Black and white of a straightened page at a low scan resolution
            // would turn the straightening's half pixels into steps that lean
            // upright strokes; it is made from a render twice as fine (a page
            // holding a picture is made as below).
            // Only the render needs PDFKit: straightening and cutting it (once, by the
            // first of the page's crops to need it) is part of each crop's work, and a
            // crop failing there fails the work (see step 1).
            let crops = page.outputCrops(direction: settings.direction).count
            let fineDPI = min(600, 2 * dpi)
            if fine, settings.enhanceMode == .blackAndWhite, dpi < 250,
               abs(page.leftSkew) >= 0.01 || (page.isSpread && abs(page.rightSkew) >= 0.01),
               let rendered = PDFRenderer.renderCGImage(page: pdfPage, dpi: fineDPI) {
                let out = LayeredScan.Once { outputImages(of: page, rendered: rendered, settings: settings) }
                // nil when it holds a picture: then none is made at this size.
                let slots = (0..<crops).map { k in
                    Slot(make: {
                        guard let image = out.value?[k] else { return nil }
                        let prepared = BlackAndWhite.prepare(image, dpi: fineDPI)
                        return prepared.picture ? nil
                            : BlackAndWhite.page(prepared, dpi: fineDPI, removeShadows: settings.removeShadows)
                    }, dpi: fineDPI)
                }
                return PagePlan(slots: slots, kind: .fine, page: page, pdfPage: pdfPage, dpi: dpi)
            }
            // A crop that fails would silently drop an output page: fail the export.
            guard let rendered = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi) else {
                throw ExportError.renderFailed(page.sourceIndex)
            }
            let out = LayeredScan.Once { outputImages(of: page, rendered: rendered, settings: settings) }
            let slots = (0..<crops).map { k in
                Slot(make: { out.value.map { finished($0[k], dpi: dpi, settings: settings) } }, dpi: dpi)
            }
            return PagePlan(slots: slots, kind: .ready, page: page, pdfPage: pdfPage, dpi: dpi)
        }
        func plan(_ page: BookPage) throws -> PagePlan {
            guard let pdfPage = document.page(at: page.sourceIndex) else {
                throw ExportError.renderFailed(page.sourceIndex)
            }
            // Render at the scan's own resolution when there is one: higher
            // would invent pixels, lower would throw detail away. Kept within
            // 150–600 DPI so OCR has enough to read and memory stays sane.
            let dpi = renderDPI(scanDPI: PDFRenderer.scanDPI(of: pdfPage), settings: settings)
            // A scan stored in layers gives its text layer alone, in black and
            // white at its own resolution, but for pages whose color layer
            // holds a picture: those keep the color export.
            if let layers = LayeredScan.layers(of: pdfPage) {
                let textDPI = LayeredScan.textDPI(layers)
                if settings.bothLayers {
                    if let work = LayeredScan.inkWork(of: page, pdfPage, layers: layers, direction: settings.direction,
                                                      removeShadows: settings.removeShadows,
                                                      flatten: settings.flattenPages) {
                        var color: [CGImage]?
                        if work.contains(where: { $0 == nil }) {
                            color = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi)
                                .flatMap { outputImages(of: page, rendered: $0, settings: settings) }
                        }
                        let slots = work.enumerated().map { k, make -> Slot in
                            if let make { return Slot(make: make, dpi: textDPI) }
                            // A picture page: never black and white.
                            return Slot(make: { color.map { pictureFinished($0[k], dpi: dpi, settings: settings) } }, dpi: dpi)
                        }
                        var plan = PagePlan(slots: slots, kind: .layered, page: page, pdfPage: pdfPage, dpi: dpi)
                        plan.colorFailed = work.contains(where: { $0 == nil }) && color == nil
                        plan.pictures = work.map { $0 == nil }
                        return plan
                    }
                } else if let text = LayeredScan.textPages(of: page, pdfPage, layers: layers,
                                                           direction: settings.direction,
                                                           bothLayers: false, removeShadows: settings.removeShadows,
                                                           flatten: settings.flattenPages) {
                    var color: [CGImage] = []
                    if text.contains(where: { $0 == nil }) {
                        guard let rendered = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi),
                              let out = outputImages(of: page, rendered: rendered, settings: settings) else {
                            throw ExportError.renderFailed(page.sourceIndex)
                        }
                        color = out
                    }
                    let slots = text.enumerated().map { k, image -> Slot in
                        if let image { return Slot(make: { image }, dpi: textDPI) }
                        // A picture page: never black and white.
                        return Slot(make: { pictureFinished(color[k], dpi: dpi, settings: settings) }, dpi: dpi)
                    }
                    return PagePlan(slots: slots, kind: .ready, page: page, pdfPage: pdfPage, dpi: dpi)
                }
            }
            return try plainPlan(page, pdfPage, dpi: dpi, fine: true)
        }

        var report = Report()
        let textFont = makeTextLayerFont()
        // Each page's render at export DPI, 4 bytes a pixel, sizes the batches.
        let renderBytes = todo.map { page -> Int in
            guard let pdfPage = document.page(at: page.sourceIndex) else { return 0 }
            let dpi = renderDPI(scanDPI: PDFRenderer.scanDPI(of: pdfPage), settings: settings)
            let box = pdfPage.bounds(for: .mediaBox)
            return Int(box.width * dpi / 72) * Int(box.height * dpi / 72) * 4
        }
        var pagesRead = 0
        let readLock = NSLock()
        for range in planBatches(sizes: renderBytes) {
            if isCancelled?() == true { throw ExportError.cancelled }
            let batch = todo[range]

            // 1. Render, straighten and crop serially: PDFKit can't draw one document
            //    from several threads at once. What needs no PDFKit (straightening,
            //    black and white, removing shadows) is left as work, done for the whole
            //    batch at once in parallel; the result is the same, made in any order.
            //    The autorelease pool matters: PDFKit autoreleases while drawing, and a
            //    background thread doesn't drain until the whole export ends, which
            //    kept every rendered page alive.
            var plans: [PagePlan] = []
            for page in batch {
                try autoreleasepool { plans.append(try plan(page)) }
            }
            let work = plans.indices.flatMap { p in plans[p].slots.indices.map { (p, $0) } }
            var made = [CGImage?](repeating: nil, count: work.count)
            made.withUnsafeMutableBufferPointer { made in
                DispatchQueue.concurrentPerform(iterations: work.count) { i in
                    autoreleasepool {
                        let (p, k) = work[i]
                        made[i] = plans[p].slots[k].make()
                    }
                }
            }
            var images: [CGImage] = []
            var dpis: [Double] = []
            var next = 0
            for var plan in plans {
                var done = Array(made[next..<(next + plan.slots.count)])
                next += plan.slots.count
                try autoreleasepool {
                    // A layered page whose black and white failed, or a fine black and
                    // white holding a picture, is made again as the page would have been
                    // without that path, its work done here.
                    while done.contains(where: { $0 == nil }) {
                        if plan.kind == .layered, plan.colorFailed, !plan.inkFailed(done) {
                            throw ExportError.renderFailed(plan.page.sourceIndex)
                        }
                        guard plan.kind != .ready else { throw ExportError.renderFailed(plan.page.sourceIndex) }
                        plan = try plainPlan(plan.page, plan.pdfPage, dpi: plan.dpi, fine: plan.kind == .layered)
                        done = plan.slots.map { $0.make() }
                    }
                }
                images += done.compactMap { $0 }
                dpis += plan.slots.map { $0.dpi }
            }

            // 2. OCR the batch in parallel. nil = the reader failed on the whole page;
            //    incomplete = it failed on part of it.
            let noText = OCRService.Recognition(lines: [], complete: true)
            var text = [OCRService.Recognition?](repeating: noText, count: images.count)
            if settings.ocr {
                text.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: images.count) { i in
                        out[i] = recognize(images[i])
                        readLock.withLock {
                            pagesRead += 1
                            let shown = min(pagesRead, total - 1)
                            if shown > 0 { progress?(shown, total) }
                        }
                    }
                }
                // Vision tends to fail while it warms up and then recover, so give
                // failed or partly failed pages one more try now that the rest of
                // the batch is done, keeping whichever result read more.
                for i in text.indices where text[i]?.complete != true {
                    guard let retry = recognize(images[i]) else { continue }
                    if retry.complete || retry.lines.count > (text[i]?.lines.count ?? -1) { text[i] = retry }
                }
            }

            if isCancelled?() == true { throw ExportError.cancelled }

            // 3. Write the batch in reading order. OCR above read the full-quality
            //    image; what goes into the file is the compact encoding of it, made
            //    for the batch's pages in parallel first.
            var encoded = [CGImage?](repeating: nil, count: images.count)
            encoded.withUnsafeMutableBufferPointer { encoded in
                DispatchQueue.concurrentPerform(iterations: images.count) { i in
                    autoreleasepool { encoded[i] = encodeForPDF(images[i], quality: settings.jpegQuality) }
                }
            }
            for (i, image) in images.enumerated() {
                let pointsPerPixel = 72.0 / dpis[i]
                var box = CGRect(x: 0, y: 0,
                                 width: Double(image.width) * pointsPerPixel,
                                 height: Double(image.height) * pointsPerPixel)
                ctx.beginPage(mediaBox: &box)
                ctx.draw(encoded[i] ?? image, in: box)
                report.pageCount += 1
                if let recognition = text[i] {
                    drawTextLayer(recognition.lines, in: ctx, pageSize: box.size, font: textFont)
                }
                if text[i]?.complete != true {
                    report.ocrFailedPages.append(report.pageCount)
                }
                ctx.endPage()
                if !settings.ocr || report.pageCount == total { progress?(report.pageCount, total) }
            }
        }
        ctx.closePDF()
        // Cancel pressed during the last batch: don't replace the destination.
        if isCancelled?() == true { throw ExportError.cancelled }
        // A file that isn't the PDF we just wrote must not replace the destination.
        guard isComplete(tmpURL, pageCount: report.pageCount) else { throw ExportError.writeFailed }
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: url)
            }
        } catch {
            throw ExportError.writeFailed
        }
        return report
    }

    /// One source page's output pages, in reading order, from its render: each half
    /// straightened (as the preview composite, so the crop boxes line up), in color
    /// or gray, flattened if the settings ask, cut to its crop. The Export view draws
    /// these too, from a small render. Nil when a crop fails.
    static func outputImages(of page: BookPage, rendered: CGImage, settings: Settings) -> [CGImage]? {
        let composite = ImageTransform.deskewedComposite(
            rendered, splitX: page.splitX,
            leftDegrees: page.leftSkew, rightDegrees: page.rightSkew,
            isSpread: page.isSpread)
        let enhanced = ImageEnhancer.apply(composite, mode: settings.enhanceMode)
        let flat = settings.flattenPages ? flattened(enhanced, page: page, direction: settings.direction) : nil
        var images: [CGImage] = []
        for (k, crop) in page.outputCrops(direction: settings.direction).enumerated() {
            // A crop that flattening left as it is comes from the page as it was.
            let source = flat.map { $0.changed[k] ? $0.image : enhanced } ?? enhanced
            guard let sub = PDFRenderer.crop(source, to: crop) else { return nil }
            images.append(sub)
        }
        return images
    }

    /// The straightened page with the print in each of its crops flattened (see Flatten),
    /// and which crops changed; nil when every crop is left as it is.
    static func flattened(_ image: CGImage, page: BookPage, direction: ReadingDirection) -> (image: CGImage, changed: [Bool])? {
        let size = CGSize(width: image.width, height: image.height)
        let regions = page.outputCrops(direction: direction).map { c -> (rect: CGRect, gutterOnRight: Bool?) in
            let c = c.normalized()
            return (c.pixelRect(in: size).integral, page.isSpread ? c.x + c.width / 2 < page.splitX : nil)
        }
        return Flatten.pages(image, regions: regions)
    }

    /// An output page of a scan not stored in layers, made black and white and its
    /// shadows removed as the settings ask. In black and white a page holding a
    /// picture stays gray (see `BlackAndWhite.page`). With `preview`, a small page:
    /// its ink is left gray.
    static func finished(_ image: CGImage, dpi: Double, settings: Settings, preview: Bool = false) -> CGImage {
        if settings.enhanceMode == .blackAndWhite,
           let bw = BlackAndWhite.page(image, dpi: dpi, preview: preview, removeShadows: settings.removeShadows) {
            return bw
        }
        return pictureFinished(image, dpi: dpi, settings: settings)
    }

    /// An output page that keeps its color or gray (a layered page whose color layer
    /// holds a picture, or a picture page in black and white), its shadows removed
    /// if the settings ask. The export and the Export view both make it here.
    static func pictureFinished(_ image: CGImage, dpi: Double, settings: Settings) -> CGImage {
        settings.removeShadows ? ShadowRemoval.page(image, dpi: dpi) ?? image : image
    }

    /// The page image to embed, in whichever form makes the smaller file. Pages
    /// that hold only grays (black-and-white or grayscale scans stored as RGB) are
    /// first converted to gray: a third of the data. Then JPEG versus lossless:
    /// photos and toned scans are far smaller as JPEG, but crisp black type on
    /// white compresses better losslessly (JPEG is poor at hard edges). Quartz
    /// stores a raw image with zlib (Flate) and a JPEG-backed image as-is, so
    /// compare the JPEG against zlib of the raw pixels and keep the smaller.
    private static func encodeForPDF(_ image: CGImage, quality: Double) -> CGImage {
        let source = ImageEnhancer.isEffectivelyGray(image)
            ? ImageEnhancer.apply(image, mode: .grayscale)
            : image
        // Pure black and white (a bitonal scan drawn at its own resolution): one bit
        // per pixel holds it exactly, and is far smaller than 8 bits.
        if let bits = blackAndWhiteBits(source) { return bits }
        let jpeg = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
            return source
        }
        CGImageDestinationAddImage(dest, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return source }
        // A JPEG under ~1/12 of the raw size means continuous tone (a photo, a toned
        // scan): lossless can't win there, so skip measuring it — slow on big plates.
        let rawBytes = source.bytesPerRow * source.height
        if jpeg.length * 12 > rawBytes, let lossless = zlibSize(of: source), lossless <= jpeg.length {
            return source
        }
        guard let provider = CGDataProvider(data: jpeg),
              let embedded = CGImage(jpegDataProviderSource: provider, decode: nil,
                                     shouldInterpolate: true, intent: .defaultIntent) else { return source }
        return embedded
    }

    /// A 1-bit copy of an 8-bit gray image whose pixels are all 0 or 255, else nil.
    static func blackAndWhiteBits(_ image: CGImage) -> CGImage? {
        guard image.bitsPerPixel == 8, image.bitsPerComponent == 8,
              image.colorSpace?.model == .monochrome, image.decode == nil,
              let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let w = image.width, h = image.height, stride = image.bytesPerRow
        guard CFDataGetLength(data) >= stride * h else { return nil }
        let rowBytes = (w + 7) / 8
        var packed = [UInt8](repeating: 0, count: rowBytes * h)
        // Eight pixels to a byte; a pixel neither 0 nor 255 (v + 1 over 1, wrapping) ends it.
        let pure = packed.withUnsafeMutableBufferPointer { out -> Bool in
            for y in 0..<h {
                let row = base + y * stride
                var other: UInt8 = 0
                for b in 0..<rowBytes {
                    var byte: UInt8 = 0
                    let x0 = b * 8, n = min(8, w - x0)
                    for k in 0..<n {
                        let v = row[x0 + k]
                        other |= (v &+ 1) > 1 ? 1 : 0
                        byte |= (v & 0x80) >> UInt8(k)
                    }
                    out[y * rowBytes + b] = byte
                }
                if other != 0 { return false }
            }
            return true
        }
        guard pure else { return nil }
        guard let provider = CGDataProvider(data: Data(packed) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Size of the image's raw pixels after zlib, as Quartz would store them.
    /// nil if it can't be measured or zlib doesn't shrink it at all.
    private static func zlibSize(of image: CGImage) -> Int? {
        guard let data = image.dataProvider?.data, CFDataGetLength(data) > 0 else { return nil }
        let count = CFDataGetLength(data)
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { out.deallocate() }
        let size = compression_encode_buffer(out, count, CFDataGetBytePtr(data), count, nil, COMPRESSION_ZLIB)
        return size > 0 ? size : nil   // 0 = didn't fit in `count` bytes, i.e. no gain
    }

    /// Draw the recognized text as invisible, selectable runs. `CTLineDraw`
    /// positions glyphs individually, so PDF text extraction reconstructs words
    /// from glyph gaps. The rules that keep copied text clean:
    ///   • each word Vision boxed is drawn on its own box, sized to it, with a
    ///     space glyph filling the gap to the next word. Set as one line,
    ///     Helvetica's widths drift from the print's, and in a table a word ran
    ///     into the next cell's ("motionis" on Wallace 1957). A thin space ends
    ///     the line too: a reader took a short line beside another ("over",
    ///     boxed only as tall as its letters) for a superscript and joined them;
    ///   • a line without word boxes is drawn whole, scaled the same in both
    ///     directions and shrunk to fit its width if needed. Stretching it
    ///     spreads the glyphs and yields "c a u s e". (Scale the context, not
    ///     the text matrix: CTLineDraw places glyphs at the font's own advances
    ///     and ignores the text matrix for that, which spreads the letters out.)
    ///   • where a box overlaps a shorter one on another line, it ends where the
    ///     shorter begins. Vision tilts a line to take in a drop cap, boxing its
    ///     words two lines tall, which put them on the line below;
    ///   • keep a line's glyphs (ascent + descent, as tall as the font size)
    ///     clear of its neighbours'. OCR boxes in tight print, like footnotes,
    ///     can be taller than the gap between baselines; PDFKit then reads the
    ///     two lines as one and runs the last word of one into the first of the
    ///     next. So where neighbours would overlap, only the height shrinks: the
    ///     baseline and the width stay put, so each word still covers its print.
    /// Every run uses the one `font` object made for the export, so the PDF
    /// embeds Helvetica once. (Making a font per line at that line's size usually
    /// got a cached font back, but under memory pressure each line embedded its
    /// own copy: about 1,000 copies and +7 MB on a 26-page book.)
    static func drawTextLayer(_ lines: [OCRService.Line], in ctx: CGContext, pageSize: CGSize, font: CTFont) {
        guard !lines.isEmpty else { return }
        let baseSize = CTFontGetSize(font)
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        ctx.textMatrix = .identity

        func onPage(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * pageSize.width, y: r.minY * pageSize.height,
                   width: r.width * pageSize.width, height: r.height * pageSize.height)
        }
        // What to draw: each boxed word, or the whole line, with the line it's on.
        var pieces: [(text: String, box: CGRect, line: Int, wordsFollow: Bool)] = []
        for (k, line) in lines.enumerated() {
            if line.words.isEmpty {
                pieces.append((line.text, onPage(line.box), k, false))
            } else {
                for (n, w) in line.words.enumerated() {
                    pieces.append((w.text, onPage(w.box), k, n < line.words.count - 1))
                }
            }
        }
        // Limits come from each box as Vision gave it, so the order the lines
        // come in doesn't matter.
        let boxes = pieces.map { p -> CGRect in
            var bottom = p.box.minY, top = p.box.maxY
            for o in pieces where o.line != p.line && o.box.height < p.box.height
                && o.box.minX < p.box.maxX && p.box.minX < o.box.maxX
                && o.box.minY < p.box.maxY && p.box.minY < o.box.maxY {
                // The shorter box is below this one's middle: this one ends above
                // it; above the middle: this one starts below it.
                if o.box.midY < p.box.midY { bottom = max(bottom, o.box.maxY) } else { top = min(top, o.box.minY) }
            }
            // Never clipped away: a box over several lines, like a drop cap read
            // on its own, keeps its full height.
            return top - bottom > 1 ? CGRect(x: p.box.minX, y: bottom, width: p.box.width, height: top - bottom) : p.box
        }

        struct Run { let ctLine: CTLine; let x: Double; let baseline: Double; let width: Double
                     let xScale: Double; let size: Double; var height: Double }
        func ctLine(_ text: String) -> CTLine {
            // No ligatures: a reader gives the fi and fl glyphs no height, or
            // puts them at the page's bottom edge, splitting "scientific".
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .ligature: 0]))
        }
        let space = ctLine(" ")
        let spaceWidth = CTLineGetTypographicBounds(space, nil, nil, nil)
        var runs: [Run] = []
        for (i, piece) in pieces.enumerated() {
            // A word trimmed to its ink can be under a point wide ("I").
            let box = boxes[i]
            guard box.width > 0, box.height > 1 else { continue }
            let line = ctLine(piece.text)
            let naturalWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard naturalWidth > 0 else { continue }
            let size = max(1, box.height)
            let baseline = box.minY + size * 0.18
            if lines[piece.line].words.isEmpty {
                let fit = min(size, box.width * baseSize / naturalWidth)
                runs.append(Run(ctLine: line, x: box.minX, baseline: box.minY + fit * 0.18,
                                width: naturalWidth * fit / baseSize, xScale: fit / baseSize, size: fit, height: fit))
                continue
            }
            runs.append(Run(ctLine: line, x: box.minX, baseline: baseline, width: box.width,
                            xScale: box.width / naturalWidth, size: size, height: size))
            // The space fills the gap to the next word (thin if they touch, or at the line's end).
            let gap = piece.wordsFollow ? max(0.05, pieces[i + 1].box.minX - box.maxX) : 0.05
            runs.append(Run(ctLine: space, x: box.maxX, baseline: baseline, width: gap,
                            xScale: gap / spaceWidth, size: size, height: size))
        }

        // Where runs that share some x would overlap, shrink both heights by the
        // factor that makes the upper one's descent meet the lower one's ascent.
        // Factors come from the full heights and each run keeps its smallest,
        // so a line over several pieces of one row shrinks once, not once per
        // piece. Runs whose baselines are under half a line apart are the same
        // row of print (or a duplicate), not neighbours.
        let ascent = CTFontGetAscent(font) / baseSize, descent = CTFontGetDescent(font) / baseSize
        var factor = [Double](repeating: 1, count: runs.count)
        for i in runs.indices {
            for j in runs.indices where runs[j].baseline < runs[i].baseline {
                let pitch = runs[i].baseline - runs[j].baseline
                guard pitch > 0.5 * min(runs[i].size, runs[j].size),
                      runs[i].x < runs[j].x + runs[j].width, runs[j].x < runs[i].x + runs[i].width else { continue }
                let needed = descent * runs[i].size + ascent * runs[j].size
                guard needed > pitch else { continue }
                factor[i] = min(factor[i], pitch / needed)
                factor[j] = min(factor[j], pitch / needed)
            }
        }
        for i in runs.indices { runs[i].height = runs[i].size * factor[i] }

        for run in runs {
            ctx.saveGState()
            ctx.translateBy(x: run.x, y: run.baseline)
            ctx.scaleBy(x: run.xScale, y: run.height / baseSize)
            ctx.textPosition = .zero
            CTLineDraw(run.ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// True when `url` is a PDF of exactly `pageCount` pages.
    static func isComplete(_ url: URL, pageCount: Int) -> Bool {
        guard let doc = PDFDocument(url: url) else { return false }
        return doc.pageCount == pageCount
    }

    /// Whether the page already has text a reader can search: from an earlier
    /// OCR, or because it was made on a computer rather than scanned.
    static func hasText(_ page: PDFPage) -> Bool {
        page.string?.contains { !$0.isWhitespace } == true
    }

    /// Whether the PDF already has text, judged from up to `sample` pages spread
    /// through it, so opening a long book stays quick.
    static func hasText(_ document: PDFDocument, sample: Int = 10) -> Bool {
        let n = document.pageCount, count = min(n, sample)
        return (0..<count).contains { k in document.page(at: k * n / count).map(hasText) ?? false }
    }

    /// The text layer's font, made once per export (see drawTextLayer).
    static func makeTextLayerFont() -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, 100, nil)
    }
}
