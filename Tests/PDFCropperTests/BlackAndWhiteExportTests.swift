import Testing
import Foundation
import PDFKit
@testable import PDFCropper

/// Black and white that never loses ink: shadows and bands go white, print in or
/// touching them stays, print the scanner left only in a layered scan's color layer
/// turns black, and scans not stored in layers export as before unless asked.
@Suite("Black and white export")
struct BlackAndWhiteExportTests {
    /// A 3 × 4 inch page at 300 DPI.
    static let w = 900, h = 1200, dpi = 300.0

    /// Letter-like marks: an "o" and an "l" of 3-pixel strokes, 30 pixels tall,
    /// with their top-left at (x, y). The pixels they cover.
    static func glyphs(_ x: Int, _ y: Int) -> [Int] {
        var px = Set<Int>()
        func bar(_ x0: Int, _ y0: Int, _ bw: Int, _ bh: Int) {
            for yy in y0..<(y0 + bh) { for xx in x0..<(x0 + bw) { px.insert(yy * w + xx) } }
        }
        bar(x, y + 8, 3, 22); bar(x + 17, y + 8, 3, 22); bar(x, y + 8, 20, 3); bar(x, y + 27, 20, 3)   // o
        bar(x + 28, y, 3, 30)                                                                            // l
        return Array(px)
    }

    /// Lines of glyph pairs filling a box.
    static func text(in box: CGRect) -> [Int] {
        var px: [Int] = []
        for y in stride(from: Int(box.minY), to: Int(box.maxY) - 40, by: 50) {
            for x in stride(from: Int(box.minX), to: Int(box.maxX) - 40, by: 45) { px += glyphs(x, y) }
        }
        return px
    }

    /// A soft fold shadow along the left side, 1.2 inch wide: 120 at the side to the paper's 235.
    static func shadowed() -> [UInt8] {
        var g = [UInt8](repeating: 235, count: w * h)
        for y in 0..<h {
            for x in 0..<360 {
                let t = 1 - Double(x) / 360
                g[y * w + x] = UInt8(235 - 115 * t * t)
            }
        }
        return g
    }

    private func inkShare(_ out: [UInt8], _ px: [Int]) -> Double {
        Double(px.filter { out[$0] == 0 }.count) / Double(max(1, px.count))
    }

