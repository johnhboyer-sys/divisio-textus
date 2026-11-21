import Foundation
import PDFKit
import CoreGraphics

/// Scans stored in layers ("mixed raster content"): a sharp 1-bit text layer, an
/// image mask painted in black, over small low-resolution color patches (paper
/// tint, the fold's shadow, the page edges, sometimes a picture). Drawn flat in
/// color such a page is many times the size of its source; its text layer alone,
/// at its own resolution, is the clean black-and-white page.
enum LayeredScan {

    struct Layers {
        /// The text layer: 1 bit per pixel, ink black, at its own resolution.
        let text: CGImage
        /// Where the text layer lands: its unit square → page space.
        let placement: CGAffineTransform
        /// Its resolution on the page.
        let dpi: Double
        /// The color patches beneath it.
        let patches: [PDFRenderer.DrawnImage]
    }

    /// The page's layers, or nil when it isn't stored this way: exactly one image
    /// mask, in black, covering most of the page at 200 DPI or more; every other
    /// image at most 3/4 of its resolution (or tiny); and nothing else painted.
    static func layers(of page: PDFPage) -> Layers? {
        guard let cgPage = page.pageRef, let content = PDFRenderer.drawnContent(cgPage),
              !content.paintsOther else { return nil }
        let visible = cgPage.getBoxRect(.cropBox)
        let pageArea = visible.width * visible.height
        let masks = content.images.filter(\.isMask)
        guard pageArea > 0, masks.count == 1, let mask = masks.first, mask.inkIsBlack else { return nil }
        let dpi = resolution(of: mask)
        let onPage = mask.bounds.intersection(visible)
        guard dpi >= 200, !onPage.isNull, onPage.width * onPage.height >= 0.5 * pageArea else { return nil }
        let patches = content.images.filter { !$0.isMask }
        for p in patches {
            let small = p.bounds.width * p.bounds.height <= 0.005 * pageArea
            guard small || resolution(of: p) <= 0.75 * dpi else { return nil }
        }
        guard let text = maskImage(mask.stream, width: mask.pixelWidth, height: mask.pixelHeight) else { return nil }
        return Layers(text: text, placement: mask.placement, dpi: dpi, patches: patches)
    }

    /// Pixels per inch as drawn, along the sharper axis.
    static func resolution(of image: PDFRenderer.DrawnImage) -> Double {
        guard image.size.width > 0, image.size.height > 0 else { return 0 }
        return max(Double(image.pixelWidth) / (image.size.width / 72),
                   Double(image.pixelHeight) / (image.size.height / 72))
    }

    /// An image mask's samples as a 1-bit gray image with ink black. In a mask a 0
    /// sample paints (with the default /Decode [0 1]), as 0 is black in gray, so the
    /// bits carry over as they are; /Decode [1 0] flips both.
    private static func maskImage(_ stream: CGPDFStreamRef, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == .raw else { return nil }
        let rowBytes = (width + 7) / 8
        guard CFDataGetLength(data) >= rowBytes * height else { return nil }
        var decode: [CGFloat] = [0, 1]
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Decode", &array), let array, CGPDFArrayGetCount(array) == 2 {
            var first: CGPDFReal = 0
            if CGPDFArrayGetNumber(array, 0, &first), first >= 0.5 { decode = [1, 0] }
        }
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: decode, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A color patch's pixels, or nil if Core Graphics can't hand them over
    /// (JPEG data, or raw 8-bit gray or RGB samples).
    static func patchImage(_ patch: PDFRenderer.DrawnImage) -> CGImage? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(patch.stream, &format),
              let provider = CGDataProvider(data: data) else { return nil }
        if format == .jpegEncoded {
            return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard format == .raw, let dict = CGPDFStreamGetDictionary(patch.stream) else { return nil }
        var bpc: CGPDFInteger = 0
        var space: UnsafePointer<CChar>?
        CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc)
        CGPDFDictionaryGetName(dict, "ColorSpace", &space)
        let components: Int
        switch space.map({ String(cString: $0) }) {
        case "DeviceGray": components = 1
        case "DeviceRGB": components = 3
        default: return nil
        }
        let w = patch.pixelWidth, h = patch.pixelHeight
        guard bpc == 8, w > 0, h > 0, CFDataGetLength(data) >= w * h * components else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * components,
                       bytesPerRow: w * components,
                       space: components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draw the text layer into `ctx` as `PDFRenderer.renderCGImage` draws the page
    /// at `scale` pixels per point: the crop box at the origin, turned by /Rotate.
    /// `over` keeps what is beneath where the layer has no ink (as the page draws it,
    /// a mask) instead of painting its paper white.
    static func drawText(_ layers: Layers, of page: PDFPage, in ctx: CGContext, scale: Double, over: Bool = false) {
        ctx.saveGState()
        if over { ctx.setBlendMode(.multiply) }
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.transform(for: .cropBox))
        ctx.concatenate(layers.placement)
        ctx.draw(layers.text, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.restoreGState()
    }

