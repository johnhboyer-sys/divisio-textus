import Foundation
import PDFKit
import AppKit
import CoreGraphics
import CoreText

/// Builds the output PDF: one page per book page, sized to its own crop (never
/// scaled, never padded). Optionally overlays an invisible OCR text layer so the
/// PDF is searchable.
enum PDFExporter {

    struct Settings {
        var dpi: Double = 300            // export render resolution
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
        var errorDescription: String? {
            switch self {
            case .noPages: return "No pages to export."
            case .sourceUnreadable: return "Could not reopen the source PDF."
            case .renderFailed(let i): return "Failed to render source page \(i + 1)."
            case .writeFailed: return "Could not write the output PDF."
            }
        }
    }

    /// What the export produced. `ocrFailedPages` are 1-based output page numbers
    /// where Vision failed, so those pages have no searchable text.
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
                       progress: ((Int, Int) -> Void)? = nil) throws -> Report {

        let todo = pages.filter { !$0.outputCrops(direction: settings.direction).isEmpty }
        let total = todo.reduce(0) { $0 + $1.outputCrops(direction: settings.direction).count }
        guard total > 0 else { throw ExportError.noPages }

        // Each page's media box is its own crop (no padding, no resampling), sized at
        // the export DPI so the page keeps its physical size: a 300 DPI crop 2550 px
        // wide is 8.5 in (612 pt), not 2550 pt.
        let pointsPerPixel = 72.0 / settings.dpi
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
        var batchStart = 0
        while batchStart < todo.count {
            let batch = todo[batchStart..<min(batchStart + batchSize, todo.count)]
            batchStart += batch.count

            // 1. Render, straighten and crop serially: PDFKit can't draw one document
            //    from several threads at once.
            //    The autorelease pool matters: PDFKit autoreleases while drawing, and a
            //    background thread doesn't drain until the whole export ends, which
            //    kept every rendered page alive.
            var images: [CGImage] = []
            for page in batch {
                try autoreleasepool {
                    guard let pdfPage = document.page(at: page.sourceIndex),
                          let rendered = PDFRenderer.renderCGImage(page: pdfPage, dpi: settings.dpi) else {
                        throw ExportError.renderFailed(page.sourceIndex)
                    }
                    // Deskew each half independently at full export resolution,
                    // matching the preview composite, so the crop boxes line up.
                    let composite = ImageTransform.deskewedComposite(
                        rendered, splitX: page.splitX,
                        leftDegrees: page.leftSkew, rightDegrees: page.rightSkew,
                        isSpread: page.isSpread)
                    let enhanced = ImageEnhancer.apply(composite, mode: settings.enhanceMode)
                    for crop in page.outputCrops(direction: settings.direction) {
                        if let sub = PDFRenderer.crop(enhanced, to: crop) { images.append(sub) }
                    }
                }
            }

            // 2. OCR the batch in parallel. nil = Vision failed on that page.
            var lines = [[OCRService.Line]?](repeating: [], count: images.count)
            if settings.ocr {
                lines.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: images.count) { i in
                        out[i] = OCRService.recognizeLines(images[i], languages: settings.ocrLanguages)
                    }
                }
                // Vision tends to fail while it warms up and then recover, so give
                // failed pages one more try now that the rest of the batch is done.
                for i in lines.indices where lines[i] == nil {
                    lines[i] = OCRService.recognizeLines(images[i], languages: settings.ocrLanguages)
                }
            }

            // 3. Write the batch in reading order.
            for (i, image) in images.enumerated() {
                var box = CGRect(x: 0, y: 0,
                                 width: Double(image.width) * pointsPerPixel,
                                 height: Double(image.height) * pointsPerPixel)
                ctx.beginPage(mediaBox: &box)
                ctx.draw(image, in: box)
                report.pageCount += 1
                if let pageLines = lines[i] {
                    drawTextLayer(pageLines, in: ctx, pageSize: box.size)
                } else {
                    report.ocrFailedPages.append(report.pageCount)
                }
                ctx.endPage()
                progress?(report.pageCount, total)
            }
        }
        ctx.closePDF()
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

    /// Draw each recognized line as one invisible, selectable run. `CTLineDraw`
    /// positions glyphs individually, so PDF text extraction reconstructs words
    /// from glyph gaps. The rules that keep copied text clean:
    ///   • never stretch horizontally (textMatrix stays identity) — stretching
    ///     spreads glyphs and yields "c a u s e";
    ///   • if the natural line is wider than its box, shrink the font UNIFORMLY
    ///     to fit, which keeps letters tight and the space glyphs intact, so
    ///     words stay separated and letters stay joined.
    private static func drawTextLayer(_ lines: [OCRService.Line], in ctx: CGContext, pageSize: CGSize) {
        guard !lines.isEmpty else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        ctx.textMatrix = .identity

        for line in lines {
            let box = CGRect(x: line.box.minX * pageSize.width,
                             y: line.box.minY * pageSize.height,
                             width: line.box.width * pageSize.width,
                             height: line.box.height * pageSize.height)
            guard box.width > 1, box.height > 1 else { continue }

            var fontSize = max(1, box.height)
            var ctLine = makeLine(line.text, fontSize: fontSize)
            let naturalWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            // Shrink to fit width if needed (uniform — no glyph distortion).
            if naturalWidth > box.width, naturalWidth > 0 {
                fontSize *= box.width / naturalWidth
                ctLine = makeLine(line.text, fontSize: max(1, fontSize))
            }

            ctx.textPosition = CGPoint(x: box.minX, y: box.minY + fontSize * 0.18)
            CTLineDraw(ctLine, ctx)
        }
        ctx.restoreGState()
    }

    private static func makeLine(_ text: String, fontSize: CGFloat) -> CTLine {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return CTLineCreateWithAttributedString(attributed)
    }
}
