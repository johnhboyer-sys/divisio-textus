import Foundation
import PDFKit
import AppKit
import CoreGraphics

/// Renders source PDF pages to bitmaps. Preview renders are small/fast;
/// export renders go to a target DPI to preserve scan detail.
enum PDFRenderer {

    /// Render a page to a CGImage. `dpi` interprets the page's point size
    /// (1 pt = 1/72") as physical inches.
    static func renderCGImage(page: PDFPage, dpi: Double) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let pxW = max(1, Int((bounds.width * scale).rounded()))
        let pxH = max(1, Int((bounds.height * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: pxW,
                                  height: pxH,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        // PDFKit draws in PDF (bottom-left) space; our context matches.
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    static func renderNSImage(page: PDFPage, dpi: Double) -> NSImage? {
        guard let cg = renderCGImage(page: page, dpi: dpi) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Crop a top-left-origin normalized rect out of a CGImage.
    static func crop(_ image: CGImage, to rect: CropRect) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let px = rect.normalized().pixelRect(in: size).integral
        let clamped = px.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped)
    }
}
