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

    /// Resolution of a scanned page: the pixel density of the largest image on it,
    /// when that image has the page's shape (a full-page scan). nil for pages
    /// without one, e.g. born-digital text. Looks into nested form objects and
    /// resources inherited from the page tree.
    static func scanDPI(of page: PDFPage) -> Double? {
        guard let cgPage = page.pageRef, let pageDict = cgPage.dictionary else { return nil }
        let box = cgPage.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }

        var resources: CGPDFDictionaryRef?
        var node: CGPDFDictionaryRef? = pageDict
        while let current = node, resources == nil {
            var r: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &r) { resources = r; break }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        guard let resources else { return nil }

        // Several pages can share one resource dictionary listing every page's
        // scan, so at the top level only count what this page draws.
        let drawn = drawnXObjectNames(cgPage)

        var largest = (w: 0, h: 0)
        func scan(_ res: CGPDFDictionaryRef, depth: Int) {
            var xobjects: CGPDFDictionaryRef?
            guard depth < 4, CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xo = xobjects else { return }
            var forms: [CGPDFDictionaryRef] = []
            CGPDFDictionaryApplyBlock(xo, { key, object, _ in
                if depth == 0, let drawn, !drawn.contains(String(cString: key)) { return true }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let s = stream,
                      let dict = CGPDFStreamGetDictionary(s) else { return true }
                var subtype: UnsafePointer<CChar>?
                CGPDFDictionaryGetName(dict, "Subtype", &subtype)
                switch subtype.map({ String(cString: $0) }) {
                case "Image":
                    var w: CGPDFInteger = 0, h: CGPDFInteger = 0
                    CGPDFDictionaryGetInteger(dict, "Width", &w)
                    CGPDFDictionaryGetInteger(dict, "Height", &h)
                    if w * h > largest.w * largest.h { largest = (w, h) }
                case "Form":
                    var r: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dict, "Resources", &r), let r { forms.append(r) }
                default:
                    break
                }
                return true
            }, nil)
            for form in forms { scan(form, depth: depth + 1) }
        }
        scan(resources, depth: 0)

        guard largest.w > 0, largest.h > 0 else { return nil }
        // Same shape as the page (either orientation) ⇒ it is the page scan.
        let pageAspect = box.width / box.height
        let imageAspect = Double(largest.w) / Double(largest.h)
        let ratio = max(imageAspect / pageAspect, pageAspect / imageAspect)
        let rotatedRatio = max(imageAspect * pageAspect, 1 / (imageAspect * pageAspect))
        guard min(ratio, rotatedRatio) < 1.15 else { return nil }
        let imageLong = Double(max(largest.w, largest.h))
        let pageLongInches = max(box.width, box.height) / 72
        return imageLong / pageLongInches
    }

    /// Names of the XObjects the page's own content stream draws ("/Name Do"),
    /// or nil if the content couldn't be read.
    private static func drawnXObjectNames(_ page: CGPDFPage) -> Set<String>? {
        final class Names { var set = Set<String>() }
        let names = Names()
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            var name: UnsafePointer<CChar>?
            guard let info, CGPDFScannerPopName(scanner, &name), let name else { return }
            Unmanaged<Names>.fromOpaque(info).takeUnretainedValue().set.insert(String(cString: name))
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(names).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        return withExtendedLifetime(names) { CGPDFScannerScan(scanner) ? names.set : nil }
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
