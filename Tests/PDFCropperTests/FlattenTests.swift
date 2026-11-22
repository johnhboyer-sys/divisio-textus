import Testing
import Foundation
import CoreGraphics
@testable import PDFCropper

/// Flatten pages on synthetic leaves (`HCSynth`, drawn at 330 DPI) warped with a known
/// curl into the gutter (`HillClimbFlattenTests.warp`).
@Suite("Flatten")
@MainActor
struct FlattenTests {

    /// A full text leaf of the first synthetic book, its gray pixels, and whether its gutter is on the right.
    static func leaf() -> (g: [UInt8], w: Int, h: Int, right: Bool)? {
        guard let item = HillClimbFlattenTests.synthLeaves().first,
              let scan = HCSynth.render(item.spec, .scan) else { return nil }
        let rect = item.spec.leaves[item.leaf].paper.integral
            .intersection(CGRect(x: 0, y: 0, width: item.spec.W, height: item.spec.H))
        guard let cut = scan.cropping(to: rect) else { return nil }
        return (HillClimb.gray(cut), cut.width, cut.height, item.leaf == 0)
    }

    static func image(_ g: [UInt8], _ w: Int, _ h: Int) -> CGImage {
        HillClimbFlattenTests.image(g, w, h)!
    }

    static func meanCurl(_ image: CGImage) -> (curl: Double, glyphs: [HCGlyph]) {
        let c = HillClimbFlattenTests.curl(image, dpi: HillClimbFlattenTests.synthDPI, gutterOnRight: nil)
        return (c.meanPt, c.glyphs)
    }

    @Test("The option is off by default, in the export settings and in the app")
    func offByDefault() {
        #expect(!PDFExporter.Settings().flattenPages)
        #expect(!HillClimb.makeModel().flattenPages)
    }

    @Test("A straight page is left as it is")
    func straightUnchanged() throws {
        let l = try #require(Self.leaf())
        let im = Self.image(l.g, l.w, l.h)
        #expect(Flatten.pages(im, regions: [(CGRect(x: 0, y: 0, width: l.w, height: l.h), l.right)]) == nil)
        #expect(Flatten.report(l.g, width: l.w, height: l.h, gutterOnRight: l.right).outcome == .straight)
    }

    @Test("A page curled into the gutter comes back straight, every glyph kept")
    func curledFlattened() throws {
        let l = try #require(Self.leaf())
        let wp = HillClimbFlattenTests.Warp(band: 0.4, tilt: 30, drop: 10, squash: 0)
        let warped = HillClimbFlattenTests.warp(l.g, l.w, l.h, wp, gutterOnRight: l.right)
        let im = Self.image(warped, l.w, l.h)
        let flat = try #require(Flatten.pages(im, regions: [(CGRect(x: 0, y: 0, width: l.w, height: l.h), l.right)])?.image)
        #expect(flat.width == l.w && flat.height == l.h)
        let before = Self.meanCurl(im), after = Self.meanCurl(flat)
        #expect(after.curl < 0.4 * before.curl, "curl \(before.curl) -> \(after.curl) pt")
        let rep = Flatten.report(warped, width: l.w, height: l.h, gutterOnRight: l.right)
        let check = HillClimbFlattenTests.printCheck(before: im, after: flat, glyphsBefore: before.glyphs,
                                                     glyphsAfter: after.glyphs, model: rep.model)
        #expect(check.lost.isEmpty && check.merged.isEmpty, "lost \(check.lost.count), merged \(check.merged.count)")
    }

    @Test("Text too small to trace is left as it is")
    func tooSmall() throws {
        let l = try #require(Self.leaf())
        // A quarter the size: about 3 px letters.
        let w = l.w / 4, h = l.h / 4
        var g = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h { for x in 0..<w { g[y * w + x] = l.g[(4 * y) * l.w + 4 * x] } }
        #expect(Flatten.pages(Self.image(g, w, h), regions: [(CGRect(x: 0, y: 0, width: w, height: h), nil)]) == nil)
    }

    /// `g` with the rectangle (top-left pixels) painted `value`.
    static func paint(_ g: inout [UInt8], _ w: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ value: UInt8) {
        for y in y0..<y1 { for x in x0..<x1 { g[y * w + x] = value } }
    }

    /// Ink pixels (under 128) of `g` in the rectangle.
    static func inkCount(_ g: [UInt8], _ w: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
        var n = 0
        for y in y0..<y1 { for x in x0..<x1 where g[y * w + x] < 128 { n += 1 } }
        return n
    }

    /// The leaf curled so that flattening lifts the lines by its gutter (about 20 px at the top).
    static func liftedLeaf() throws -> (g: [UInt8], w: Int, h: Int, right: Bool) {
        let l = try #require(leaf())
        #expect(l.right, "the first leaf has its gutter on the right")
        let wp = HillClimbFlattenTests.Warp(band: 0.4, tilt: -30, drop: 10, squash: 0)
        return (HillClimbFlattenTests.warp(l.g, l.w, l.h, wp, gutterOnRight: true), l.w, l.h, true)
    }

    @Test("Review a: a folio on the crop's top row stays in the crop")
    func folioOnEdgeRow() throws {
        var l = try Self.liftedLeaf()
        // Three figures in the top margin by the gutter, their top on the crop's top row.
        let top = 60, fh = 25
        for k in 0..<3 { Self.paint(&l.g, l.w, 1850 + 18 * k, top, 1850 + 18 * k + 12, top + fh, 0) }
        let before = Self.inkCount(l.g, l.w, 1840, top, 1910, top + fh)
        let region = CGRect(x: 0, y: top, width: l.w, height: l.h - top)
        let out = Flatten.pages(Self.image(l.g, l.w, l.h), regions: [(region, true)])
        let g = out.map { HillClimb.gray($0.image) } ?? l.g
        let after = Self.inkCount(g, l.w, 1830, top, 1920, top + fh + 20)
        #expect(after * 10 >= before * 9, "folio ink \(before) -> \(after)")
    }

