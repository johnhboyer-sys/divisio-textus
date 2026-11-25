import Foundation
import PDFKit
import AppKit
import CoreGraphics

/// Renders source PDF pages to bitmaps. Preview renders are small/fast;
/// export renders go to a target DPI to preserve scan detail.
enum PDFRenderer {

    /// Render a page to a CGImage as a PDF viewer shows it: its crop box, turned
    /// by its /Rotate setting. `dpi` interprets the page's point size (1 pt = 1/72")
    /// as physical inches.
    static func renderCGImage(page: PDFPage, dpi: Double) -> CGImage? {
        let size = displaySize(of: page)
        let scale = dpi / 72.0
        // A malformed page can claim an absurd or non-finite size: refuse it rather
        // than trap converting it, or ask for a bitmap no Mac can hold.
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        guard w.isFinite, h.isFinite, w > 0, h > 0, w * h <= 2_000_000_000 else { return nil }
        let pxW = max(1, Int(w))
        let pxH = max(1, Int(h))

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
        // PDFKit applies the crop box offset and the rotation itself; the canvas
        // just has to be the displayed size.
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    /// The page's size as displayed: crop box, width and height swapped when it
    /// is turned a quarter.
    static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let quarterTurns = (page.rotation % 360 + 360) % 360 / 90
        return quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
    }