    /// Draw the color patches (decoded) likewise.
    static func drawPatches(_ patches: [(PDFRenderer.DrawnImage, CGImage)], of page: PDFPage,
                            in ctx: CGContext, scale: Double) {
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.transform(for: .cropBox))
        for (patch, image) in patches {
            ctx.saveGState()
            ctx.concatenate(patch.placement)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Run `draw`, which paints the page as a `width` × `height` render does, under
    /// the turns `ImageTransform.deskewedComposite` gives that render: a single page
    /// about its center, each half of a spread about its own center and kept to its
    /// half. One pass, so the text layer is resampled once, not twice.
    static func drawStraightened(_ page: BookPage, width w: Int, height h: Int,
                                 in ctx: CGContext, _ draw: (CGContext) -> Void) {
        let W = Double(w), H = Double(h)
        func turn(about x: Double, _ degrees: Double) {
            guard abs(degrees) > 0.01 else { return }
            ctx.translateBy(x: x, y: H / 2)
            ctx.rotate(by: degrees * .pi / 180)
            ctx.translateBy(x: -x, y: -H / 2)
        }
        if !page.isSpread {
            ctx.saveGState(); turn(about: W / 2, page.leftSkew); draw(ctx); ctx.restoreGState()
            return
        }
        let split = Double(max(1, min(w - 1, Int(page.splitX * W))))
        for (half, degrees) in [(CGRect(x: 0, y: 0, width: split, height: H), page.leftSkew),
                                (CGRect(x: split, y: 0, width: W - split, height: H), page.rightSkew)] {
            ctx.saveGState()
            ctx.clip(to: half)
            turn(about: half.midX, degrees)
            ctx.clip(to: half)
            draw(ctx)
            ctx.restoreGState()
        }
    }

    /// An 8-bit gray canvas the size of the page drawn at `dpi`, white, with `draw`
    /// done straightened as the page's export is. Top-left origin rows.
    static func straightened(_ page: BookPage, _ pdfPage: PDFPage, dpi: Double,
                             _ draw: (CGContext, Double) -> Void) -> (pixels: [UInt8], width: Int, height: Int)? {
        let size = PDFRenderer.displaySize(of: pdfPage)
        let scale = dpi / 72
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        guard w.isFinite, h.isFinite, w >= 1, h >= 1, w * h <= 2_000_000_000 else { return nil }
        let pw = Int(w), ph = Int(h)
        var pixels = [UInt8](repeating: 255, count: pw * ph)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: pw, height: ph, bitsPerComponent: 8,
                                      bytesPerRow: pw, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            drawStraightened(page, width: pw, height: ph, in: ctx) { draw($0, scale) }
            return true
        }
        return ok ? (pixels, pw, ph) : nil
    }

    /// The crop's pixel rectangle in a `width` × `height` image, as `PDFRenderer.crop` cuts it.
    private static func pixelRect(_ crop: CropRect, width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        let px = crop.normalized().pixelRect(in: CGSize(width: width, height: height)).integral
        let r = px.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        return (Int(r.minX), Int(r.minY), Int(r.width), Int(r.height))
    }

