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

        var report = Report()
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
                    // Render at the scan's own resolution when there is one: higher
                    // would invent pixels, lower would throw detail away. Kept within
                    // 150–600 DPI so OCR has enough to read and memory stays sane.
                    let dpi = settings.matchScanResolution
                        ? PDFRenderer.scanDPI(of: pdfPage).map { min(600, max(150, $0)) } ?? settings.dpi
                        : settings.dpi
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

            // 2. OCR the batch in parallel. nil = Vision failed on the whole page;
            //    incomplete = it failed on part of it.
            let noText = OCRService.Recognition(lines: [], complete: true)
            var text = [OCRService.Recognition?](repeating: noText, count: images.count)
            if settings.ocr {
                text.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: images.count) { i in
                        out[i] = OCRService.recognizeLines(images[i], languages: settings.ocrLanguages)
                    }
                }
                // Vision tends to fail while it warms up and then recover, so give
                // failed or partly failed pages one more try now that the rest of
                // the batch is done, keeping whichever result read more.
                for i in text.indices where text[i]?.complete != true {
                    guard let retry = OCRService.recognizeLines(images[i], languages: settings.ocrLanguages) else { continue }
                    if retry.complete || retry.lines.count > (text[i]?.lines.count ?? -1) { text[i] = retry }
                }
            }

            if isCancelled?() == true { throw ExportError.cancelled }

            // 3. Write the batch in reading order. OCR above read the full-quality
            //    image; what goes into the file is the compact encoding of it.
            for (i, image) in images.enumerated() {
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
        return report
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