    @Test("A faint glyph inside a soft shadow survives; the shadow goes white")
    func faintGlyphInShadow() {
        var g = Self.shadowed()
        let faint = Self.glyphs(80, 300) + Self.glyphs(150, 600)
        for i in faint { g[i] = UInt8(max(0, Int(g[i]) - 50)) }      // 50 darker than the shadow it sits in
        let out = BlackAndWhite.ink(gray: g, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(inkShare(out, faint) > 0.95, "\(inkShare(out, faint))")
        let marks = Set(faint)
        let stray = out.indices.filter { out[$0] == 0 && !marks.contains($0) }.count
        #expect(stray < 200, "\(stray) shadow pixels turned black")
    }

    @Test("A soft shadow alone goes white")
    func shadowAlone() {
        let out = BlackAndWhite.ink(gray: Self.shadowed(), sharp: nil, tone: true,
                                    width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(out.allSatisfy { $0 == 255 })
    }

    @Test("Sharp-layer text inside a soft shadow stays pixel for pixel; its speckle goes")
    func sharpTextInShadow() {
        var g = Self.shadowed()
        var sharp = [Bool](repeating: false, count: Self.w * Self.h)
        let text = Self.text(in: CGRect(x: 40, y: 100, width: 700, height: 1000))
        for i in text { sharp[i] = true; g[i] = 0 }
        // A scanner's speckle in the darkest of the shadow: lone black pixels.
        var rng = HCRandom(11)
        var speckle: [Int] = []
        for y in 0..<Self.h { for x in 0..<30 where rng.chance(0.25) {
            let i = y * Self.w + x
            if !sharp[i] { sharp[i] = true; g[i] = 0; speckle.append(i) }
        } }
        let out = BlackAndWhite.ink(gray: g, sharp: sharp, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(inkShare(out, text) > 0.99)
        // Lone specks and small clusters go; a few clusters the size of a full stop stay.
        #expect(inkShare(out, speckle) < 0.1, "\(inkShare(out, speckle))")
    }

    /// A black-and-white page: text, and a solid black fold band 0.1 inch wide down
    /// the right side.
    static func banded() -> (gray: [UInt8], text: [Int], band: [Int]) {
        var g = [UInt8](repeating: 255, count: w * h)
        let text = Self.text(in: CGRect(x: 100, y: 100, width: 650, height: 900))
        for i in text { g[i] = 0 }
        var band: [Int] = []
        for y in 0..<h { for x in 870..<w { band.append(y * w + x); g[y * w + x] = 0 } }
        return (g, text, band)
    }

    @Test("A black fold band with no glyphs goes white; the text stays")
    func bandGoesWhite() {
        let page = Self.banded()
        let out = BlackAndWhite.ink(gray: page.gray, sharp: nil, tone: false,
                                    width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(inkShare(out, page.band) < 0.01)
        #expect(inkShare(out, page.text) == 1)
    }

    @Test("A folio touching the band survives")
    func folioTouchingBand() {
        var page = Self.banded()
        // "10" at the foot, its right stroke against the band.
        var folio: [Int] = []
        for y in 1100..<1140 {
            for x in 830..<834 { folio.append(y * Self.w + x) }                    // 1
            for x in 846..<870 where x < 850 || x >= 866 || y < 1104 || y >= 1136 {  // 0
                folio.append(y * Self.w + x)
            }
        }
        for i in folio { page.gray[i] = 0 }
        let out = BlackAndWhite.ink(gray: page.gray, sharp: nil, tone: false,
                                    width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(inkShare(out, folio) > 0.95)
        #expect(inkShare(out, page.band) < 0.01)
    }

    @Test("Print only in a layered scan's color layer comes out black")
    func colorLayerPrint() throws {
        let bits = LayeredFixture.textBits()
        // The color layer: tinted paper with a printed rule and a solid letter-sized
        // block the text layer doesn't hold, at 75 DPI.
        let rule = CGRect(x: 40, y: 20, width: 200, height: 3)      // in color-layer pixels, top-left origin
        let block = CGRect(x: 300, y: 12, width: 12, height: 16)
        let color = LayeredFixture.jpeg(375, 225) { x, y in
            let p = CGPoint(x: x, y: y)
            return rule.contains(p) || block.contains(p) ? (60, 55, 50) : (238, 232, 205)
        }
        let url = LayeredFixture.write("bw-colorink.pdf", [
            .init(bits: bits, patches: [.init(jpeg: color, width: 375, height: 225,
                                              rect: CGRect(origin: .zero, size: LayeredFixture.size))])])
        let doc = try #require(PDFDocument(url: url))
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        let layers = try #require(LayeredScan.layers(of: doc.page(at: 0)!))
        let out = try #require(LayeredScan.textPages(of: page, doc.page(at: 0)!, layers: layers,
                                                     direction: .leftToRight, bothLayers: true)?.first ?? nil)
        let px = BlackAndWhite.grayPixels(out)
        #expect(Set(px).isSubset(of: [0, 255]))
        // Text layer pixels are 4 per color-layer pixel.
        func share(_ r: CGRect) -> Double {
            let inner = r.insetBy(dx: 0.5, dy: 0.5)
            var n = 0, black = 0
            for y in Int(inner.minY * 4)..<Int(inner.maxY * 4) {
                for x in Int(inner.minX * 4)..<Int(inner.maxX * 4) { n += 1; if px[y * out.width + x] == 0 { black += 1 } }
            }
            return Double(black) / Double(max(1, n))
        }
        #expect(share(rule) > 0.9)
        #expect(share(block) > 0.9)
        // The text layer's ink is all there.
        let rowBytes = (LayeredFixture.maskWidth + 7) / 8
        var lost = 0, inkCount = 0
        for y in 0..<LayeredFixture.maskHeight {
            for x in 0..<LayeredFixture.maskWidth where bits[y * rowBytes + x / 8] & UInt8(0x80 >> (x % 8)) == 0 {
                inkCount += 1
                if px[y * out.width + x] != 0 { lost += 1 }
            }
        }
        #expect(lost == 0, "\(lost) of \(inkCount) text-layer pixels lost")
        // Tinted paper is white.
        #expect(px.filter { $0 == 255 }.count * 10 > px.count * 8)
    }

    @Test("Review 1: sparse pale print (gray 150, about 1% of the page) stays, with and without Remove shadows")
    func sparsePalePrint() throws {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        let text = Self.text(in: CGRect(x: 100, y: 100, width: 700, height: 150))
        for i in text { g[i] = 150 }
        let share = Double(text.count) / Double(Self.w * Self.h)
        #expect(share > 0.005 && share < 0.02, "\(share)")
        let out = BlackAndWhite.ink(gray: g, sharp: nil, tone: BlackAndWhite.holdsTones(g, width: Self.w, height: Self.h),
                                    width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(inkShare(out, text) > 0.95, "black and white: \(inkShare(out, text))")
        let on = BlackAndWhite.ink(gray: g, sharp: nil, tone: BlackAndWhite.holdsTones(g, width: Self.w, height: Self.h),
                                   width: Self.w, height: Self.h, dpi: Self.dpi, removeShadows: true)
        #expect(inkShare(on, text) > 0.95, "black and white, Remove shadows: \(inkShare(on, text))")
        let image = try #require(BlackAndWhite.image(g, width: Self.w, height: Self.h))
        let gray = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        let kept = text.filter { gray[$0] < 200 }.count
        #expect(Double(kept) > 0.95 * Double(text.count), "gray, Remove shadows: \(kept) of \(text.count)")
    }

    @Test("Review 1b: pale print (gray 150, 1%) beside black print (1%) stays")
    func palePrintBesideBlack() throws {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        let pale = Self.text(in: CGRect(x: 100, y: 100, width: 700, height: 150))
        let black = Self.text(in: CGRect(x: 100, y: 700, width: 700, height: 150))
        for i in pale { g[i] = 150 }
        for i in black { g[i] = 0 }
        let out = BlackAndWhite.ink(gray: g, sharp: nil, tone: BlackAndWhite.holdsTones(g, width: Self.w, height: Self.h),
                                    width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(inkShare(out, pale) > 0.95, "\(inkShare(out, pale))")
        #expect(inkShare(out, black) > 0.95)
    }

    @Test("Review 3b: a black figure 2 inches tall, 0.05 inch from the side, stays")
    func tallFigureNearSide() throws {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        let text = Self.text(in: CGRect(x: 380, y: 100, width: 480, height: 1000))
        for i in text { g[i] = 0 }
        var figure: [Int] = []
        for y in 300..<900 { for x in 15..<315 { figure.append(y * Self.w + x) } }
        for i in figure { g[i] = 10 }
        let image = try #require(BlackAndWhite.image(g, width: Self.w, height: Self.h))
        for remove in [false, true] {
            let bw = BlackAndWhite.page(image, dpi: Self.dpi, removeShadows: remove).map(BlackAndWhite.grayPixels) ?? g
            #expect(Double(figure.filter { bw[$0] < 128 }.count) > 0.95 * Double(figure.count), "remove \(remove)")
        }
        let gray = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(figure.filter { gray[$0] < 128 }.count) > 0.95 * Double(figure.count))
    }

    @Test("Review 3c: a tall figure near the side stays though a separate dark strip runs down the crop's edge")
    func tallFigureBesideEdgeStrip() throws {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        let text = Self.text(in: CGRect(x: 380, y: 100, width: 480, height: 1000))
        for i in text { g[i] = 0 }
        var figure: [Int] = []
        for y in 300..<900 { for x in 15..<315 { figure.append(y * Self.w + x) } }
        for i in figure { g[i] = 10 }
        for y in 300..<900 { for x in 0..<2 { g[y * Self.w + x] = 10 } }     // paper between it and the figure
        let image = try #require(BlackAndWhite.image(g, width: Self.w, height: Self.h))
        for remove in [false, true] {
            let bw = BlackAndWhite.page(image, dpi: Self.dpi, removeShadows: remove).map(BlackAndWhite.grayPixels) ?? g
            #expect(Double(figure.filter { bw[$0] < 128 }.count) > 0.95 * Double(figure.count), "remove \(remove)")
        }
        let gray = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(figure.filter { gray[$0] < 128 }.count) > 0.95 * Double(figure.count))
    }

    @Test("Review 3d: a gray outline letter inside a small gray shadow is read as tones and stays")
    func grayLetterInSmallShadow() {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        for y in 500..<596 { for x in 400..<496 { g[y * Self.w + x] = 125 } }
        // A 20 x 22 outline letter, 1-px strokes, centred in it.
        var letter: [Int] = []
        for x in 438..<458 { letter += [537 * Self.w + x, 558 * Self.w + x] }
        for y in 537..<559 { letter += [y * Self.w + 438, y * Self.w + 457] }
        for i in letter { g[i] = 100 }
        #expect(BlackAndWhite.holdsTones(g, width: Self.w, height: Self.h))
        let out = BlackAndWhite.ink(gray: g, sharp: nil, tone: BlackAndWhite.holdsTones(g, width: Self.w, height: Self.h),
                                    width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(inkShare(out, letter) > 0.9, "\(inkShare(out, letter))")
    }

    @Test("Review 4c: on a layered scan's shadow a hairline piece beside a letter stays; specks away from letters go")
    func hairlineBesideLetterOnShadow() {
        var g = Self.shadowed()
        var sharp = [Bool](repeating: false, count: Self.w * Self.h)
        let text = Self.text(in: CGRect(x: 40, y: 100, width: 700, height: 1000))
        for i in text { sharp[i] = true; g[i] = 0 }
        // A broken-off hairline, 1 x 12 px, 2 px right of a letter's l (113..115), in the shadow.
        var hair: [Int] = []
        for y in 600..<612 { hair.append(y * Self.w + 118) }
        for i in hair { sharp[i] = true; g[i] = 0 }
        // Lone specks well away from any letter, in the darkest of the shadow.
        let specks = [(20, 60), (25, 1150), (10, 1180)].map { $0.1 * Self.w + $0.0 }
        for i in specks { sharp[i] = true; g[i] = 0 }
        let out = BlackAndWhite.ink(gray: g, sharp: sharp, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(inkShare(out, hair) == 1, "\(inkShare(out, hair))")
        #expect(inkShare(out, specks) == 0)
        #expect(inkShare(out, text) > 0.99)
    }

    @Test("Review 4d: on a layered scan's shadow a small letter's dot stays beside its stem")
    func smallLetterDotOnShadow() {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        for y in 500..<596 { for x in 400..<496 { g[y * Self.w + x] = 125 } }
        var sharp = [Bool](repeating: false, count: Self.w * Self.h)
        var stem: [Int] = [], dot: [Int] = []
        for y in 537..<557 { for x in 444..<446 { stem.append(y * Self.w + x) } }
        for y in 532..<535 { dot.append(y * Self.w + 444) }
        for i in stem + dot { sharp[i] = true; g[i] = 0 }
        let out = BlackAndWhite.ink(gray: g, sharp: sharp, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(inkShare(out, stem) == 1)
        #expect(inkShare(out, dot) == 1, "\(inkShare(out, dot))")
    }

    /// `text` drawn black on white with CoreText, `points` tall at `dpi`, its baseline at
    /// `baseline` px from the top and starting at `x`: 0 for ink, 255 for paper, smoothed.
    static func rendered(_ text: String, font name: String, points: Double, dpi: Double,
                         x: Double, baseline: Double, into px: inout [UInt8]) -> String {
        let font = CTFontCreateWithName(name as CFString, points * dpi / 72, nil)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        px.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.textPosition = CGPoint(x: x, y: Double(h) - baseline)
            CTLineDraw(line, ctx)
        }
        return CTFontCopyPostScriptName(font) as String
    }

    @Test("Review 4f: a piece beside a big kept group is judged by the whole group, not the part searched first")
    func pieceBesideBigGroup() {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        for y in 450..<900 { for x in 250..<700 { g[y * Self.w + x] = 125 } }
        var sharp = [Bool](repeating: false, count: Self.w * Self.h)
        // A 2-px diagonal, 600 px with no straight run of 6, ending in an upright bar.
        var group: [Int] = []
        for i in 0..<300 { group += [(520 + i) * Self.w + 300 + i, (520 + i) * Self.w + 301 + i] }
        for y in 820..<840 { for x in 600..<603 { group.append(y * Self.w + x) } }
        let piece = [516 * Self.w + 296, 516 * Self.w + 297, 517 * Self.w + 296, 517 * Self.w + 297]
        for i in group + piece { sharp[i] = true; g[i] = 0 }
        let out = BlackAndWhite.ink(gray: g, sharp: sharp, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi)
        #expect(inkShare(out, group) == 1, "the group is kept: \(inkShare(out, group))")
        #expect(inkShare(out, piece) == 1, "\(inkShare(out, piece))")
    }

    /// One case at a time: drawing with CoreText from parallel cases stalled the run.
    @Test("Review 4e: Greek accents and breathings and italic dots on a layered scan's shadow stay")
    func accentsOnShadow() {
        for dpi in [300.0, 200.0, 150.0] { for points in [9.0, 7.0, 6.0] { accents(dpi: dpi, points: points) } }
    }

    private func accents(dpi: Double, points: Double) {
        var ink = [UInt8](repeating: 255, count: Self.w * Self.h)
        let greek = Self.rendered("ά ὁ ῆ ἐ", font: "TimesNewRomanPSMT", points: points, dpi: dpi, x: 150, baseline: 500, into: &ink)
        let italic = Self.rendered("i é ö", font: "TimesNewRomanPS-ItalicMT", points: points, dpi: dpi, x: 150, baseline: 600,
                                   into: &ink)
        // The gray-125 shadow under them, on gray-235 paper; the sharp layer is the drawn ink.
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        var sharp = [Bool](repeating: false, count: Self.w * Self.h)
        for y in 400..<700 { for x in 100..<700 { g[y * Self.w + x] = 125 } }
        for i in g.indices {
            g[i] = UInt8(Int(g[i]) * Int(ink[i]) / 255)
            sharp[i] = ink[i] < 128
        }
        let out = BlackAndWhite.ink(gray: g, sharp: sharp, tone: true, width: Self.w, height: Self.h, dpi: dpi)
        // Every piece of every letter (bodies, accents, breathings, dots) keeps its ink.
        var seen = [Bool](repeating: false, count: Self.w * Self.h)
        var pieces = 0, lost: [String] = []
        for s in sharp.indices where sharp[s] && !seen[s] {
            var stack = [s], piece: [Int] = []
            seen[s] = true
            while let k = stack.popLast() {
                piece.append(k)
                let x = k % Self.w, y = k / Self.w
                for ny in max(0, y - 1)...min(Self.h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(Self.w - 1, x + 1) where sharp[ny * Self.w + nx] && !seen[ny * Self.w + nx] {
                        seen[ny * Self.w + nx] = true; stack.append(ny * Self.w + nx)
                    }
                }
            }
            pieces += 1
            let kept = piece.filter { out[$0] == 0 }.count
            if kept * 10 < piece.count * 9 {
                lost.append("\(piece.count) px at (\(piece[0] % Self.w), \(piece[0] / Self.w)) kept \(kept)")
            }
        }
        #expect(pieces >= 12, "\(pieces) pieces drawn (\(greek), \(italic))")
        #expect(lost.isEmpty, "\(points) pt at \(dpi) DPI, \(greek)/\(italic): lost \(lost)")
    }

    @Test("Review 3: a black figure an inch square, 0.05 inch from the side, stays")
    func figureNearSide() throws {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        let text = Self.text(in: CGRect(x: 380, y: 100, width: 480, height: 1000))
        for i in text { g[i] = 0 }
        var figure: [Int] = []
        for y in 400..<700 { for x in 15..<315 { figure.append(y * Self.w + x) } }
        for i in figure { g[i] = 10 }
        let image = try #require(BlackAndWhite.image(g, width: Self.w, height: Self.h))
        // Black and white: either kept as a picture (the page stays gray) or made black.
        let bw = BlackAndWhite.page(image, dpi: Self.dpi).map(BlackAndWhite.grayPixels) ?? g
        #expect(Double(figure.filter { bw[$0] < 128 }.count) > 0.95 * Double(figure.count))
        let on = BlackAndWhite.page(image, dpi: Self.dpi, removeShadows: true).map(BlackAndWhite.grayPixels) ?? g
        #expect(Double(figure.filter { on[$0] < 128 }.count) > 0.95 * Double(figure.count))
        let gray = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(figure.filter { gray[$0] < 128 }.count) > 0.95 * Double(figure.count))
    }

    @Test("Black and white of a straightened low-resolution scan is made twice as fine")
    func turnedLowResolution() throws {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let scan = Fixtures.image(1275, 1650, gray: true) { c in      // 150 DPI
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for i in 0..<30 { c.fill(CGRect(x: 300, y: 165 + i * 41, width: 800, height: 12)) }
        }
        let url = Fixtures.writePDF("bw-turned.pdf", media: letter, pages: [{ $0.draw(scan, in: letter) }])
        let doc = try #require(PDFDocument(url: url))
        var settings = PDFExporter.Settings()
        settings.ocr = false
        settings.enhanceMode = .blackAndWhite
        func width(_ page: BookPage, _ name: String) throws -> Int {
            let out = Fixtures.url(name)
            _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: settings)
            let made = try #require(PDFDocument(url: out)?.page(at: 0))
            return try #require(PDFRenderer.drawnContent(made.pageRef!)?.images.first).pixelWidth
        }
        let level = try width(BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true), "bw-level.pdf")
        let turned = try width(BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, leftSkew: 0.8,
                                        analyzed: true), "bw-turned-out.pdf")
        #expect(turned == 2 * level, "\(level) \(turned)")
    }

    @Test("Scans not stored in layers: Color as before, Black and white 1 bit")
    func plainUnchanged() throws {
        #expect(PDFExporter.Settings().enhanceMode == .color && !PDFExporter.Settings().removeShadows)
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let scan = Fixtures.image(1275, 1650, gray: true) { c in
            c.setFillColor(CGColor(gray: 0.55, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 260, height: 1650))              // a gray shadow down the side
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for i in 0..<30 { c.fill(CGRect(x: 300, y: 165 + i * 41, width: 800, height: 12)) }
        }
        let url = Fixtures.writePDF("bw-plain.pdf", media: letter, pages: [{ $0.draw(scan, in: letter) }])
        let doc = try #require(PDFDocument(url: url))
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        var settings = PDFExporter.Settings()
        settings.ocr = false
        let a = Fixtures.url("bw-plain-a.pdf"), b = Fixtures.url("bw-plain-b.pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: a, settings: settings)
        // As before: the page drawn again is the color export's crop.
        let made = try #require(PDFDocument(url: a)?.page(at: 0))
        let again = try #require(PDFRenderer.renderCGImage(page: made, dpi: 150))
        let src = try #require(PDFRenderer.renderCGImage(page: doc.page(at: 0)!, dpi: 150))
        let truth = try #require(PDFExporter.outputImages(of: page, rendered: src, settings: settings)?.first)
        #expect(Fixtures.difference(again, truth) < 1, "\(Fixtures.difference(again, truth))")
        // Black and white: 1 bit, the shadow white, the bars kept.
        settings.enhanceMode = .blackAndWhite
        _ = try PDFExporter.export(pages: [page], from: doc, to: b, settings: settings)
        let bw = try #require(PDFDocument(url: b)?.page(at: 0))
        let drawn = try #require(PDFRenderer.drawnContent(bw.pageRef!)?.images.first)
        var bpc: CGPDFInteger = 0
        #expect(CGPDFDictionaryGetInteger(CGPDFStreamGetDictionary(drawn.stream)!, "BitsPerComponent", &bpc) && bpc == 1)
        let px = HillClimb.gray(try #require(PDFRenderer.renderCGImage(page: bw, dpi: 150)))
        let w = 1275
        #expect(px.count == w * 1650)
        // The shadow (and its edge) white, the bars black.
        #expect((0..<1650).allSatisfy { y in (0..<270).allSatisfy { px[y * w + $0] == 255 } })
        let dark = px.filter { $0 == 0 }.count
        #expect(abs(dark - 30 * 800 * 12) < 30 * 800 * 12 / 20, "\(dark) black pixels")
    }
}