    /// The page's output pages, in reading order, as black-and-white pages: both
    /// layers drawn together at the text layer's own resolution (the color layer
    /// smoothly enlarged), straightened and cut as the color export would be, then
    /// turned to black and white by `BlackAndWhite.ink` with the text layer as the
    /// sharp layer: body text stays the text layer pixel for pixel, print the
    /// scanner left only in the color layer (a stamp, a rule, parts of big
    /// letters) turns black, and shadows, tint and dark bands at the fold or the
    /// page's edges turn white. 8-bit gray holding only 0 and 255, which the
    /// exporter packs to 1 bit. An entry is nil where the color layer holds a
    /// picture inside that page (see `holdsPicture`): that page keeps the color
    /// export. nil if a crop fails. With `previewDPI` the pages are drawn small and
    /// their ink left gray: a small 1-bit page looks broken, a gray one doesn't.
    /// `removeShadows` as for `BlackAndWhite.ink`.
    static func textPages(of page: BookPage, _ pdfPage: PDFPage, layers: Layers,
                          direction: ReadingDirection, previewDPI: Double? = nil,
                          removeShadows: Bool = false) -> [CGImage?]? {
        let crops = page.outputCrops(direction: direction)
        let marked = holdsPicture(page, pdfPage, layers: layers, crops: crops)
        guard crops.indices.contains(where: { !marked[$0] }) else { return crops.map { _ in nil } }
        let dpi = previewDPI ?? textDPI(layers)
        // Patches that can't be decoded were found to be pictures above; any left
        // out here would only be paper.
        let decoded = layers.patches.compactMap { p in patchImage(p).map { (p, $0) } }
        guard let text = straightened(page, pdfPage, dpi: dpi, { ctx, scale in
                  drawText(layers, of: pdfPage, in: ctx, scale: scale) }),
              let both = straightened(page, pdfPage, dpi: dpi, { ctx, scale in
                  drawPatches(decoded, of: pdfPage, in: ctx, scale: scale)
                  drawText(layers, of: pdfPage, in: ctx, scale: scale, over: true) }) else { return nil }
        var out: [CGImage?] = []
        for (k, crop) in crops.enumerated() {
            guard let r = pixelRect(crop, width: text.width, height: text.height) else { return nil }
            if marked[k] { out.append(nil); continue }
            var gray = [UInt8](repeating: 255, count: r.w * r.h)
            var sharp = [Bool](repeating: false, count: r.w * r.h)
            for y in 0..<r.h {
                let row = (r.y + y) * text.width + r.x
                for x in 0..<r.w {
                    gray[y * r.w + x] = both.pixels[row + x]
                    sharp[y * r.w + x] = text.pixels[row + x] < (previewDPI != nil ? 192 : 128)
                }
            }
            let ink = BlackAndWhite.ink(gray: gray, sharp: sharp, tone: true, width: r.w, height: r.h,
                                        dpi: dpi, preview: previewDPI != nil, removeShadows: removeShadows)
            guard let image = BlackAndWhite.image(ink, width: r.w, height: r.h) else { return nil }
            out.append(image)
        }
        return out
    }

    /// The resolution text pages are made at: the text layer's own, within the
    /// export's usual 150–600 DPI. Never lower: thinning a 1-bit layer breaks letters.
    static func textDPI(_ layers: Layers) -> Double { min(600, max(150, layers.dpi.rounded())) }

    /// Whether the color layer holds a picture inside each crop. Measured at 50 DPI
    /// on both layers, straightened as the export is. A mark is a color-layer pixel
    /// at least 20% darker than the brightest paper within 0.2 inch (so the tint and
    /// slow shading aren't marks) and more than 0.04 inch from the text layer's ink
    /// (the color layer carries a blurred copy of the text). A picture is a group of
    /// touching marks at least 0.4 inch each way, mostly inside the crop. Groups that
    /// run to within 0.06 inch of the page half's edge (or of 0.3 inch past the crop) are the
    /// fold's shadow, the page's edge or the scanner bed, and don't count; nor do
    /// thin ones: pen, a stamp, a printed rule. Over `pictureLimit` square inches of
    /// picture and the crop keeps its color.
    static func holdsPicture(_ page: BookPage, _ pdfPage: PDFPage, layers: Layers, crops: [CropRect]) -> [Bool] {
        pictureArea(of: page, pdfPage, layers: layers, crops: crops).map { $0 > pictureLimit }
    }

    static let pictureLimit = 0.15

