import Testing
import Foundation
import CoreGraphics
import PDFKit
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

    /// The leaf with a raised capital at the gutter end of its first line, or a long tail
    /// below the gutter end of its last line, curled so the lines bend into the gutter (down
    /// at the top, up at the bottom); the running head, the short last line and the folio
    /// gone, so the crop can sit tight on the text.
    static func markedLeaf(top: Bool) throws -> (g: [UInt8], w: Int, h: Int) {
        var l = try #require(leaf())
        #expect(l.right, "the first leaf has its gutter on the right")
        paint(&l.g, l.w, 0, 100, l.w, 180, 255)
        paint(&l.g, l.w, 0, 2375, l.w, l.h, 255)
        if top {
            paint(&l.g, l.w, 1740, 200, 1810, 275, 255)
            paint(&l.g, l.w, 1750, 200, 1790, 257, 0)
        } else {
            paint(&l.g, l.w, 1740, 2328, 1810, 2375, 255)
            paint(&l.g, l.w, 1750, 2347, 1790, 2409, 0)
        }
        let wp = HillClimbFlattenTests.Warp(band: 0.4, tilt: -30, drop: 0, squash: 0)
        return (HillClimbFlattenTests.warp(l.g, l.w, l.h, wp, gutterOnRight: true), l.w, l.h)
    }

    @Test("Review 3: a raised capital by the gutter stays in a crop tight on the first line")
    func capitalTightTop() throws {
        let l = try Self.markedLeaf(top: true)
        // The crop 2 px above the first ink: the first baseline is under a line pitch below it.
        let first = try #require((0..<l.h).first { y in (0..<l.w).contains { l.g[y * l.w + $0] < 128 } })
        let top = first - 2
        let before = Self.inkCount(l.g, l.w, 1740, top, 1800, top + 55)
        let out = Flatten.pages(Self.image(l.g, l.w, l.h), regions: [(CGRect(x: 0, y: top, width: l.w, height: l.h - top), true)])
        let after = Self.inkCount(out.map { HillClimb.gray($0.image) } ?? l.g, l.w, 1740, top, 1800, top + 55)
        #expect(before > 1500 && after * 100 >= before * 97, "capital ink \(before) -> \(after)")
    }

    @Test("Review 3: a long tail by the gutter stays in a crop tight on the last line")
    func tailTightBottom() throws {
        let l = try Self.markedLeaf(top: false)
        let last = try #require((0..<l.h).last { y in (0..<l.w).contains { l.g[y * l.w + $0] < 128 } })
        let bottom = last + 3
        let before = Self.inkCount(l.g, l.w, 1740, bottom - 70, 1800, bottom)
        let out = Flatten.pages(Self.image(l.g, l.w, l.h), regions: [(CGRect(x: 0, y: 0, width: l.w, height: bottom), true)])
        let after = Self.inkCount(out.map { HillClimb.gray($0.image) } ?? l.g, l.w, 1740, bottom - 70, 1800, bottom)
        #expect(before > 1500 && after * 100 >= before * 97, "tail ink \(before) -> \(after)")
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

    /// A one-page PDF of the curled leaf scanned at 300 DPI three fifths the size: x-height
    /// about 11 px at 300 DPI, 4 at 120. Loaded into a new model, with its page.
    static func smallTypePDF() async throws -> (m: AppModel, page: BookPage, pdfPage: PDFPage) {
        let l = try #require(Self.leaf())
        let wp = HillClimbFlattenTests.Warp(band: 0.4, tilt: 30, drop: 10, squash: 0)
        let warped = Self.image(HillClimbFlattenTests.warp(l.g, l.w, l.h, wp, gutterOnRight: l.right), l.w, l.h)
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
        return (m, try #require(m.pages.first), try #require(m.document?.page(at: 0)))
    }

    @Test("Review c: the Export view flattens small type the export flattens")
    func previewFlattensSmallType() async throws {
        let (m, page, pdfPage) = try await Self.smallTypePDF()
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

    /// The leaf curled down by its gutter at the top and narrowed there, so flattening
    /// lowers the top lines and widens the letters by the gutter.
    static func squashedLeaf() throws -> (g: [UInt8], w: Int, h: Int) {
        let l = try #require(leaf())
        let wp = HillClimbFlattenTests.Warp(band: 0.4, tilt: 30, drop: 10, squash: 0.2)
        return (HillClimbFlattenTests.warp(l.g, l.w, l.h, wp, gutterOnRight: true), l.w, l.h)
    }

    @Test("Review 2, 1: a folio on the image's own first row stays in the crop")
    func folioOnImageEdge() throws {
        let l = try Self.liftedLeaf()
        // The leaf from row 60 down, three figures by the gutter on its first row: nothing is beyond.
        let top = 60, fh = 25, h = l.h - top
        var g = Array(l.g[(top * l.w)...])
        for k in 0..<3 { Self.paint(&g, l.w, 1850 + 18 * k, 0, 1850 + 18 * k + 12, fh, 0) }
        let before = Self.inkCount(g, l.w, 1840, 0, 1910, fh)
        let out = Flatten.pages(Self.image(g, l.w, h), regions: [(CGRect(x: 0, y: 0, width: l.w, height: h), true)])
        let after = Self.inkCount(out.map { HillClimb.gray($0.image) } ?? g, l.w, 1830, 0, 1920, fh + 20)
        #expect(after * 10 >= before * 9, "folio ink \(before) -> \(after)")
    }

    @Test("Review 2, 2: margin print on the crop's edge row, or in the color layer only, is squeezed 5% at most")
    func marginPrintSqueeze() throws {
        let l = try Self.squashedLeaf()
        let fh = 25
        func folio(_ g: inout [UInt8], _ y: Int) {
            for k in 0..<3 { Self.paint(&g, l.w, 1850 + 18 * k, y, 1850 + 18 * k + 12, y + fh, 0) }
        }
        // Blank, the gutter margin gives up to 30% of its width for widening; with a folio
        // in it (halfway down the page), 5%.
        let blank = Flatten.analyze(l.g, width: l.w, height: l.h, gutterOnRight: true).1
        var g = l.g
        folio(&g, 1400)
        let marked = Flatten.analyze(g, width: l.w, height: l.h, gutterOnRight: true).1
        #expect(marked.stretchPx < 0.7 * blank.stretchPx, "blank margin \(blank.stretchPx) px, with a folio \(marked.stretchPx)")
        // A folio by the gutter on the crop's top row, the row above the crop blank.
        let top = 60
        g = l.g
        folio(&g, top)
        let edge = Flatten.analyze(Array(g[(top * l.w)...]), width: l.w, height: l.h - top, gutterOnRight: true,
                                   outside: Flatten.Outside(above: [UInt8](repeating: 255, count: l.w), below: nil)).1
        #expect(edge.stretchPx <= marked.stretchPx + 0.5, "folio on the edge row: \(edge.stretchPx) px")
        // A folio in the color layer only (a layered scan).
        var color = l.g
        folio(&color, 1400)
        let colorOnly = Flatten.analyze(l.g, width: l.w, height: l.h, gutterOnRight: true, guardGray: color).1
        #expect(colorOnly.stretchPx <= marked.stretchPx + 0.5, "folio in the color layer: \(colorOnly.stretchPx) px")
    }

    @Test("Review 2, 3: print in the color layer only is not stretched by the fade at the crop's edge")
    func colorPrintFade() throws {
        let l = try #require(Self.leaf())
        // The running head (rows 115-150, by the gutter) in the color layer only, and the
        // first line ending short of the gutter, so no text by the gutter lies above the lines.
        var color = l.g
        Self.paint(&color, l.w, 1260, 222, l.w, 272, 255)
        var text = color
        Self.paint(&text, l.w, 0, 115, l.w, 150, 255)
        let wp = HillClimbFlattenTests.Warp(band: 0.4, tilt: -30, drop: 10, squash: 0)
        text = HillClimbFlattenTests.warp(text, l.w, l.h, wp, gutterOnRight: true)
        color = HillClimbFlattenTests.warp(color, l.w, l.h, wp, gutterOnRight: true)
        // The crop starts just above the head: flattening lifts the lines by the gutter, so
        // the shift fades over the rows above the text.
        let r = (x: 0, y: 125, w: l.w, h: l.h - 125)
        let model = Flatten.model(gray: text, width: l.w, height: l.h, region: r, gutterOnRight: true, guardGray: color)
        let before = Flatten.cut(color, width: l.w, r.x, r.y, r.w, r.h)
        let after = model.map { Flatten.warped(gray: color, width: l.w, region: r, model: $0) } ?? before
        // The head's height by the gutter: its first to last row of ink there.
        func height(_ g: [UInt8]) -> Int {
            let rows = (0..<80).filter { y in (1760..<1800).contains { g[y * r.w + $0] < 128 } }
            return (rows.last ?? 0) - (rows.first ?? 0) + 1
        }
        let h0 = height(before), h1 = height(after)
        #expect(h0 > 15 && abs(h1 - h0) * 100 <= 8 * h0, "head \(h0) rows -> \(h1)")
    }

    @Test("Review 2, 4: the Export view measures the warp again when the export resolution changes")
    func previewFollowsResolution() async throws {
        let (m, page, pdfPage) = try await Self.smallTypePDF()
        let settings = PDFExporter.Settings(direction: m.direction, ocr: false, enhanceMode: m.enhanceMode)
        let r = try #require(PDFRenderer.renderCGImage(page: pdfPage, dpi: 40))
        let plain = try #require(PDFExporter.outputImages(of: page, rendered: r, settings: settings)?.first)
        func shown() throws -> CGImage { try #require(m.outputPreview(for: page).first) }
        func settled() async throws -> CGImage {
            var s = try shown()
            let start = Date()
            while Date().timeIntervalSince(start) < 60 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if m.flattenJob == nil { s = try shown(); if m.flattenJob == nil { break } }
            }
            return s
        }
        // At the scan's own 300 DPI the export flattens the page, and so does the view.
        m.flattenPages = true
        _ = try shown()
        let at300 = try await settled()
        #expect(at300.width == plain.width && HillClimb.gray(at300) != HillClimb.gray(plain), "flattened at 300 DPI")
        // At 100 DPI the type is too small to trace: the export leaves the page as it is, so must the view.
        m.matchScanResolution = false
        m.exportDPI = 100
        _ = try shown()
        let at100 = try await settled()
        #expect(HillClimb.gray(at100) == HillClimb.gray(plain), "the view still shows the 300 DPI warp at 100 DPI")
    }

    @Test("A blank page is left as it is")
    func blank() {
        let g = [UInt8](repeating: 230, count: 400 * 600)
        #expect(Flatten.pages(Self.image(g, 400, 600), regions: [(CGRect(x: 0, y: 0, width: 400, height: 600), nil)]) == nil)
    }
}