    static func renderNSImage(page: PDFPage, dpi: Double) -> NSImage? {
        guard let cg = renderCGImage(page: page, dpi: dpi) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Resolution of a scanned page: the pixel density of its scan image at the
    /// size the page draws it. nil for pages without one, e.g. born-digital text.
    static func scanDPI(of page: PDFPage) -> Double? {
        guard let cgPage = page.pageRef, let pageDict = cgPage.dictionary else { return nil }

        var resources: CGPDFDictionaryRef?
        var node: CGPDFDictionaryRef? = pageDict
        while let current = node, resources == nil {
            var r: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &r) { resources = r; break }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        guard let resources else { return nil }

        // 1. Images the page draws (directly or inside forms), measured at the
        //    size they are drawn.
        let visible = cgPage.getBoxRect(.cropBox)
        let content = drawnContent(cgPage)
        // A scan may be one image, several strips spanning the page width, or
        // layers (a low-resolution background under a sharp text layer). Take
        // images at least half the page wide; if together they cover at least half
        // the page (overlaps counted once), the sharpest of them gives the
        // resolution — along whichever axis is sharper.
        let wide = (content?.images ?? []).filter { $0.size.width >= 0.5 * min(visible.width, visible.height) }
        if coverage(of: wide.map(\.bounds), in: visible) >= 0.5,
           let best = wide.map({ max(Double($0.pixelWidth) / ($0.size.width / 72),
                                     Double($0.pixelHeight) / ($0.size.height / 72)) }).max() {
            return best
        }
        let drawn = content?.names
        // 2. Otherwise, if the content couldn't be followed: the largest image the
        //    page lists, if it has the page's shape, measured against the page.
        //    (Pages can share a resource dictionary listing every page's scan, so
        //    at the top level only names this page draws count.)
        var largest = (w: 0, h: 0)

        func scan(_ res: CGPDFDictionaryRef, depth: Int) {
            var xobjects: CGPDFDictionaryRef?
            guard depth < 4, CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xo = xobjects else { return }
            var forms: [CGPDFDictionaryRef] = []
            CGPDFDictionaryApplyBlock(xo, { key, object, _ in
                let name = String(cString: key)
                if depth == 0, let drawn, !drawn.contains(name) { return true }
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

        let box = cgPage.getBoxRect(.mediaBox)
        guard largest.w > 0, largest.h > 0, box.width > 0, box.height > 0 else { return nil }
        // Same shape as the page (either orientation) ⇒ it is the page scan.
        let pageAspect = box.width / box.height
        let imageAspect = Double(largest.w) / Double(largest.h)
        let ratio = max(imageAspect / pageAspect, pageAspect / imageAspect)
        let rotatedRatio = max(imageAspect * pageAspect, 1 / (imageAspect * pageAspect))
        guard min(ratio, rotatedRatio) < 1.15 else { return nil }
        return Double(max(largest.w, largest.h)) / (max(box.width, box.height) / 72)
    }

    struct DrawnImage {
        let pixelWidth: Int
        let pixelHeight: Int
        let size: CGSize     // drawn size in points along the image's own axes
        let bounds: CGRect   // where it lands on the page (bounding box)
        let placement: CGAffineTransform  // the unit square it fills → page space
        let isMask: Bool     // a 1-bit stencil painted in the fill color
        let inkIsBlack: Bool // the fill color is black or near it (for a stencil)
        let inkIsPure: Bool  // the fill color is exactly black
        let underGState: Bool // drawn under an ExtGState (`gs`), which may fade or blend it
        let stream: CGPDFStreamRef
    }

    /// Fraction of `area` covered by the union of `rects`, measured on a 100×100
    /// grid so overlapping images count once.
    private static func coverage(of rects: [CGRect], in area: CGRect) -> Double {
        guard area.width > 0, area.height > 0, !rects.isEmpty else { return 0 }
        let n = 100
        var covered = [Bool](repeating: false, count: n * n)
        for rect in rects {
            let r = rect.intersection(area)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            let x0 = Int(((r.minX - area.minX) / area.width * Double(n)).rounded(.down))
            let x1 = Int(((r.maxX - area.minX) / area.width * Double(n)).rounded(.up))
            let y0 = Int(((r.minY - area.minY) / area.height * Double(n)).rounded(.down))
            let y1 = Int(((r.maxY - area.minY) / area.height * Double(n)).rounded(.up))
            for y in max(0, y0)..<min(n, y1) { for x in max(0, x0)..<min(n, x1) { covered[y * n + x] = true } }
        }
        return Double(covered.filter { $0 }.count) / Double(n * n)
    }

    /// What the page's content draws: every image (also those inside form
    /// objects) with its pixel width and the size it is drawn at in points, plus
    /// the names of the objects the page itself draws. An XObject fills the unit
    /// square of the current transform, so its x axis spans |(a, b)| and its y
    /// axis |(c, d)|. `paintsOther` is true when the page also paints something
    /// other than images: paths, shadings, inline images or visible text.
    /// nil if the content couldn't be read.
    static func drawnContent(_ page: CGPDFPage) -> (images: [DrawnImage], names: Set<String>, paintsOther: Bool)? {
        struct Graphics {
            var ctm = CGAffineTransform.identity; var inkIsBlack = true; var inkIsPure = true
            var textMode = 0; var gstate = false
        }
        final class State {
            var g = Graphics()
            var ctm: CGAffineTransform { get { g.ctm } set { g.ctm = newValue } }
            var saved: [Graphics] = []
            var depth = 0
            var images: [DrawnImage] = []
            var names = Set<String>()
            var paintsOther = false
            var table: CGPDFOperatorTableRef?
        }
        let state = State()
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        defer { CGPDFOperatorTableRelease(table) }
        state.table = table

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let s = info.map({ Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }) else { return }
            s.saved.append(s.g)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let s = info.map({ Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }) else { return }
            if let t = s.saved.popLast() { s.g = t }
        }
        // Painting other than images.
        for op in ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "sh", "BI", "EI"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                guard let s = info.map({ Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }) else { return }
                s.paintsOther = true
            }
        }
        // Text counts unless drawn invisible (mode 3, as an OCR layer is).
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            guard let s = info.map({ Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) { s.g.textMode = mode }
        }
        for op in ["Tj", "TJ", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                guard let s = info.map({ Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }) else { return }
                if s.g.textMode != 3 { s.paintsOther = true }
            }
        }
        // The fill color, as far as a stencil's ink goes: black or near it, or not.
        // Operands are gray (1), RGB (3) or CMYK (4); a pattern name gives none.
        for op in ["g", "rg", "k", "sc", "scn"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                guard let s = info.map({ Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }) else { return }
                var v: [CGPDFReal] = []
                var x: CGPDFReal = 0
                while v.count < 4, CGPDFScannerPopNumber(scanner, &x) { v.insert(x, at: 0) }
                s.g.inkIsPure = v.count == 1 && v[0] == 0 || v.count == 3 && v.allSatisfy { $0 == 0 }
                    || v.count == 4 && v[0...2].allSatisfy { $0 == 0 } && v[3] == 1
                switch v.count {
                case 1: s.g.inkIsBlack = v[0] <= 0.25
                case 3: s.g.inkIsBlack = v.max()! <= 0.3
                case 4: s.g.inkIsBlack = v[3] >= 0.75 && v[0...2].max()! <= 0.2 || v[0...2].min()! >= 0.75
                default: s.g.inkIsBlack = false
                }
            }
        }
        CGPDFOperatorTableSetCallback(table, "gs") { _, info in
            guard let s = info.map({ Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }) else { return }
            s.g.gstate = true
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let s = info.map({ Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return } }
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            var namePtr: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &namePtr), let namePtr else { return }
            if s.depth == 0 { s.names.insert(String(cString: namePtr)) }
            let content = CGPDFScannerGetContentStream(scanner)
            var stream: CGPDFStreamRef?
            guard let object = CGPDFContentStreamGetResource(content, "XObject", namePtr),
                  CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dict, "Subtype", &subtype)
            switch subtype.map({ String(cString: $0) }) {
            case "Image":
                var w: CGPDFInteger = 0, h: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dict, "Width", &w)
                CGPDFDictionaryGetInteger(dict, "Height", &h)
                var isMask: CGPDFBoolean = 0
                CGPDFDictionaryGetBoolean(dict, "ImageMask", &isMask)
                s.images.append(DrawnImage(
                    pixelWidth: w, pixelHeight: h,
                    size: CGSize(width: hypot(s.ctm.a, s.ctm.b), height: hypot(s.ctm.c, s.ctm.d)),
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm),
                    placement: s.ctm, isMask: isMask != 0, inkIsBlack: s.g.inkIsBlack,
                    inkIsPure: s.g.inkIsPure, underGState: s.g.gstate, stream: stream))
            case "Form":
                guard s.depth < 4, let table = s.table else { return }
                // Draw the form's own content under its /Matrix.
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { CGPDFArrayGetNumber(array, i, &v[i]) }
                    matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var formResources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dict, "Resources", &formResources)
                // A form runs in its own graphics state: its q/Q pairs (even
                // unbalanced ones) must not touch the caller's stack.
                let outer = s.g, outerSaved = s.saved
                s.ctm = matrix.concatenating(outer.ctm)
                s.saved = []
                s.depth += 1
                let formContent = CGPDFContentStreamCreateWithStream(stream, formResources ?? dict, content)
                let formScanner = CGPDFScannerCreate(formContent, table, info)
                CGPDFScannerScan(formScanner)
                CGPDFScannerRelease(formScanner)
                CGPDFContentStreamRelease(formContent)
                s.depth -= 1
                s.g = outer
                s.saved = outerSaved
            default:
                break
            }
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        let completed = withExtendedLifetime(state) { CGPDFScannerScan(scanner) }
        guard completed else { return nil }
        return (images: state.images, names: state.names, paintsOther: state.paintsOther)
    }

    /// Whether the page is a black and white scan: it draws only images, each 1 bit to the
    /// pixel in gray drawing pure black and white (no /Decode but [0 1] or [1 0], no mask),
    /// or a stencil inked exactly black; none under an ExtGState, which may fade it; and it
    /// carries no annotations. Such a page has no grays of its own, only those its drawing
    /// and straightening blur in.
    static func isBitonalScan(_ page: PDFPage) -> Bool {
        guard page.annotations.isEmpty, let cgPage = page.pageRef,
              let content = drawnContent(cgPage), !content.paintsOther, !content.images.isEmpty else { return false }
        return content.images.allSatisfy { image in
            guard !image.underGState else { return false }
            if image.isMask { return image.inkIsPure }
            guard let dict = CGPDFStreamGetDictionary(image.stream) else { return false }
            var bits: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bits), bits == 1 else { return false }
            var other: CGPDFObjectRef?
            guard !CGPDFDictionaryGetObject(dict, "SMask", &other), !CGPDFDictionaryGetObject(dict, "Mask", &other)
            else { return false }
            var decode: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Decode", &decode), let decode {
                var a: CGPDFReal = -1, b: CGPDFReal = -1
                guard CGPDFArrayGetCount(decode) == 2, CGPDFArrayGetNumber(decode, 0, &a), CGPDFArrayGetNumber(decode, 1, &b),
                      a == 0 && b == 1 || a == 1 && b == 0 else { return false }
            }
            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(dict, "ColorSpace", &object), let object else { return false }
            return isGraySpace(object)
        }
    }

    /// DeviceGray, CalGray, or an ICC profile of one component.
    private static func isGraySpace(_ object: CGPDFObjectRef) -> Bool {
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name {
            return ["DeviceGray", "CalGray", "G"].contains(String(cString: name))
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetCount(array) >= 1,
              CGPDFArrayGetName(array, 0, &name), let name else { return false }
        switch String(cString: name) {
        case "CalGray", "DeviceGray", "G": return true     // [/DeviceGray], as Cherniss writes it
        case "ICCBased":
            var stream: CGPDFStreamRef?
            var n: CGPDFInteger = 0
            guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetInteger(dict, "N", &n) else { return false }
            return n == 1
        default: return false
        }
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
