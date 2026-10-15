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
        case renderFailed(Int)
        case writeFailed
        var errorDescription: String? {
            switch self {
            case .noPages: return "No pages to export."
            case .renderFailed(let i): return "Failed to render source page \(i + 1)."
            case .writeFailed: return "Could not write the output PDF."
            }
        }
    }

    /// Progress callback receives (completedCrops, totalCrops).
    static func export(pages: [BookPage],
                       from document: PDFDocument,
                       to url: URL,
                       settings: Settings,
                       progress: ((Int, Int) -> Void)? = nil) throws {

        // 1. Gather every output crop together with its rendered source image.
        struct Job { let cgImage: CGImage; let crop: CropRect }
        var jobs: [Job] = []

        // Cache source renders so a spread is only rasterized once.
        var renderCache: [Int: CGImage] = [:]

        for page in pages where page.classification != .skip {
            let crops = page.outputCrops(direction: settings.direction)
            guard !crops.isEmpty else { continue }

            let source: CGImage
            if let cached = renderCache[page.sourceIndex] {
                source = cached
            } else {
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
                renderCache[page.sourceIndex] = enhanced
                source = enhanced
            }

            for crop in crops {
                guard let sub = PDFRenderer.crop(source, to: crop) else { continue }
                jobs.append(Job(cgImage: sub, crop: crop))
            }
        }

        guard !jobs.isEmpty else { throw ExportError.noPages }

        // 2. Write each page through a Core Graphics PDF context. Each page's media
        //    box is exactly its own crop (1 pixel = 1 point) — no padding, no scaling
        //    — then optionally an invisible OCR text layer is overlaid.
        var defaultBox = CGRect(x: 0, y: 0, width: jobs[0].cgImage.width, height: jobs[0].cgImage.height)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw ExportError.writeFailed
        }

        let total = jobs.count
        for (i, job) in jobs.enumerated() {
            let image = job.cgImage
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            if settings.ocr {
                let lines = OCRService.recognizeLines(image, languages: settings.ocrLanguages)
                drawTextLayer(lines, in: ctx, pageSize: box.size)
            }
            ctx.endPage()
            progress?(i + 1, total)
        }
        ctx.closePDF()
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
