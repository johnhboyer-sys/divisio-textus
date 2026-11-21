import Testing
import Foundation
import AppKit
import PDFKit
@testable import PDFCropper

/// Draws the shadow score's real cases (`HillClimbShadowTests.cases`) before and after
/// Remove shadows, for the owner to judge by eye. Runs only when BW_SHOW_DIR and
/// HILLCLIMB_DIR are set; BW_SHOW_ONLY=name,name picks cases. For each case:
/// * `<case>.png`: every output page, in Color and in Black and white, without the option
///   (as exported before it) and with it, scaled smoothly to 1400 px tall;
/// * `<case>-100pct.png`: the fold side of each output page at 100%, 1.4 inch wide and
///   1.6 inch tall where the page without the option has most dark marks by the fold:
///   the scan in gray, then the four exports.
@Suite("BW show", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["BW_SHOW_DIR"] != nil
                    && ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct BWShowTests {

    @Test("Draw the cases")
    func draw() async throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["BW_SHOW_DIR"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = env["BW_SHOW_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        for c in HillClimbShadowTests.cases where only?.contains(c.name) ?? true {
            guard let (m, url, page) = await HillClimbShadowTests.loadCase(c) else { continue }
            var variants: [(label: String, pages: [CGImage])] = []
            var dpi = 300.0
            for (mode, enhance) in [("Color", EnhanceMode.color), ("Black and white", EnhanceMode.blackAndWhite)] {
                for remove in [false, true] {
                    var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false,
                                                        reader: m.ocrReader, packs: m.ocrPacks, enhanceMode: enhance)
                    settings.matchScanResolution = m.matchScanResolution
                    settings.removeShadows = remove
                    let pages = try HillClimbShadowTests.exported(page, from: url, settings: settings,
                                                                  name: "show-\(c.name)-\(variants.count).pdf")
                    variants.append(("\(mode)" + (remove ? ", Remove shadows" : ", before"), pages))
                }
            }
            // The scan in gray, cut as the color export is, at the color export's resolution.
            let doc = try #require(AppModel.reopen(url, password: nil))
            let src = try #require(doc.page(at: page.sourceIndex))
            if let first = variants[0].pages.first {
                let crop = page.outputCrops(direction: m.direction).first!
                dpi = Double(first.width) / (crop.width * src.bounds(for: .cropBox).width / 72)
            }
            var gray = PDFExporter.Settings(direction: m.direction)
            gray.enhanceMode = .grayscale
            let scans = PDFRenderer.renderCGImage(page: src, dpi: dpi)
                .flatMap { PDFExporter.outputImages(of: page, rendered: $0, settings: gray) } ?? []

            // Overview: one row per variant, the output pages side by side.
            var rows: [[(String, CGImage)]] = []
            for v in variants { rows.append(v.pages.enumerated().map { ("\(v.label) — page \($0.offset + 1)", $0.element) }) }
            if let image = Self.grid(rows, height: 1400) {
                HillClimb.png(image, to: dir.appendingPathComponent("\(c.name).png"))
            }
            // The fold side at 100%.
            var cropRows: [[(String, CGImage)]] = []
            let count = variants[0].pages.count
            for k in 0..<count {
                let before = variants[2].pages[k]       // black and white without the option: shows the marks
                let side = count == 2 ? (k == 0 ? 1 : -1) : Self.darkerSide(before)
                let r = Self.foldRect(before, side: side, dpi: dpi)
                var row: [(String, CGImage)] = []
                if k < scans.count, let s = Self.cut(scans[k], r, from: before) { row.append(("scan (gray) — page \(k + 1)", s)) }
                for v in variants where k < v.pages.count {
                    if let s = Self.cut(v.pages[k], r, from: before) { row.append((v.label, s)) }
                }
                cropRows.append(row)
            }
            if let image = Self.grid(cropRows, height: nil) {
                HillClimb.png(image, to: dir.appendingPathComponent("\(c.name)-100pct.png"))
            }
            print("BWSHOW \(c.name) pages=\(count) dpi=\(HillClimb.r(dpi, 1))")
        }
    }

    /// 1 for the right side, -1 for the left: the one with more dark pixels in its outer inch.
    static func darkerSide(_ image: CGImage) -> Int {
        let g = HillClimb.gray(image), w = image.width, h = image.height
        let band = max(1, w / 6)
        var l = 0, r = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in 0..<band where g[y * w + x] < 128 { l += 1 }
            for x in (w - band)..<w where g[y * w + x] < 128 { r += 1 }
        }
        return r >= l ? 1 : -1
    }

    /// 1.4 inch from the fold side by 1.6 inch, where `image` has most dark pixels in it.
    static func foldRect(_ image: CGImage, side: Int, dpi: Double) -> CGRect {
        let w = image.width, h = image.height
        let cw = min(w, Int(1.4 * dpi)), ch = min(h, Int(1.6 * dpi))
        let x0 = side > 0 ? w - cw : 0
        let g = HillClimb.gray(image)
        var perRow = [Int](repeating: 0, count: h)
        for y in 0..<h { for x in x0..<(x0 + cw) where g[y * w + x] < 128 { perRow[y] += 1 } }
        var best = 0, bestY = 0, sum = perRow[0..<ch].reduce(0, +)
        best = sum
        for y in 1...(h - ch) {
            sum += perRow[y + ch - 1] - perRow[y - 1]
            if sum > best { best = sum; bestY = y }
        }
        return CGRect(x: x0, y: bestY, width: cw, height: ch)
    }

    /// `r` (pixels of `ref`, top-left origin) cut from `image`, scaled to `ref`'s size first if they differ.
    static func cut(_ image: CGImage, _ r: CGRect, from ref: CGImage) -> CGImage? {
        guard image.width != ref.width || image.height != ref.height else { return image.cropping(to: r) }
        let sx = Double(image.width) / Double(ref.width), sy = Double(image.height) / Double(ref.height)
        return image.cropping(to: CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy))
    }

    /// Rows of labelled panels; each scaled smoothly to `height` if given (never nearest neighbour).
    static func grid(_ rows: [[(String, CGImage)]], height: Int?) -> CGImage? {
        let labelH = 44, gap = 16
        func size(_ im: CGImage) -> (Int, Int) {
            guard let height else { return (im.width, im.height) }
            return (Int((Double(im.width) * Double(height) / Double(im.height)).rounded()), height)
        }
        let rowSizes = rows.map { $0.map { size($0.1) } }
        let width = rowSizes.map { $0.reduce(0) { $0 + $1.0 + gap } }.max() ?? 0
        let total = rowSizes.reduce(0) { $0 + ($1.map(\.1).max() ?? 0) + labelH + gap }
        guard width > 0, total > 0,
              let ctx = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 0.78, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: total))
        var top = 0
        for (row, sizes) in zip(rows, rowSizes) {
            let rh = sizes.map(\.1).max() ?? 0
            var x = 0
            for ((label, im), (w, h)) in zip(row, sizes) {
                let y = total - top - labelH - h
                ctx.draw(im, in: CGRect(x: x, y: y, width: w, height: h))
                let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 26),
                                                                          .foregroundColor: NSColor.black])
                ctx.textPosition = CGPoint(x: x + 8, y: total - top - labelH + 12)
                CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
                x += w + gap
            }
            top += rh + labelH + gap
        }
        return ctx.makeImage()
    }
}
