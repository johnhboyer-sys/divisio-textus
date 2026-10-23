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

    struct Settings {
        var dpi: Double = 300            // export resolution when not matching the scan
        var matchScanResolution = true   // use each page's own scan resolution instead
        var jpegQuality: Double = 0.7    // for pages stored as JPEG (see encodeForPDF)
        var direction: ReadingDirection = .leftToRight
        var ocr: Bool = true             // embed searchable text layer
        var ocrLanguages: [String] = ["en-US"]
        var enhanceMode: EnhanceMode = .color  // color or grayscale
    }

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
    /// where Vision failed on all or part of the page, so it isn't fully searchable.
    struct Report {
        var pageCount = 0
        var ocrFailedPages: [Int] = []
    }

    /// Source pages handled per batch. Only one batch of rendered pages is held in
    /// memory at a time (rendering a whole book first needs several GB), and OCR —
    /// the slow step — runs on the batch's pages in parallel.
    private static let batchSize = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// Progress callback receives (completedCrops, totalCrops).
    static func export(pages: [BookPage],
                       from document: PDFDocument,
                       to url: URL,
                       settings: Settings,
                       isCancelled: (() -> Bool)? = nil,
                       progress: ((Int, Int) -> Void)? = nil) throws -> Report {

        let todo = pages.filter { !$0.outputCrops(direction: settings.direction).isEmpty }
        let total = todo.reduce(0) { $0 + $1.outputCrops(direction: settings.direction).count }
        guard total > 0 else { throw ExportError.noPages }

        var report = Report()
        try writePDF(to: url, isCancelled: isCancelled) { ctx in
            let textFont = makeTextLayerFont()
            var batchStart = 0
            while batchStart < todo.count {
                if isCancelled?() == true { throw ExportError.cancelled }
                let batch = todo[batchStart..<min(batchStart + batchSize, todo.count)]
                batchStart += batch.count

                // 1. Render, straighten and crop serially: PDFKit can't draw one document
                //    from several threads at once.
                //    The autorelease pool matters: PDFKit autoreleases while drawing, and a
                //    background thread doesn't drain until the whole export ends, which
                //    kept every rendered page alive.
                var images: [CGImage] = []
                var dpis: [Double] = []
                for page in batch {
                    try autoreleasepool {
                        guard let pdfPage = document.page(at: page.sourceIndex) else {
                            throw ExportError.renderFailed(page.sourceIndex)
                        }
                        let dpi = renderDPI(of: pdfPage, settings: settings)
                        guard let rendered = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi) else {
                            throw ExportError.renderFailed(page.sourceIndex)
                        }
                        // Deskew each half independently at full export resolution,
                        // matching the preview composite, so the crop boxes line up.
                        let composite = ImageTransform.deskewedComposite(
                            rendered, splitX: page.splitX,
                            leftDegrees: page.leftSkew, rightDegrees: page.rightSkew,
                            isSpread: page.isSpread)
                        let enhanced = ImageEnhancer.apply(composite, mode: settings.enhanceMode)
                        // A crop that fails would silently drop an output page: fail the export.
                        for crop in page.outputCrops(direction: settings.direction) {
                            guard let sub = PDFRenderer.crop(enhanced, to: crop) else {
                                throw ExportError.renderFailed(page.sourceIndex)
                            }
                            images.append(sub)
                            dpis.append(dpi)
                        }
                    }
                }

                // 2. OCR the batch in parallel.
                let text = recognizeAll(images.map { settings.ocr ? $0 : nil }) {
                    OCRService.recognizeLines($0, languages: settings.ocrLanguages)
                }

                if isCancelled?() == true { throw ExportError.cancelled }

                // 3. Write the batch in reading order. OCR above read the full-quality
                //    image; what goes into the file is the compact encoding of it.
                for (i, image) in images.enumerated() {
                    // Each page's media box is its own crop (no padding, no resampling), sized at
                    // its render DPI so the page keeps its physical size: a 300 DPI crop 2550 px
                    // wide is 8.5 in (612 pt), not 2550 pt.
                    let pointsPerPixel = 72.0 / dpis[i]
                    var box = CGRect(x: 0, y: 0,
                                     width: Double(image.width) * pointsPerPixel,
                                     height: Double(image.height) * pointsPerPixel)
                    ctx.beginPage(mediaBox: &box)
                    ctx.draw(encodeForPDF(image, quality: settings.jpegQuality), in: box)
                    report.pageCount += 1
                    if let recognition = text[i] {
                        drawTextLayer(recognition.lines, in: ctx, pageSize: box.size, font: textFont)
                    }
                    if text[i]?.complete != true {
                        report.ocrFailedPages.append(report.pageCount)
                    }
                    ctx.endPage()
                    progress?(report.pageCount, total)
                }
            }
        }
        return report
    }

    /// Export the PDF's own pages as they are — not split, straightened, cropped
    /// or recolored — with every page read afresh into an invisible text layer.
    /// No page keeps text it had, which could only be doubled, or garbled: Quartz
    /// loses the text mapping of some fonts (OCRmyPDF's, for one) when it copies
    /// a page. Each page goes out at its displayed size, turned as it shows:
    ///   • a page without text is copied, so its images and vectors go in as they
    ///     are (JPEG and JPEG 2000 byte for byte; Quartz stores other images
    ///     losslessly as Flate, so black-and-white scans can grow), notes and form
    ///     fields drawn into the page;
    ///   • a page with text that shows nothing but one scan image gets that image
    ///     back unchanged (a JPEG byte for byte, others pixel for pixel), without
    ///     the old text;
    ///   • any other page with text — a layered scan, a page made on a computer —
    ///     can't be copied without its text, so it is drawn whole as an image at
    ///     its scan's resolution and stored losslessly.
    /// Links and bookmarks aren't carried over. `recognize` stands in for Vision
    /// in tests.
    static func exportAsTheyAre(from document: PDFDocument, to url: URL, settings: Settings,
                                isCancelled: (() -> Bool)? = nil,
                                progress: ((Int, Int) -> Void)? = nil,
                                recognize: ((CGImage) -> OCRService.Recognition?)? = nil) throws -> Report {
        let total = document.pageCount
        guard total > 0 else { throw ExportError.noPages }
        let read = recognize ?? { OCRService.recognizeLines($0, languages: settings.ocrLanguages) }
        var report = Report()
        try writePDF(to: url, isCancelled: isCancelled) { ctx in
            let textFont = makeTextLayerFont()
            var batchStart = 0
            while batchStart < total {
                if isCancelled?() == true { throw ExportError.cancelled }
                let batch = batchStart..<min(batchStart + batchSize, total)
                batchStart = batch.upperBound

                // 1. Render each page to read, and choose how it goes out; serially (see export).
                var images = [CGImage?](repeating: nil, count: batch.count)
                var outputs = [PageOutput](repeating: .copy, count: batch.count)
                if settings.ocr {
                    for (k, index) in batch.enumerated() {
                        try autoreleasepool {
                            guard let page = document.page(at: index),
                                  let image = PDFRenderer.renderCGImage(page: page, dpi: renderDPI(of: page, settings: settings)) else {
                                throw ExportError.renderFailed(index)
                            }
                            images[k] = image
                            if hasText(page) {
                                outputs[k] = liftedScan(of: page, shown: image).map { .lift($0.image, $0.transform) } ?? .redraw
                            }
                        }
                    }
                }

                // 2. OCR them in parallel.
                let text = recognizeAll(images, read)
                if isCancelled?() == true { throw ExportError.cancelled }

                // 3. Write each page and lay its text over it.
                for (k, index) in batch.enumerated() {
                    try autoreleasepool {
                        guard let page = document.page(at: index) else { throw ExportError.renderFailed(index) }
                        var box = CGRect(origin: .zero, size: PDFRenderer.displaySize(of: page))
                        switch outputs[k] {
                        case .copy:
                            box = beginCopy(of: page, in: ctx)
                        case .lift(let scan, let transform):
                            ctx.beginPage(mediaBox: &box)
                            ctx.saveGState()
                            ctx.clip(to: box)
                            page.transform(ctx, for: .cropBox)
                            ctx.concatenate(transform)
                            ctx.draw(scan, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                            ctx.restoreGState()
                        case .redraw:
                            guard let image = images[k] else { throw ExportError.renderFailed(index) }
                            ctx.beginPage(mediaBox: &box)
                            ctx.draw(exactGray(image) ?? image, in: box)
                        }
                        report.pageCount += 1
                        if let recognition = text[k] {
                            drawTextLayer(recognition.lines, in: ctx, pageSize: box.size, font: textFont)
                        }
                        if text[k]?.complete != true {
                            report.ocrFailedPages.append(report.pageCount)
                        }
                        ctx.endPage()
                    }
                    progress?(report.pageCount, total)
                }
            }
        }
        return report
    }

    /// How exportAsTheyAre writes a page (see there).
    private enum PageOutput {
        case copy
        case lift(CGImage, CGAffineTransform)
        case redraw
    }

    /// Whether the page already has text a reader can search: from an earlier
    /// OCR, or because it was made on a computer rather than scanned.
    static func hasText(_ page: PDFPage) -> Bool {
        page.string?.contains { !$0.isWhitespace } == true
    }

    /// The page's one scan image, unchanged, and where the page draws it, when the
    /// page shows nothing else (its text being invisible, as OCR leaves it). nil
    /// otherwise, or when the image can't be rebuilt exactly. The proof is to look:
    /// the page as `shown` (rendered whole, at its scan's resolution, so pixels
    /// line up one to one) and the image drawn alone must match. Smoothing is
    /// tried as the image asks first, then the other way, since Quartz draws a
    /// JPEG differently when smoothing it.
    private static func liftedScan(of page: PDFPage, shown whole: CGImage) -> (image: CGImage, transform: CGAffineTransform)? {
        guard let cgPage = page.pageRef,
              let drawn = PDFRenderer.drawnContent(cgPage)?.images, drawn.count == 1,
              let dict = CGPDFStreamGetDictionary(drawn[0].stream),
              let shown = GrayBuffer(cgImage: whole, maxDim: max(whole.width, whole.height)) else { return nil }
        let transform = drawn[0].transform
        var asked = false
        CGPDFDictionaryGetBoolean(dict, "Interpolate", &asked)
        for interpolate in [asked, !asked] {
            guard let image = unchangedImage(drawn[0].stream, interpolate: interpolate),
                  let ctx = CGContext(data: nil, width: whole.width, height: whole.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            let size = PDFRenderer.displaySize(of: page)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: whole.width, height: whole.height))
            ctx.scaleBy(x: Double(whole.width) / size.width, y: Double(whole.height) / size.height)
            ctx.clip(to: CGRect(origin: .zero, size: size))
            page.transform(ctx, for: .cropBox)
            ctx.concatenate(transform)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let alone = ctx.makeImage(),
                  let b = GrayBuffer(cgImage: alone, maxDim: max(alone.width, alone.height)),
                  b.width == shown.width, b.height == shown.height else { return nil }
            // A visible folio or stamp is hundreds of changed pixels.
            let changed = zip(shown.pixels, b.pixels).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 48 ? 1 : 0) }
            if changed <= shown.pixels.count / 100_000 { return (image, transform) }
        }
        return nil
    }

    /// The image as gray when every pixel of it is gray: the same pixels, a third
    /// of the data. nil if any pixel has color (or the image isn't 8-bit RGBX).
    private static func exactGray(_ image: CGImage) -> CGImage? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let w = image.width, h = image.height, stride = image.bytesPerRow
        var gray = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = bytes + y * stride + x * 4
                guard p[0] == p[1], p[1] == p[2] else { return nil }
                gray[y * w + x] = p[0]
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The image a PDF image stream holds, rebuilt without changing it: a JPEG
    /// from its own bytes, so Quartz writes them back as they are; JPEG 2000
    /// decoded; others from their samples, which Quartz stores losslessly. Gray
    /// and RGB only: nil for masks, palettes, CMYK and soft masks.
    private static func unchangedImage(_ stream: CGPDFStreamRef, interpolate: Bool) -> CGImage? {
        guard let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        var flag = false
        if CGPDFDictionaryGetBoolean(dict, "ImageMask", &flag), flag { return nil }
        var object: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dict, "SMask", &object) || CGPDFDictionaryGetObject(dict, "Mask", &object) { return nil }
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0, bpc: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &w), CGPDFDictionaryGetInteger(dict, "Height", &h),
              w > 0, h > 0 else { return nil }
        CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc)

        // Components: DeviceGray / DeviceRGB, or an ICC profile with 1 or 3.
        var components = 0
        var name: UnsafePointer<CChar>?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetName(dict, "ColorSpace", &name), let name {
            components = ["DeviceGray": 1, "DeviceRGB": 3][String(cString: name)] ?? 0
        } else if CGPDFDictionaryGetArray(dict, "ColorSpace", &array), let array, CGPDFArrayGetCount(array) == 2,
                  CGPDFArrayGetName(array, 0, &name), let name, String(cString: name) == "ICCBased" {
            var icc: CGPDFStreamRef?
            var n: CGPDFInteger = 0
            if CGPDFArrayGetStream(array, 1, &icc), let icc, let iccDict = CGPDFStreamGetDictionary(icc),
               CGPDFDictionaryGetInteger(iccDict, "N", &n) { components = Int(n) }
        }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), let provider = CGDataProvider(data: data) else { return nil }
        if format == .JPEG2000 {
            guard let source = CGImageSourceCreateWithData(data, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard components == 1 || components == 3 else { return nil }
        let space = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()

        var decode: [CGFloat]?
        if CGPDFDictionaryGetArray(dict, "Decode", &array), let array, CGPDFArrayGetCount(array) == 2 * components {
            decode = (0..<2 * components).map { i in
                var v: CGPDFReal = 0
                CGPDFArrayGetNumber(array, i, &v)
                return v
            }
        }
        if format == .jpegEncoded {
            return CGImage(jpegDataProviderSource: provider, decode: decode, shouldInterpolate: interpolate, intent: .defaultIntent)
        }
        guard [1, 8].contains(bpc) else { return nil }
        let bytesPerRow = (w * bpc * components + 7) / 8
        guard CFDataGetLength(data) == bytesPerRow * h else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: bpc, bitsPerPixel: bpc * components,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: decode, shouldInterpolate: interpolate, intent: .defaultIntent)
    }

    /// Begin an output page that is `page` as it shows, and return its box. Drawn
    /// the way the OCR render is (see PDFRenderer), so text laid over it lands on
    /// what was read: PDFKit places the crop box and the page's turn, and draws
    /// what its notes and marks show.
    private static func beginCopy(of page: PDFPage, in ctx: CGContext) -> CGRect {
        var box = CGRect(origin: .zero, size: PDFRenderer.displaySize(of: page))
        ctx.beginPage(mediaBox: &box)
        ctx.saveGState()
        ctx.clip(to: box)
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        return box
    }

    /// Whether the PDF already has text, judged from up to `sample` pages spread
    /// through it, so opening a long book stays quick.
    static func hasText(_ document: PDFDocument, sample: Int = 10) -> Bool {
        let n = document.pageCount, count = min(n, sample)
        return (0..<count).contains { k in document.page(at: k * n / count).map(hasText) ?? false }
    }

    /// Render at the scan's own resolution when there is one: higher would invent
    /// pixels, lower would throw detail away. Kept within 150–600 DPI so OCR has
    /// enough to read and memory stays sane.
    private static func renderDPI(of page: PDFPage, settings: Settings) -> Double {
        settings.matchScanResolution
            ? PDFRenderer.scanDPI(of: page).map { min(600, max(150, $0)) } ?? settings.dpi
            : settings.dpi
    }

    /// Read the images' text in parallel; a nil image has nothing to read. A nil
    /// result means Vision failed on the whole page; incomplete, on part of it.
    private static func recognizeAll(_ images: [CGImage?],
                                     _ read: (CGImage) -> OCRService.Recognition?) -> [OCRService.Recognition?] {
        let noText = OCRService.Recognition(lines: [], complete: true)
        var text = [OCRService.Recognition?](repeating: noText, count: images.count)
        text.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: images.count) { i in
                if let image = images[i] { out[i] = read(image) }
            }
        }
        // Vision tends to fail while it warms up and then recover, so give
        // failed or partly failed pages one more try now that the rest of
        // the batch is done, keeping whichever result read more.
        for i in text.indices where text[i]?.complete != true {
            guard let image = images[i], let retry = read(image) else { continue }
            if retry.complete || retry.lines.count > (text[i]?.lines.count ?? -1) { text[i] = retry }
        }
        return text
    }

    /// Write a PDF through `body` to a temporary file and move it into place at
    /// the end, so exporting over the source PDF never reads and writes one file
    /// at once, and a failed or cancelled export leaves no half-written file behind.
    private static func writePDF(to url: URL, isCancelled: (() -> Bool)?, _ body: (CGContext) throws -> Void) throws {
        let fm = FileManager.default
        guard let tmpDir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                       appropriateFor: url, create: true) else {
            throw ExportError.writeFailed
        }
        defer { try? fm.removeItem(at: tmpDir) }
        let tmpURL = tmpDir.appendingPathComponent(url.lastPathComponent)

        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: tmpURL as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw ExportError.writeFailed
        }
        try body(ctx)
        ctx.closePDF()
        // Cancel pressed during the last batch: don't replace the destination.
        if isCancelled?() == true { throw ExportError.cancelled }
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: url)
            }
        } catch {
            throw ExportError.writeFailed
        }
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

    /// Draw each recognized line as one invisible, selectable run. `CTLineDraw`
    /// positions glyphs individually, so PDF text extraction reconstructs words
    /// from glyph gaps. The rules that keep copied text clean:
    ///   • never stretch horizontally — stretching spreads glyphs and yields
    ///     "c a u s e";
    ///   • size each line by scaling the drawing the same in both directions,
    ///     shrinking to fit the line's width if needed, which keeps letters
    ///     tight and the space glyphs intact. (Scale the context, not the text
    ///     matrix: CTLineDraw places glyphs at the font's own advances and
    ///     ignores the text matrix for that, which spreads the letters out.)
    /// Every line uses the one `font` object made for the export, so the PDF
    /// embeds Helvetica once. (Making a font per line at that line's size usually
    /// got a cached font back, but under memory pressure each line embedded its
    /// own copy: about 1,000 copies and +7 MB on a 26-page book.)
    static func drawTextLayer(_ lines: [OCRService.Line], in ctx: CGContext, pageSize: CGSize, font: CTFont) {
        guard !lines.isEmpty else { return }
        let baseSize = CTFontGetSize(font)
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        ctx.textMatrix = .identity

        for line in lines {
            let box = CGRect(x: line.box.minX * pageSize.width,
                             y: line.box.minY * pageSize.height,
                             width: line.box.width * pageSize.width,
                             height: line.box.height * pageSize.height)
            guard box.width > 1, box.height > 1 else { continue }

            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: line.text, attributes: [.font: font]))
            let naturalWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            var size = max(1, box.height)
            if naturalWidth > 0, naturalWidth * size / baseSize > box.width {
                size = max(1, box.width * baseSize / naturalWidth)
            }
            let scale = size / baseSize
            ctx.saveGState()
            ctx.translateBy(x: box.minX, y: box.minY + size * 0.18)
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// The text layer's font, made once per export (see drawTextLayer).
    static func makeTextLayerFont() -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, 100, nil)
    }
}