    @Test("Review a: a tall capital by the crop's top edge stays in the crop")
    func tallCapitalAtEdge() throws {
        var l = try Self.liftedLeaf()
        // A raised capital five x-heights tall by the gutter, 2 px under the crop's top.
        let top = 38
        Self.paint(&l.g, l.w, 1700, top, 1800, 150, 255)
        Self.paint(&l.g, l.w, 1720, top + 2, 1790, top + 2 + 95, 0)
        let before = Self.inkCount(l.g, l.w, 1700, top, 1800, top + 100)
        let region = CGRect(x: 0, y: top, width: l.w, height: l.h - top)
        let out = Flatten.pages(Self.image(l.g, l.w, l.h), regions: [(region, true)])
        let g = out.map { HillClimb.gray($0.image) } ?? l.g
        let after = Self.inkCount(g, l.w, 1690, top, 1810, top + 120)
        // Pushed up, its top would run into the crop's edge row: cut.
        let onEdge = Self.inkCount(g, l.w, 1690, top, 1810, top + 1)
        #expect(after * 100 >= before * 97 && onEdge == 0, "capital ink \(before) -> \(after), \(onEdge) on the edge row")
    }

    @Test("Review b: two close columns with offset baselines are not bent")
    func offsetColumns() throws {
        let l = try #require(Self.leaf())
        // The straight leaf cut into two columns 1.5 x-heights apart, the right one 8 px lower.
        let mid = 1023, gap = 14, drop = 8
        var g = [UInt8](repeating: 255, count: l.w * l.h)
        for y in 0..<l.h {
            for x in 0..<l.w where x < mid - gap || x >= mid + gap {
                let sy = x < mid ? y : y - drop
                if sy >= 0 { g[y * l.w + x] = l.g[sy * l.w + x] }
            }
        }
        let full = CGRect(x: 0, y: 0, width: l.w, height: l.h)
        let rep = Flatten.report(g, width: l.w, height: l.h, gutterOnRight: l.right)
        #expect(Flatten.pages(Self.image(g, l.w, l.h), regions: [(full, l.right)]) == nil,
                "\(rep.outcome) droop \(rep.droop) shift \(rep.maxShift) \(rep.note)")
        #expect(rep.note.contains("columns 2"), "\(rep.note)")
    }

    @Test("Review c: the Export view flattens small type the export flattens")
    func previewFlattensSmallType() async throws {
        let l = try #require(Self.leaf())
        let wp = HillClimbFlattenTests.Warp(band: 0.4, tilt: 30, drop: 10, squash: 0)
        let warped = Self.image(HillClimbFlattenTests.warp(l.g, l.w, l.h, wp, gutterOnRight: l.right), l.w, l.h)
        // Drawn at 300 DPI three fifths the size: x-height about 11 px at 300 DPI, 4 at 120.
        let w = Double(l.w) * 0.6, h = Double(l.h) * 0.6
        let media = CGRect(x: 0, y: 0, width: w * 72 / 300, height: h * 72 / 300)
        let url = Fixtures.writePDF("flatten-small-type.pdf", media: media, pages: [{ ctx in
            let small = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            small.interpolationQuality = .high
            small.draw(warped, in: CGRect(x: 0, y: 0, width: Int(w), height: Int(h)))
            ctx.draw(small.makeImage()!, in: media)
        }])
        let m = HillClimb.makeModel()
        await HillClimb.load(url, into: m)
        let page = try #require(m.pages.first)
        let pdfPage = try #require(m.document?.page(at: 0))
        // The export flattens it.
        var settings = PDFExporter.Settings(direction: m.direction, ocr: false, enhanceMode: m.enhanceMode)
        let rendered = try #require(PDFRenderer.renderCGImage(page: pdfPage, dpi: 300))
        let plainOut = try #require(PDFExporter.outputImages(of: page, rendered: rendered, settings: settings)?.first)
        settings.flattenPages = true
        let flatOut = try #require(PDFExporter.outputImages(of: page, rendered: rendered, settings: settings)?.first)
        #expect(HillClimb.gray(plainOut) != HillClimb.gray(flatOut), "the export flattens the page")
        // The Export view, once it has measured the page, shows it flattened: unlike the page
        // made the same size without the option.
        m.flattenPages = true
        var shown = try #require(m.outputPreview(for: page).first)
        func unflattened(_ image: CGImage) -> CGImage? {
            for dpi in [40.0, 120] {
                settings.flattenPages = false
                guard let r = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi),
                      let out = PDFExporter.outputImages(of: page, rendered: r, settings: settings)?.first else { continue }
                if out.width == image.width && out.height == image.height { return out }
            }
            return nil
        }
        let start = Date()
        while let u = unflattened(shown), HillClimb.gray(u) == HillClimb.gray(shown), Date().timeIntervalSince(start) < 60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            shown = try #require(m.outputPreview(for: page).first)
        }
        let u = try #require(unflattened(shown))
        #expect(HillClimb.gray(u) != HillClimb.gray(shown), "the Export view shows the page flattened")
    }

    @Test("A blank page is left as it is")
    func blank() {
        let g = [UInt8](repeating: 230, count: 400 * 600)
        #expect(Flatten.pages(Self.image(g, 400, 600), regions: [(CGRect(x: 0, y: 0, width: 400, height: 600), nil)]) == nil)
    }
}