    /// Square inches of picture inside each crop (see `holdsPicture`). Infinity for
    /// every crop when a patch can't be decoded: unseen, it might be a picture.
    static func pictureArea(of page: BookPage, _ pdfPage: PDFPage, layers: Layers, crops: [CropRect]) -> [Double] {
        let dpi = 50.0
        var decoded: [(PDFRenderer.DrawnImage, CGImage)] = []
        for patch in layers.patches {
            guard let image = patchImage(patch) else { return crops.map { _ in .infinity } }
            decoded.append((patch, image))
        }
        guard !decoded.isEmpty else { return crops.map { _ in 0 } }
        guard let color = straightened(page, pdfPage, dpi: dpi, { ctx, scale in
                  drawPatches(decoded, of: pdfPage, in: ctx, scale: scale) }),
              let text = straightened(page, pdfPage, dpi: dpi, { ctx, scale in
                  drawText(layers, of: pdfPage, in: ctx, scale: scale) }) else { return crops.map { _ in .infinity } }
        let w = color.width, h = color.height
        let paper = maxFilter(color.pixels, w, h, radius: 10)          // 0.2 inch
        let nearInk = minFilter(text.pixels, w, h, radius: 2)          // 0.04 inch
        let split = page.isSpread ? max(1, min(w - 1, Int(page.splitX * Double(w)))) : w
        return crops.map { crop in
            guard let c = pixelRect(crop, width: w, height: h) else { return 0 }
            // The window: the crop and 0.3 inch around it, within its half.
            let leftHalf = c.x + c.w / 2 < split
            let lo = leftHalf ? 0 : split, hi = leftHalf ? split : w
            let x0 = max(lo, c.x - 15), x1 = min(hi, c.x + c.w + 15)
            let y0 = max(0, c.y - 15), y1 = min(h, c.y + c.h + 15)
            let ww = x1 - x0, wh = y1 - y0
            guard ww > 2, wh > 2 else { return 0 }
            var mark = [Bool](repeating: false, count: ww * wh)
            for y in 0..<wh {
                for x in 0..<ww {
                    let i = (y0 + y) * w + x0 + x
                    mark[y * ww + x] = Int(paper[i]) - Int(color.pixels[i]) >= 51 && nearInk[i] > 230
                }
            }
            // Each group of touching marks, by flood fill.
            var counted = 0
            var stack: [Int] = []
            for start in mark.indices where mark[start] {
                mark[start] = false
                stack.append(start)
                var size = 0, inside = 0, atEdge = false
                var minX = ww, maxX = 0, minY = wh, maxY = 0
                while let k = stack.popLast() {
                    size += 1
                    let x = k % ww, y = k / ww
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    if x <= 2 || y <= 2 || x >= ww - 3 || y >= wh - 3 { atEdge = true }
                    let px = x0 + x, py = y0 + y
                    if px >= c.x, px < c.x + c.w, py >= c.y, py < c.y + c.h { inside += 1 }
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < ww, ny < wh, mark[ny * ww + nx] else { continue }
                        mark[ny * ww + nx] = false
                        stack.append(ny * ww + nx)
                    }
                }
                if !atEdge, maxX - minX >= 19, maxY - minY >= 19, inside * 2 >= size { counted += size }
            }
            return Double(counted) / (dpi * dpi)
        }
    }

    /// Each pixel's largest value within `radius` (a square), done by rows then columns.
    static func maxFilter(_ p: [UInt8], _ w: Int, _ h: Int, radius r: Int) -> [UInt8] {
        filter(p, w, h, r, max)
    }

    static func minFilter(_ p: [UInt8], _ w: Int, _ h: Int, radius r: Int) -> [UInt8] {
        filter(p, w, h, r, min)
    }

    private static func filter(_ p: [UInt8], _ w: Int, _ h: Int, _ r: Int, _ pick: (UInt8, UInt8) -> UInt8) -> [UInt8] {
        var rows = p
        for y in 0..<h {
            for x in 0..<w {
                var v = p[y * w + x]
                for k in max(0, x - r)...min(w - 1, x + r) { v = pick(v, p[y * w + k]) }
                rows[y * w + x] = v
            }
        }
        var out = rows
        for y in 0..<h {
            for x in 0..<w {
                var v = rows[y * w + x]
                for k in max(0, y - r)...min(h - 1, y + r) { v = pick(v, rows[k * w + x]) }
                out[y * w + x] = v
            }
        }
        return out
    }
}
