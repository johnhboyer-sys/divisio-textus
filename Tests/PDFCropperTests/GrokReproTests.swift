import Testing
import Foundation
import AppKit
import PDFKit
import CoreText
import CryptoKit
@testable import PDFCropper

/// Grok's static review of 5f3bec5 (Black and white export, and Remove shadows), each
/// finding tried on the smallest realistic page: 300 DPI, paper 235, print about 30,
/// CoreText type. A test that shows the loss is disabled ("confirmed; fix pending") and
/// passes once the loss is fixed; the others guard against it. Each prints a GROK line
/// with what it measured.
@Suite("Grok review repro")
struct GrokReproTests {
    static let w = 900, h = 1200, dpi = 300.0

    // MARK: Helpers

    /// Pixels of a box, clipped to a `pw`-wide, `ph`-tall page.
    static func box(_ x: Int, _ y: Int, _ bw: Int, _ bh: Int, _ pw: Int = w, _ ph: Int = h) -> [Int] {
        var px: [Int] = []
        for yy in y..<(y + bh) { for xx in x..<(x + bw) where xx >= 0 && xx < pw && yy >= 0 && yy < ph { px.append(yy * pw + xx) } }
        return px
    }

    /// Draw `text` with CoreText into `px` (a `pw` × `ph` ink map, 255 paper, 0 ink),
    /// its baseline `baseline` px from the top and starting at `x`. Returns its width in px.
    @discardableResult
    static func draw(_ text: String, font name: String = "TimesNewRomanPSMT", points: Double, dpi: Double = dpi,
                     x: Double, baseline: Double, into px: inout [UInt8], _ pw: Int = w, _ ph: Int = h) -> Double {
        let line = ctLine(text, font: name, points: points, dpi: dpi)
        px.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.textPosition = CGPoint(x: x, y: Double(ph) - baseline)
            CTLineDraw(line, ctx)
        }
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    static func ctLine(_ text: String, font name: String, points: Double, dpi: Double) -> CTLine {
        let font = CTFontCreateWithName(name as CFString, points * dpi / 72, nil)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    static func width(_ text: String, font: String = "TimesNewRomanPSMT", points: Double, dpi: Double = dpi) -> Double {
        CTLineGetTypographicBounds(ctLine(text, font: font, points: points, dpi: dpi), nil, nil, nil)
    }

    static let words = ("the motion of bodies is not known to us by the senses alone but by reason which judges what "
        + "the senses report and orders it under principles of nature so that physics may be called a science of "
        + "changeable being in so far as it is changeable and its causes").split(separator: " ").map(String.init)

    /// Body text: lines of `points` Times from `x0` to about `x1`, baselines from `top` every `lead` px.
    static func body(into px: inout [UInt8], x0: Double, x1: Double, top: Double, lead: Double, lines: Int,
                     points: Double = 10, dpi: Double = dpi, _ pw: Int = w, _ ph: Int = h, seed: Int = 0) {
        var k = seed
        for n in 0..<lines {
            var s = ""
            while true {
                let next = s.isEmpty ? words[k % words.count] : s + " " + words[k % words.count]
                if width(next, points: points, dpi: dpi) > x1 - x0 { break }
                s = next; k += 1
            }
            draw(s, points: points, dpi: dpi, x: x0, baseline: top + Double(n) * lead, into: &px, pw, ph)
        }
    }

    /// The page as printed on `paper`: each pixel the paper's gray times the ink's.
    static func printed(_ ink: [UInt8], on paper: [UInt8]) -> [UInt8] {
        zip(ink, paper).map { UInt8(Int($1) * (30 + Int($0) * 225 / 255) / 255) }
    }

    /// Indices where `ink` is at least half dark, within a rect.
    static func dark(_ ink: [UInt8], x0: Int = 0, x1: Int = w, y0: Int = 0, y1: Int = h, _ pw: Int = w) -> [Int] {
        var out: [Int] = []
        for y in y0..<y1 { for x in x0..<x1 where ink[y * pw + x] < 128 { out.append(y * pw + x) } }
        return out
    }

    static func share(_ out: [UInt8], _ px: [Int]) -> Double {
        Double(px.filter { out[$0] < 128 }.count) / Double(max(1, px.count))
    }

    static func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// A PDF of one page holding `image` at `dpi`.
    static func pdf(_ name: String, _ image: CGImage, dpi: Double) -> PDFDocument {
        let media = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
        let url = Fixtures.writePDF(name, media: media, pages: [{ $0.draw(image, in: media) }])
        return PDFDocument(url: url)!
    }

    // MARK: 1. Type in a plain scan's gutter shadow

    /// A black-and-white (1-bit) scan as Riezler's and Wallace's are: the gutter shadow,
    /// 235 to 60 over the inner inch, thresholded at 128 with scanner noise, so it is
    /// speckle growing solid toward the fold; the lines' inner ends run into it, and a
    /// footnote in 8 pt sits in it. `bitonal` false: the same page as a gray scan.
    static func gutterPage(bitonal: Bool) -> (gray: [UInt8], ink: [UInt8], shadow: [UInt8]) {
        var ink = [UInt8](repeating: 255, count: w * h)
        body(into: &ink, x0: 100, x1: 885, top: 120, lead: 50, lines: 18)
        body(into: &ink, x0: 100, x1: 885, top: 1060, lead: 34, lines: 3, points: 8, seed: 7)
        var shadow = [UInt8](repeating: 235, count: w * h)
        for y in 0..<h { for x in 600..<w { let t = Double(x - 600) / 300; shadow[y * w + x] = UInt8(235 - 175 * t * t) } }
        var rng = HCRandom(21)
        var g = printed(ink, on: shadow)
        for i in g.indices {
            // Box-Muller noise: sigma 25 for the scanner's sensor, thresholded for 1-bit.
            let n = (-2 * log(max(1e-9, rng.unit()))).squareRoot() * cos(2 * .pi * rng.unit())
            let v = Double(g[i]) + n * (bitonal ? 25 : 4)
            g[i] = bitonal ? (v < 128 ? 0 : 255) : UInt8(max(0, min(255, v)).rounded())
        }
        return (g, ink, shadow)
    }

    @Test("Grok 1: type in a 1-bit scan's gutter shadow stays where the scan shows it")
    func typeInBitonalGutter() throws {
        let p = Self.gutterPage(bitonal: true)
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let out = BlackAndWhite.page(image, dpi: Self.dpi).map(BlackAndWhite.grayPixels) ?? p.gray
        var report = ""
        var worst = 1.0
        for x0 in stride(from: 700, to: 900, by: 25) {
            // Type the scan shows black, in this band, where its speckle is under a fifth.
            let type = Self.dark(p.ink, x0: x0, x1: x0 + 25).filter { p.gray[$0] == 0 }
            let paperPx = (0..<Self.h).flatMap { y in (x0..<(x0 + 25)).map { y * Self.w + $0 } }.filter { p.ink[$0] > 200 }
            let speckle = Double(paperPx.filter { p.gray[$0] == 0 }.count) / Double(max(1, paperPx.count))
            let kept = Self.share(out, type)
            report += " x\(x0):speckle \(Self.r2(speckle)) kept \(Self.r2(kept));"
            if speckle < 0.2 { worst = min(worst, kept) }
        }
        print("GROK 1 bitonal gutter:\(report)")
        #expect(worst > 0.9, "type lost where the speckle is light: \(report)")
    }

    @Test("Grok 1: type in a gray scan's gutter shadow stays")
    func typeInGrayGutter() throws {
        let p = Self.gutterPage(bitonal: false)
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let out = BlackAndWhite.page(image, dpi: Self.dpi).map(BlackAndWhite.grayPixels) ?? p.gray
        var report = ""
        var worst = 1.0
        for x0 in stride(from: 700, to: 900, by: 25) {
            let type = Self.dark(p.ink, x0: x0, x1: x0 + 25)
            let kept = Self.share(out, type)
            report += " x\(x0):\(Self.r2(kept))"
            worst = min(worst, kept)
        }
        // Which step: the cells `bands` clears, found on all that might be ink (under 128 there).
        let cleared = BlackAndWhite.bands(p.gray.map { $0 < 128 }, Self.w, Self.h, dpi: Self.dpi)
        let deep = Self.dark(p.ink, x0: 825, x1: 885)
        report += " | type x825-885 in cleared band cells \(Self.r2(Double(deep.filter { cleared[$0] }.count) / Double(deep.count)))"
        print("GROK 1 gray gutter:\(report)")
        #expect(worst > 0.9, "\(report)")
    }

    // MARK: 2. A layered page's picture at the crop's edge

    /// A layered page (5 × 3 inch) with a photo patch at `rect` (points) and no text under it.
    static func layeredPicture(_ name: String, _ rect: CGRect) throws -> (PDFDocument, [UInt8]) {
        let s = 300.0 / 72
        let hole = CGRect(x: rect.minX * s, y: (LayeredFixture.size.height - rect.maxY) * s, width: rect.width * s,
                          height: rect.height * s)
        let bits = LayeredFixture.textBits(skipping: hole)
        var pic = LayeredFixture.picture()
        pic.rect = rect
        let url = LayeredFixture.write(name, [.init(bits: bits, patches: LayeredFixture.paper() + [pic])])
        return (try #require(PDFDocument(url: url)), bits)
    }

    /// Bits per component of the images an output page draws.
    static func depths(_ url: URL, page: Int) -> [Int] {
        guard let doc = CGPDFDocument(url as CFURL), let p = doc.page(at: page + 1), let dict = p.dictionary else { return [] }
        var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res,
              CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return [] }
        var out: [Int] = []
        CGPDFDictionaryApplyBlock(xo, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) {
                var bpc: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(d, "BitsPerComponent", &bpc)
                out.append(bpc)
            }
            return true
        }, nil)
        return out
    }

    /// Share of the picture's area (points, page coords) that the exported page draws darker than 200.
    static func pictureShown(_ url: URL, _ rect: CGRect) throws -> Double {
        let made = try #require(PDFDocument(url: url)?.page(at: 0))
        let img = try #require(PDFRenderer.renderCGImage(page: made, dpi: 72))
        let g = HillClimb.gray(img)
        var n = 0, d = 0
        for y in Int(LayeredFixture.size.height - rect.maxY + 3)..<Int(LayeredFixture.size.height - rect.minY - 3) {
            for x in Int(rect.minX + 3)..<Int(rect.maxX - 3) where x < img.width && y < img.height {
                n += 1; if g[y * img.width + x] < 200 { d += 1 }
            }
        }
        return Double(d) / Double(max(1, n))
    }

    @Test("Grok 2: in Black and white, a layered page's picture reaching the page's edge keeps its color export")
    func layeredPictureAtEdge() throws {
        let rect = CGRect(x: 0, y: 60, width: 108, height: 90)        // full bleed at the left
        let (doc, _) = try Self.layeredPicture("grok2-edge.pdf", rect)
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        var settings = PDFExporter.Settings(); settings.ocr = false; settings.enhanceMode = .blackAndWhite
        let out = Fixtures.url("grok2-edge-out.pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: settings)
        let shown = try Self.pictureShown(out, rect)
        print("GROK 2 edge: depths \(Self.depths(out, page: 0)) picture shown \(Self.r2(shown))")
        #expect(Self.depths(out, page: 0) == [8])
        #expect(shown > 0.8)
    }

    @Test("Grok 2: in Black and white, a layered page's picture joining the fold's shadow keeps its color export")
    func layeredPictureByFold() throws {
        let rect = CGRect(x: 225, y: 60, width: 108, height: 90)      // ends inside the shadow strip (331.2 on)
        let (doc, _) = try Self.layeredPicture("grok2-fold.pdf", rect)
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        var settings = PDFExporter.Settings(); settings.ocr = false; settings.enhanceMode = .blackAndWhite
        let out = Fixtures.url("grok2-fold-out.pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: settings)
        let shown = try Self.pictureShown(out, rect)
        print("GROK 2 fold: depths \(Self.depths(out, page: 0)) picture shown \(Self.r2(shown))")
        #expect(Self.depths(out, page: 0) == [8])
        #expect(shown > 0.8)
    }

    @Test("Grok 2: in Color and Grayscale with the options off, a picture at the edge or by the fold is judged as before (text layer)")
    func layeredPictureOffModes() throws {
        for (name, rect) in [("edge", CGRect(x: 0, y: 60, width: 108, height: 90)), ("fold", CGRect(x: 225, y: 60, width: 108, height: 90))] {
            let (doc, _) = try Self.layeredPicture("grok2-off-\(name).pdf", rect)
            let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
            for mode in [EnhanceMode.color, .grayscale] {
                var settings = PDFExporter.Settings(); settings.ocr = false; settings.enhanceMode = mode
                let out = Fixtures.url("grok2-off-\(name)-\(mode)-out.pdf")
                _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: settings)
                // As on claude/finish: the text layer alone, packed to 1 bit.
                #expect(Self.depths(out, page: 0) == [1], "\(name) \(mode)")
            }
        }
    }

    @Test("Grok 2 control: the same picture 0.5 inch inside keeps its color export")
    func layeredPictureInside() throws {
        let rect = CGRect(x: 120, y: 60, width: 108, height: 90)
        let (doc, _) = try Self.layeredPicture("grok2-in.pdf", rect)
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        var settings = PDFExporter.Settings(); settings.ocr = false
        let out = Fixtures.url("grok2-in-out.pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: settings)
        #expect(Self.depths(out, page: 0) == [8])
    }

    // MARK: 3. A plain page's plate at the crop's edge, in black and white

    /// A gray scan with text on the right and a photo-like plate (1.5 inch square) at `x`;
    /// with `fold`, a gutter shadow down the right side, 235 to 60 over the last inch.
    static func platePage(x px0: Int, fold: Bool = false) -> (gray: [UInt8], plate: [Int]) {
        var ink = [UInt8](repeating: 255, count: w * h)
        body(into: &ink, x0: 100, x1: 800, top: 100, lead: 50, lines: 4)
        body(into: &ink, x0: 100, x1: 800, top: 900, lead: 50, lines: 5, seed: 3)
        var paper = [UInt8](repeating: 235, count: w * h)
        if fold { for y in 0..<h { for x in 600..<w { let t = Double(x - 600) / 300; paper[y * w + x] = UInt8(235 - 175 * t * t) } } }
        var g = printed(ink, on: paper)
        var rng = HCRandom(3)
        var plate: [Int] = []
        for y in 300..<750 {
            for x in px0..<min(w, px0 + 450) {
                let v = 40 + (x - px0) * 150 / 450 + Int(sin(Double(y) / 7) * 30) + rng.int(-25, 25)
                let i = y * w + x
                g[i] = UInt8(max(0, min(255, v * Int(paper[i]) / 235)))
                plate.append(i)
            }
        }
        return (g, plate)
    }

    /// Black and white of the plate page: nil when kept as a picture (gray), else the share
    /// of the plate drawn black.
    static func plateBW(_ g: [UInt8]) throws -> (picture: Bool, black: Double, plate: [UInt8]) {
        let image = try #require(BlackAndWhite.image(g, width: w, height: h))
        guard let bw = BlackAndWhite.page(image, dpi: dpi) else { return (true, 1, g) }
        return (false, 0, BlackAndWhite.grayPixels(bw))
    }

    @Test("Grok 3: a plate meeting the crop's edge is kept as a picture in black and white")
    func plateAtEdge() throws {
        let p = Self.platePage(x: 0)
        let r = try Self.plateBW(p.gray)
        let black = r.picture ? 1 : Self.share(r.plate, p.plate)
        print("GROK 3 edge: picture \(r.picture), plate black \(Self.r2(black))")
        #expect(r.picture)
    }

    @Test("Grok 3: a plate joining the fold's shadow is kept as a picture in black and white")
    func plateByFold() throws {
        let p = Self.platePage(x: 440, fold: true)
        let r = try Self.plateBW(p.gray)
        let black = r.picture ? 1 : Self.share(r.plate, p.plate)
        print("GROK 3 fold: picture \(r.picture), plate black \(Self.r2(black))")
        #expect(r.picture)
    }

    @Test("Grok 3 control: the same plate with paper about it is kept as a picture")
    func plateInside() throws {
        let p = Self.platePage(x: 150)
        #expect(try Self.plateBW(p.gray).picture)
    }

    // MARK: 4. Narrow print touching the fold band

    @Test("Grok 1/4 review: print kept in a smooth shadow's band stays though it joins a rim that hugs the band")
    func keptPrintJoinedToRim() {
        // A band down the right (x 150 on, cleared) and a mark joined to it: its left 4
        // columns are print kept in the band (`keep`), its right 6 a rim hugging the band.
        let w = 200, h = 200
        var out = [UInt8](repeating: 255, count: w * h)
        var cleared = [Bool](repeating: false, count: w * h), keep = cleared
        for y in 0..<h { for x in 150..<w { cleared[y * w + x] = true } }
        var mark: [Int] = []
        for y in 50..<90 { for x in 140..<150 { out[y * w + x] = 0; mark.append(y * w + x); if x < 144 { keep[y * w + x] = true } } }
        BlackAndWhite.clearRims(&out, cleared, w, h, dpi: 300, keep: keep)
        let kept = mark.filter { out[$0] == 0 }.count
        print("GROK review keep+rim: \(kept) of \(mark.count) kept")
        #expect(kept == mark.count)
    }

    @Test("Grok 4: an i, l and full stop touching or near the fold band stay")
    func narrowMarksByBand() {
        var ink = [UInt8](repeating: 255, count: Self.w * Self.h)
        Self.body(into: &ink, x0: 100, x1: 780, top: 120, lead: 50, lines: 18)
        let band = 870
        // Lines ending at the band: "fill" and "will" touching it, "end." its stop 10 px off.
        var pieces: [(String, [Int])] = [], words: [(String, [Int])] = []
        for (k, (word, gap)) in [("of nature fill", -1.0), ("so that it will", -1.0), ("at the end.", 10.0)].enumerated() {
            var one = [UInt8](repeating: 255, count: Self.w * Self.h)
            let y = 1020.0 + Double(k) * 50
            Self.draw(word, points: 10, x: Double(band) - gap - Self.width(word, points: 10), baseline: y, into: &one)
            words.append((word, Self.dark(one, x0: 0, x1: band)))
            // The word's last mark: its pixels right of its last gap.
            let px = Self.dark(one, x0: band - 30, x1: band, y0: Int(y) - 40, y1: Int(y) + 5)
            let maxX = px.map { $0 % Self.w }.max() ?? 0
            var lastCol = maxX
            while lastCol > 0, px.contains(where: { $0 % Self.w == lastCol - 1 }) { lastCol -= 1 }
            pieces.append((word, px.filter { $0 % Self.w >= lastCol }))
            for i in one.indices where one[i] < ink[i] { ink[i] = one[i] }
        }
        var g = ink.map { $0 < 128 ? UInt8(0) : 255 }
        for y in 0..<Self.h { for x in band..<Self.w { g[y * Self.w + x] = 0 } }
        let out = BlackAndWhite.ink(gray: g, sharp: nil, tone: false, width: Self.w, height: Self.h, dpi: Self.dpi)
        let report = pieces.map { "\($0.0): \(Self.r2(Self.share(out, $0.1))) of \($0.1.count) px" }.joined(separator: ", ")
            + "; whole lines kept " + words.map { "\(Self.r2(Self.share(out, $0.1)))" }.joined(separator: ", ")
        print("GROK 4: last marks kept \(report); band left \(Self.r2(Self.share(out, Self.box(band + 5, 0, 25, Self.h))))")
        #expect(pieces.allSatisfy { Self.share(out, $0.1) > 0.9 }, "\(report)")
    }

    @Test("Grok 4b: a footnote rule running into the fold's dark band stays on clean paper")
    func ruleIntoBand() {
        var ink = [UInt8](repeating: 255, count: Self.w * Self.h)
        Self.body(into: &ink, x0: 100, x1: 860, top: 120, lead: 50, lines: 18)
        let rule = Self.box(100, 1040, 790, 2)                       // 0.5 pt, to the band
        for i in rule { ink[i] = 0 }
        var paper = [UInt8](repeating: 235, count: Self.w * Self.h)
        for y in 0..<Self.h { for x in 750..<Self.w { let t = Double(x - 750) / 150; paper[y * Self.w + x] = UInt8(235 - 195 * t * t) } }
        let g = Self.printed(ink, on: paper)
        let out = BlackAndWhite.ink(gray: g, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi)
        let clean = rule.filter { $0 % Self.w < 700 }
        print("GROK 4b: rule kept on clean paper \(Self.r2(Self.share(out, clean))), text \(Self.r2(Self.share(out, Self.dark(ink, x0: 100, x1: 700, y0: 0, y1: 1000))))")
        #expect(Self.share(out, clean) > 0.9)
    }

    // MARK: 5. A color-layer-only accent or dot

    /// "ı e ı" in the text layer; "î é ï" in the color layer: the dots and accents only there,
    /// `crisp` (as sharp as the text layer) or as a 75 DPI color layer gives them (smooth).
    static func accents(crisp: Bool, points: Double = 9) -> Double {
        let base = "ı e ı ı e", full = "î é ï i è"
        var sharpInk = [UInt8](repeating: 255, count: w * h), fullInk = sharpInk
        draw(base, points: points, x: 200, baseline: 500, into: &sharpInk)
        draw(full, points: points, x: 200, baseline: 500, into: &fullInk)
        // Down to 75 DPI and back up, smoothly, as a layered scan's color layer is drawn.
        func smooth(_ px: [UInt8]) -> [UInt8] {
            let small = Fixtures.image(w / 4, h / 4, gray: true) { c in
                c.interpolationQuality = .high
                c.draw(BlackAndWhite.image(px, width: w, height: h)!, in: CGRect(x: 0, y: 0, width: w / 4, height: h / 4))
            }
            return HillClimb.gray(Fixtures.image(w, h, gray: true) { c in
                c.interpolationQuality = .high
                c.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
            })
        }
        let color = crisp ? fullInk : smooth(fullInk)
        // The accents alone (the full line less the text layer's letters), drawn as the color layer is.
        let accentOnly = (0..<(w * h)).map { sharpInk[$0] < 200 ? UInt8(255) : fullInk[$0] }
        let accentColor = crisp ? accentOnly : smooth(accentOnly)
        var g = [UInt8](repeating: 235, count: w * h), sharp = [Bool](repeating: false, count: w * h)
        for i in g.indices {
            sharp[i] = sharpInk[i] < 128
            g[i] = sharp[i] ? 0 : UInt8(235 * (30 + Int(color[i]) * 225 / 255) / 255)
        }
        // The accents as the color layer shows them: its own dark, off the text layer.
        let accents = (0..<(w * h)).filter { accentColor[$0] < 128 && sharpInk[$0] > 200 }
        let out = BlackAndWhite.ink(gray: g, sharp: sharp, tone: true, width: w, height: h, dpi: dpi)
        print("GROK 5 \(crisp ? "crisp" : "smooth") \(points) pt: \(accents.count) accent px, mean gray \(accents.isEmpty ? 0 : accents.reduce(0) { $0 + Int(g[$1]) } / accents.count)")
        return share(out, accents)
    }

    @Test("Grok 5: dots and accents only in the color layer stay (as a 75 DPI color layer gives them)",
          .disabled("Grok 5, confirmed; fix pending"))
    func colorOnlyAccentsSmooth() {
        let kept = Self.accents(crisp: false)
        print("GROK 5 smooth: accents kept \(Self.r2(kept))")
        #expect(kept > 0.8)
    }

    @Test("Grok 5: dots and accents only in the color layer stay (crisp)")
    func colorOnlyAccentsCrisp() {
        let kept = Self.accents(crisp: true), small = Self.accents(crisp: true, points: 6)
        print("GROK 5 crisp: accents kept 9 pt \(Self.r2(kept)), 6 pt \(Self.r2(small))")
        #expect(kept > 0.8)
        #expect(small > 0.8)
    }

    // MARK: 6. A printed rule near the crop's side or top

    @Test("Grok 6: a printed upright rule 0.03 inch inside the crop's side stays",
          .disabled("Grok 6, confirmed; fix pending"))
    func ruleAtCropSide() throws {
        #expect(try Self.sideRule(at: 10) > 0.9)
    }

    @Test("Grok 6 control: the same rule 0.1 inch inside the crop's side stays")
    func ruleNearCropSide() throws {
        #expect(try Self.sideRule(at: 30) > 0.9)
    }

    static func sideRule(at x: Int) throws -> Double {
        var ink = [UInt8](repeating: 255, count: Self.w * Self.h)
        Self.body(into: &ink, x0: 60, x1: 820, top: 120, lead: 50, lines: 20)
        let rule = Self.box(x, 200, 3, 600)                     // a table's frame
        for i in rule { ink[i] = 0 }
        let g = Self.printed(ink, on: [UInt8](repeating: 235, count: Self.w * Self.h))
        let image = try #require(BlackAndWhite.image(g, width: Self.w, height: Self.h))
        let out = BlackAndWhite.grayPixels(try #require(BlackAndWhite.page(image, dpi: Self.dpi)))
        print("GROK 6 side: rule at x \(x) kept \(Self.r2(Self.share(out, rule)))")
        return Self.share(out, rule)
    }

    @Test("Grok 6: a running head's rule 0.1 inch from a shadowed top stays",
          .disabled("Grok 6, confirmed; fix pending"))
    func ruleAtShadowedTop() throws {
        #expect(try Self.topRule(shadow: true) > 0.9)
    }

    @Test("Grok 6 control: the same rule by a clean top stays")
    func ruleAtCleanTop() throws {
        #expect(try Self.topRule(shadow: false) > 0.9)
    }

    static func topRule(shadow: Bool) throws -> Double {
        var ink = [UInt8](repeating: 255, count: Self.w * Self.h)
        Self.body(into: &ink, x0: 100, x1: 800, top: 160, lead: 50, lines: 20)
        let rule = Self.box(100, 30, 700, 2)
        for i in rule { ink[i] = 0 }
        var paper = [UInt8](repeating: 235, count: Self.w * Self.h)
        for y in 0..<120 where shadow { for x in 0..<Self.w { let t = 1 - Double(y) / 120; paper[y * Self.w + x] = UInt8(235 - 110 * t * t) } }
        let g = Self.printed(ink, on: paper)
        let image = try #require(BlackAndWhite.image(g, width: Self.w, height: Self.h))
        let out = BlackAndWhite.grayPixels(try #require(BlackAndWhite.page(image, dpi: Self.dpi)))
        print("GROK 6 top: shadow \(shadow) rule kept \(Self.r2(Self.share(out, rule)))")
        return Self.share(out, rule)
    }

    // MARK: 7. The Export view's black and white against the export's

    @Test("Grok 7: the Export view shows no ink the export drops (1-bit gutter page)")
    func previewMatchesExport() throws {
        try Self.preview(bitonal: true)
    }

    @Test("Grok 7: the Export view shows no ink the export drops (gray gutter page)")
    func previewMatchesExportGray() throws {
        try Self.preview(bitonal: false)
    }

    static func preview(bitonal: Bool) throws {
        let p = Self.gutterPage(bitonal: bitonal)
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let doc = Self.pdf("grok7-\(bitonal).pdf", image, dpi: Self.dpi)
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        var settings = PDFExporter.Settings(); settings.enhanceMode = .blackAndWhite
        func made(_ dpi: Double, preview: Bool) throws -> [UInt8] {
            let r = try #require(PDFRenderer.renderCGImage(page: doc.page(at: 0)!, dpi: dpi))
            let o = try #require(PDFExporter.outputImages(of: page, rendered: r, settings: settings)?.first)
            return BlackAndWhite.grayPixels(PDFExporter.finished(o, dpi: dpi, settings: settings, preview: preview))
        }
        let small = try made(40, preview: true), big = try made(300, preview: false)
        // Each 40 DPI pixel against the 7.5 × 7.5 export pixels under it, over the type's
        // lines in the gutter (x 750 to 890): ink shown where the export has none.
        let sw = Int((Double(Self.w) * 40 / 300).rounded()), sh = Int((Double(Self.h) * 40 / 300).rounded())
        var shownOnly = 0, both = 0
        for y in 0..<sh {
            for x in Int(750 * 40 / 300.0)..<Int(890 * 40 / 300.0) where small[y * sw + x] < 192 {
                let bx = Int(Double(x) * 7.5), by = Int(Double(y) * 7.5)
                let any = Self.box(bx, by, 8, 8).contains { big[$0] < 128 }
                if any { both += 1 } else { shownOnly += 1 }
            }
        }
        print("GROK 7 bitonal \(bitonal): preview ink pixels by the fold with export ink under them \(both), without \(shownOnly)")
        #expect(shownOnly * 10 <= both, "\(shownOnly) of \(shownOnly + both)")
    }

    // MARK: 8. Fine black and white of a turned spread with a picture on one side

    @Test("Grok 8: a turned 200 DPI spread's text side is made twice as fine though the other side holds a picture")
    func turnedSpreadWithPicture() throws {
        let sw = 2400, sh = 1600                              // 12 × 8 inch at 200 DPI
        func scan(picture: Bool) -> CGImage {
            Fixtures.image(sw, sh, gray: true) { c in
                c.setFillColor(CGColor(gray: 0, alpha: 1))
                for i in 0..<30 { c.fill(CGRect(x: 1350, y: 150 + i * 42, width: 900, height: 10)) }
                if picture {
                    for y in stride(from: 400, to: 1200, by: 4) {
                        for x in stride(from: 200, to: 1000, by: 4) {
                            c.setFillColor(CGColor(gray: 0.2 + 0.5 * Double(x - 200) / 800 + 0.1 * sin(Double(y) / 9), alpha: 1))
                            c.fill(CGRect(x: x, y: y, width: 4, height: 4))
                        }
                    }
                } else {
                    for i in 0..<30 { c.fill(CGRect(x: 150, y: 150 + i * 42, width: 900, height: 10)) }
                }
            }
        }
        var settings = PDFExporter.Settings(); settings.ocr = false; settings.enhanceMode = .blackAndWhite
        let page = BookPage(sourceIndex: 0, classification: .spread, splitX: 0.5, leftCrop: CropRect(x: 0.02, y: 0.02, width: 0.46, height: 0.96),
                            rightCrop: CropRect(x: 0.52, y: 0.02, width: 0.46, height: 0.96), rightSkew: 0.8, analyzed: true)
        func rightWidth(_ picture: Bool) throws -> (Int, [Int]) {
            let doc = Self.pdf("grok8-\(picture).pdf", scan(picture: picture), dpi: 200)
            let out = Fixtures.url("grok8-\(picture)-out.pdf")
            _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: settings)
            let made = try #require(PDFDocument(url: out)?.page(at: 1))
            return (try #require(PDFRenderer.drawnContent(made.pageRef!)?.images.first).pixelWidth,
                    Self.depths(out, page: 0) + Self.depths(out, page: 1))
        }
        let plain = try rightWidth(false), withPicture = try rightWidth(true)
        print("GROK 8: text side width \(plain.0) (no picture), \(withPicture.0) (picture opposite); depths \(plain.1) \(withPicture.1)")
        #expect(withPicture.0 == plain.0)
    }

    // MARK: S1. Remove shadows in Color: print in the shadow brightened past the paper

    /// A gray page with a gutter shadow (235 to 80 over the last inch) and, in the shadow and
    /// on clean paper alike, black type, gray type (ink at half) and a gray rule; with `band`, a
    /// solid black fold band down the last 0.07 inch too.
    static func shadowPrint(band: Bool) -> (gray: [UInt8], black: [Int], grayType: [Int], rule: [Int], edges: [Int]) {
        var ink = [UInt8](repeating: 255, count: w * h), half = ink
        body(into: &ink, x0: 100, x1: 860, top: 120, lead: 50, lines: 12)
        body(into: &half, x0: 100, x1: 860, top: 740, lead: 50, lines: 6, seed: 5)
        var full = ink
        for i in half.indices where half[i] < 255 { full[i] = UInt8(min(Int(full[i]), 128 + Int(half[i]) / 2)) }
        let rule = box(100, 1080, 720, 3)          // to x 820, short of the darkest shadow
        for i in rule { full[i] = 140 }
        var paper = [UInt8](repeating: 235, count: w * h)
        for y in 0..<h { for x in 600..<w { let t = Double(x - 600) / 300; paper[y * w + x] = UInt8(235 - 155 * t * t) } }
        var g = printed(full, on: paper)
        if band { for y in 0..<h { for x in 880..<w { g[y * w + x] = 15 } } }
        let black = dark(ink), grayType = (0..<(w * h)).filter { half[$0] < 64 }
        let edges = (0..<(w * h)).filter { ink[$0] >= 64 && ink[$0] < 200 }
        return (g, black, grayType, rule, edges)
    }

    @Test("Grok S1: in Color with Remove shadows, gray print and soft edges in the gutter shadow stay darker than the paper")
    func colorShadowPrint() throws {
        var report = ""
        var worst = 0.0
        for band in [false, true] {
            let p = Self.shadowPrint(band: band)
            let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
            let out = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
            let paperOut = Int(out[600 * Self.w + 50])
            let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi)
            let bwr = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi, removeShadows: true)
            report += " rule in bw \(Self.r2(Self.share(bw, p.rule))) bw+rs \(Self.r2(Self.share(bwr, p.rule))) gray \(p.gray[p.rule[5]]) out \(out[p.rule[5]]);"
            func lost(_ px: [Int], _ x0: Int, _ x1: Int) -> Double {
                let here = px.filter { $0 % Self.w >= x0 && $0 % Self.w < x1 && !(band && $0 % Self.w >= 870) }
                return Double(here.filter { Int(out[$0]) >= paperOut - 8 }.count) / Double(max(1, here.count))
            }
            func whiter(_ px: [Int], _ x0: Int, _ x1: Int) -> Int {
                px.filter { $0 % Self.w >= x0 && $0 % Self.w < x1 && Int(out[$0]) > paperOut + 5 }.count
            }
            report += " band \(band): paper \(paperOut);"
            for (name, px) in [("black", p.black), ("gray type", p.grayType), ("gray rule", p.rule), ("edges", p.edges)] {
                let clean = lost(px, 100, 500), shadow = lost(px, 700, 870)
                report += " \(name) lost clean \(Self.r2(clean)) shadow \(Self.r2(shadow)) whiter \(whiter(px, 700, 880));"
                if name != "edges" { worst = max(worst, shadow) }
            }
        }
        print("GROK S1:\(report)")
        #expect(worst < 0.1, "\(report)")
    }

    // MARK: S2-S4. Remove shadows: print beside the text block

    /// Body text from x 150 to 675 on clean paper, and `extra` ink; out: Black and white
    /// with Remove shadows, and Color with it.
    static func besideBlock(_ extra: (inout [UInt8]) -> Void, lead: Double = 50, lines: Int = 20)
        throws -> (ink: [UInt8], bw: [UInt8], color: [UInt8]) {
        var ink = [UInt8](repeating: 255, count: w * h)
        body(into: &ink, x0: 150, x1: 675, top: 100, lead: lead, lines: lines)
        extra(&ink)
        let g = printed(ink, on: [UInt8](repeating: 235, count: w * h))
        let bw = BlackAndWhite.ink(gray: g, sharp: nil, tone: BlackAndWhite.holdsTones(g, width: w, height: h),
                                   width: w, height: h, dpi: dpi, removeShadows: true)
        let image = try #require(BlackAndWhite.image(g, width: w, height: h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: dpi)))
        return (ink, bw, color)
    }

    @Test("Grok S2: a figure's axis, a marginal rule and a table's loose upright rules beside the block stay")
    func rulesBesideBlock() throws {
        let axis = Self.box(730, 300, 2, 220) + Self.box(730, 518, 130, 2)        // an L, past the right edge
        let marginal = Self.box(745, 700, 2, 160)                                   // a rule in the margin
        let table = Self.box(80, 300, 2, 260) + Self.box(120, 300, 2, 260)          // loose upright rules, left
        let r = try Self.besideBlock { ink in for i in axis + marginal + table { ink[i] = 0 } }
        let report = "axis bw \(Self.r2(Self.share(r.bw, axis))) color \(Self.r2(Self.share(r.color, axis))); "
            + "marginal bw \(Self.r2(Self.share(r.bw, marginal))) color \(Self.r2(Self.share(r.color, marginal))); "
            + "table bw \(Self.r2(Self.share(r.bw, table))) color \(Self.r2(Self.share(r.color, table)))"
        print("GROK S2: \(report)")
        #expect([axis, marginal, table].allSatisfy { Self.share(r.bw, $0) > 0.9 && Self.share(r.color, $0) > 0.9 }, "\(report)")
    }

    @Test("Grok S3: a marginal verse number with fold specks within an x-height stays")
    func marginalNumberWithSpecks() throws {
        for count in [3, 6] { try Self.numberWithSpecks(count) }
    }

    static func numberWithSpecks(_ count: Int) throws {
        var number: [Int] = []
        let r = try Self.besideBlock { ink in
            var one = [UInt8](repeating: 255, count: Self.w * Self.h)
            Self.draw("12", points: 8, x: 740, baseline: 450, into: &one)
            number = Self.dark(one)
            for i in number { ink[i] = min(ink[i], one[i]) }
            for (x, y) in [(744, 462), (756, 466), (768, 456), (735, 420), (775, 440), (750, 416)].prefix(count) {
                for i in Self.box(x, y, 3, 3) { ink[i] = 0 }
            }
        }
        print("GROK S3 \(count) specks: number kept bw \(Self.r2(Self.share(r.bw, number))) color \(Self.r2(Self.share(r.color, number)))")
        #expect(Self.share(r.bw, number) > 0.9)
        #expect(Self.share(r.color, number) > 0.9)
    }

    @Test("Grok S3: marginal line numbers set solid stay")
    func marginalNumbersSetSolid() throws {
        try Self.numbers(lead: 10 * Self.dpi / 72, every: 1)                     // 10 on 10, every line
    }

    @Test("Grok S3 control: marginal line numbers on every fifth line, 10 on 10, stay")
    func marginalNumbersEveryFifth() throws {
        try Self.numbers(lead: 10 * Self.dpi / 72, every: 5)
    }

    @Test("Grok S3: marginal line numbers on every line, 10 on 12, stay")
    func marginalNumbersLeaded() throws {
        try Self.numbers(lead: 12 * Self.dpi / 72, every: 1)
    }

    static func numbers(lead: Double, every: Int) throws {
        var numbers: [Int] = []
        let r = try Self.besideBlock({ ink in
            var one = [UInt8](repeating: 255, count: Self.w * Self.h)
            for n in 0..<24 where (n + 1) % every == 0 { Self.draw("\(n + 1)", points: 10, x: 720, baseline: 100 + Double(n) * lead, into: &one) }
            numbers = Self.dark(one)
            for i in numbers { ink[i] = min(ink[i], one[i]) }
        }, lead: lead, lines: 24)
        print("GROK S3 lead \(Self.r2(lead)) every \(every): numbers kept bw \(Self.r2(Self.share(r.bw, numbers))) color \(Self.r2(Self.share(r.color, numbers)))")
        #expect(Self.share(r.bw, numbers) > 0.9)
        #expect(Self.share(r.color, numbers) > 0.9)
    }

    @Test("Grok S4: a thumb-index letter touching the fore-edge stays",
          .disabled("Grok S4, confirmed; fix pending"))
    func thumbIndex() throws {
        var letter: [Int] = []
        let bold = "TimesNewRomanPS-BoldMT"
        let r = try Self.besideBlock { ink in
            var one = [UInt8](repeating: 255, count: Self.w * Self.h)
            Self.draw("M", font: bold, points: 14, x: 900 - Self.width("M", font: bold, points: 14) + 2, baseline: 500, into: &one)
            letter = Self.dark(one)
            for i in letter { ink[i] = 0 }
        }
        print("GROK S4: letter kept bw \(Self.r2(Self.share(r.bw, letter))) color \(Self.r2(Self.share(r.color, letter)))")
        #expect(Self.share(r.bw, letter) > 0.9)
    }

    // MARK: What the whole-book gate found

    @Test("Gate: a word in small capitals and dot leaders beside the block stay (Cherniss p3, Freudenthal p2)")
    func smallRowsBesideBlock() throws {
        var word: [Int] = [], dots: [Int] = []
        let r = try Self.besideBlock { ink in
            var one = [UInt8](repeating: 255, count: Self.w * Self.h)
            Self.draw("ROGER", points: 5, x: 700, baseline: 400, into: &one)
            word = Self.dark(one)
            var two = [UInt8](repeating: 255, count: Self.w * Self.h)
            for k in 0..<4 { for i in Self.box(700 + 22 * k, 600, 6, 6) { two[i] = 0 } }
            dots = Self.dark(two)
            for i in word + dots { ink[i] = min(ink[i], min(one[i], two[i])) }
        }
        print("GROK gate rows: word bw \(Self.r2(Self.share(r.bw, word))) color \(Self.r2(Self.share(r.color, word))); "
              + "dots bw \(Self.r2(Self.share(r.bw, dots))) color \(Self.r2(Self.share(r.color, dots)))")
        #expect(Self.share(r.bw, word) > 0.9 && Self.share(r.color, word) > 0.9)
        #expect(Self.share(r.bw, dots) > 0.9 && Self.share(r.color, dots) > 0.9)
    }

    @Test("Gate: a word in big capitals beside the block stays (Cherniss p3's COPYRIGHT, ROGER)")
    func bigCapitalsBesideBlock() throws {
        var ink = [UInt8](repeating: 255, count: Self.w * Self.h)
        Self.body(into: &ink, x0: 430, x1: 860, top: 100, lead: 50, lines: 20)
        var one = [UInt8](repeating: 255, count: Self.w * Self.h)
        Self.draw("ROGER", points: 22, x: 20, baseline: 500, into: &one)
        let word = Self.dark(one)
        for i in word { ink[i] = min(ink[i], one[i]) }
        let g = Self.printed(ink, on: [UInt8](repeating: 235, count: Self.w * Self.h))
        let bw = BlackAndWhite.ink(gray: g, sharp: nil, tone: BlackAndWhite.holdsTones(g, width: Self.w, height: Self.h),
                                   width: Self.w, height: Self.h, dpi: Self.dpi, removeShadows: true)
        print("GROK gate capitals: word bw \(Self.r2(Self.share(bw, word)))")
        #expect(Self.share(bw, word) > 0.9)
    }

    @Test("Gate: a word beside the block whose letters run together stays (Cherniss p3 at 150 DPI)")
    func joinedWordBesideBlock() throws {
        var ink = [UInt8](repeating: 255, count: Self.w * Self.h)
        Self.body(into: &ink, x0: 430, x1: 860, top: 100, lead: 50, lines: 20)
        var one = [UInt8](repeating: 255, count: Self.w * Self.h)
        Self.draw("ROGER", font: "TimesNewRomanPS-BoldMT", points: 12, x: 40, baseline: 500, into: &one)
        // Run the letters together, as a coarse scan does: each ink pixel spread 3 px to the right.
        var joined = one
        for y in 0..<Self.h { for x in 0..<(Self.w - 3) where one[y * Self.w + x] < 128 {
            for d in 1...3 { joined[y * Self.w + x + d] = 0 }
        } }
        let word = Self.dark(joined)
        for i in word { ink[i] = 0 }
        let g = Self.printed(ink, on: [UInt8](repeating: 235, count: Self.w * Self.h))
        let bw = BlackAndWhite.ink(gray: g, sharp: nil, tone: BlackAndWhite.holdsTones(g, width: Self.w, height: Self.h),
                                   width: Self.w, height: Self.h, dpi: Self.dpi, removeShadows: true)
        print("GROK gate joined word: bw \(Self.r2(Self.share(bw, word)))")
        #expect(Self.share(bw, word) > 0.9)
    }

    @Test("Gate: a big capital run into the next letter, starting a row of small capitals beside the block, stays")
    func capitalStartingRow() throws {
        var ink = [UInt8](repeating: 255, count: Self.w * Self.h)
        Self.body(into: &ink, x0: 430, x1: 860, top: 100, lead: 50, lines: 20)
        var cap = [UInt8](repeating: 255, count: Self.w * Self.h), rest = cap
        Self.draw("C", points: 20, x: 40, baseline: 500, into: &cap)
        let cw = Self.width("C", points: 20)
        Self.draw("O", points: 11, x: 40 + cw - 2, baseline: 500, into: &cap)
        Self.draw("PYRIGHT", points: 11, x: 40 + cw + Self.width("O", points: 11) + 2, baseline: 500, into: &rest)
        // C and O run together, as Cherniss's COPYRIGHT does.
        var joined = cap
        for y in 0..<Self.h { for x in 0..<(Self.w - 3) where cap[y * Self.w + x] < 128 { for d in 1...3 { joined[y * Self.w + x + d] = 0 } } }
        let word = Self.dark(joined) + Self.dark(rest)
        for i in Self.dark(joined) { ink[i] = 0 }
        for i in Self.dark(rest) { ink[i] = min(ink[i], rest[i]) }
        let g = Self.printed(ink, on: [UInt8](repeating: 235, count: Self.w * Self.h))
        let bw = BlackAndWhite.ink(gray: g, sharp: nil, tone: BlackAndWhite.holdsTones(g, width: Self.w, height: Self.h),
                                   width: Self.w, height: Self.h, dpi: Self.dpi, removeShadows: true)
        let co = Self.dark(joined)
        print("GROK gate capital: Co bw \(Self.r2(Self.share(bw, co))), whole word \(Self.r2(Self.share(bw, word)))")
        #expect(Self.share(bw, co) > 0.9 && Self.share(bw, word) > 0.9)
    }

    @Test("Gate: a dark cover with light lettering is left as it is (Freudenthal p1, p2)")
    func darkCover() throws {
        var g = [UInt8](repeating: 45, count: Self.w * Self.h)
        var ink = [UInt8](repeating: 255, count: Self.w * Self.h)
        Self.body(into: &ink, x0: 100, x1: 800, top: 150, lead: 50, lines: 18)
        for i in g.indices where ink[i] < 255 { g[i] = UInt8(45 + (255 - Int(ink[i])) * 180 / 255) }
        // And one with a light emblem over most of its middle: dark only all round.
        var e = g
        for y in 0..<Self.h { for x in 0..<Self.w where pow(Double(x - 450) / 420, 2) + pow(Double(y - 600) / 560, 2) < 1 {
            e[y * Self.w + x] = 225
        } }
        for (name, px) in [("dark", g), ("emblem", e)] {
            let image = try #require(BlackAndWhite.image(px, width: Self.w, height: Self.h))
            let out = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
            let changed = zip(out, px).filter { abs(Int($0) - Int($1)) > 2 }.count
            print("GROK gate cover \(name): \(changed) pixels changed")
            #expect(changed == 0, "\(name)")
        }
    }

    @Test("Gate: an index page claiming a quarter of its resolution keeps both columns (Cherniss p216)")
    func indexAtWrongScale() {
        // Drawn at 400 DPI, judged at the 100 the page claims: two columns of 8 point index
        // entries, dense with numbers, as Cherniss's index (a scan claiming 72 ppi) is.
        let real = 400.0, claimed = 100.0, pw = 2200, ph = 1600
        var px = [UInt8](repeating: 255, count: pw * ph)
        let names = ["Anaximenes", "Anaxagoras", "Empedocles", "Heraclitus", "Parmenides", "Democritus", "Leucippus",
                     "Xenophanes", "Diogenes", "Melissus", "Zeno", "Pythagoreans", "Alcmaeon", "Hippo", "Thales"]
        var rng = HCRandom(11)
        for column in 0..<2 {
            let x0 = column == 0 ? 200.0 : 1150.0
            for line in 0..<25 {
                var s = line % 3 == 0 ? names[(line / 3 + 5 * column) % names.count] + ": " : "   "
                for k in 0..<rng.int(3, 7) {
                    let n = rng.int(1, 240)
                    s += (k == 0 ? "" : rng.int(0, 2) == 0 ? "; " : ", ") + (rng.int(0, 3) == 0 ? "n. \(n)" : "\(n)")
                    if rng.int(0, 4) == 0 { s += "-\(n + rng.int(1, 4))" }
                }
                Self.draw(s, points: 8, dpi: real, x: x0, baseline: 200 + Double(line) * 55, into: &px, pw, ph)
            }
        }
        var out = px.map { $0 < 128 ? UInt8(0) : 255 }
        let before = out
        ShadowRemoval.clearSides(&out, pw, ph, dpi: claimed)
        let lost = zip(before, out).filter { $0 == 0 && $1 != 0 }.count
        print("GROK gate index at a quarter scale: \(lost) of \(before.filter { $0 == 0 }.count) ink pixels cleared")
        #expect(lost == 0)
    }

    // MARK: S5. Teeth on a page under 0.8 inch wide

    @Test("Grok S5: on a page 0.7 inch wide a comb's zone stays by the teeth",
          .disabled("Grok S5, confirmed; fix pending"))
    func teethOnNarrowPage() {
        let nw = 210
        var g = [UInt8](repeating: 235, count: nw * Self.h)
        for k in 0..<11 { for i in Self.box(0, 80 + k * 100, 40, 60, nw, Self.h) { g[i] = 45 } }
        let t = ShadowRemoval.teeth(g, nw, Self.h, dpi: Self.dpi, paper: 235)
        let rows = (100..<1100).filter { y in (0..<nw).allSatisfy { t.zone[y * nw + $0] } }.count
        print("GROK S5: teeth found \(t.found), rows zoned the page's full width \(rows) of 1000")
        #expect(rows < 500)
    }

    // MARK: S6. The speck merge's time on a tall column of specks

    @Test("Grok S6: clearSides on a 600 DPI page with a tall column of specks (time only)",
          .enabled(if: ProcessInfo.processInfo.environment["GROK_TIME"] != nil))
    func speckColumnTime() {
        let d = 600.0, pw = 3600, ph = 6600                                        // 6 × 11 inch
        var ink = [UInt8](repeating: 255, count: pw * ph)
        Self.body(into: &ink, x0: 600, x1: 3000, top: 400, lead: 100, lines: 58, dpi: d, pw, ph)
        let base = ink
        var n = 0
        for y in stride(from: 0, to: ph, by: 2) { for x in stride(from: 3300, to: 3314, by: 2) { ink[y * pw + x] = 0; n += 1 } }
        var a = base
        var t0 = HillClimb.now()
        ShadowRemoval.clearSides(&a, pw, ph, dpi: d)
        let plain = HillClimb.now() - t0
        var b = ink
        t0 = HillClimb.now()
        ShadowRemoval.clearSides(&b, pw, ph, dpi: d)
        let specked = HillClimb.now() - t0
        print("GROK S6: \(n) specks: clearSides \(Self.r2(specked)) s; without them \(Self.r2(plain)) s")
    }
}


/// The corpus side of the review: where on real books each finding could happen, and the
/// export of chosen pages in each mode to look at by eye. Runs only when GROK_CORPUS (the
/// folder for PNGs) and HILLCLIMB_DIR are set; never writes inside the books folder.
/// - survey: GROK_SURVEY=Book,Book (short names) prints GROKC lines: pictures a layered
///   page's test throws out for touching its window (2), plate-sized groups a plain page's
///   test throws out as running off (3), type-dark pixels `bands` clears (1), and marks
///   Remove shadows clears that look like print (S2, S3).
/// - show: GROK_SHOW=name:Book:page,... (page 1-based) draws each in Color and Black and
///   white, with and without Remove shadows: `<name>.png` (all output pages) and
///   `<name>-100pct.png` (the fold side at 100%, the scan first).
@Suite("Grok review corpus", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["GROK_CORPUS"] != nil
                    && ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct GrokReproCorpus {
    static let env = ProcessInfo.processInfo.environment
    static var out: URL { URL(fileURLWithPath: env["GROK_CORPUS"]!, isDirectory: true) }

    @Test("Survey", .enabled(if: ProcessInfo.processInfo.environment["GROK_SURVEY"] != nil))
    func survey() async throws {
        for name in Self.env["GROK_SURVEY"]!.split(separator: ",").map(String.init) {
            guard let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == name }) else { continue }
            let m = HillClimb.makeModel()
            await HillClimb.load(url, into: m)
            let doc = try #require(AppModel.reopen(url, password: nil))
            for page in m.pages {
                guard let pdfPage = doc.page(at: page.sourceIndex) else { continue }
                let crops = page.outputCrops(direction: m.direction)
                guard !crops.isEmpty else { continue }
                if let layers = LayeredScan.layers(of: pdfPage) {
                    for (k, g) in Self.layeredEdgePictures(page, pdfPage, layers, crops).enumerated() where !g.isEmpty {
                        print("GROKC 2 \(name) p\(page.sourceIndex + 1) crop \(k): pictures thrown out for touching the window \(g)")
                    }
                    continue
                }
                let dpi = min(200, PDFRenderer.scanDPI(of: pdfPage) ?? 200)
                guard let r = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi),
                      let images = PDFExporter.outputImages(of: page, rendered: r, settings: PDFExporter.Settings()) else { continue }
                for (k, image) in images.enumerated() {
                    let tag = "\(name) p\(page.sourceIndex + 1) crop \(k)"
                    let w = image.width, h = image.height
                    let gray = BlackAndWhite.grayPixels(image)
                    let paper = BlackAndWhite.background(gray, w, h, dpi: dpi)
                    let off = Self.runOffPictures(paper, gray, w, h, dpi: dpi)
                    if !off.isEmpty { print("GROKC 3 \(tag): plate-sized groups thrown out as running off \(off)") }
                    // 1: type-dark pixels (60 under the paper map) in cells `bands` clears.
                    let cleared = BlackAndWhite.bands(gray.map { $0 < 128 }, w, h, dpi: dpi)
                    var typeDark = 0
                    for i in 0..<(w * h) where cleared[i] && Int(gray[i]) < Int(paper[i]) - 60 { typeDark += 1 }
                    if typeDark > 200 { print("GROKC 1 \(tag): \(typeDark) type-dark pixels in cleared band cells") }
                    // S2, S3: marks Remove shadows clears that look like print.
                    let tone = BlackAndWhite.holdsTones(gray, width: w, height: h)
                    let before = BlackAndWhite.ink(gray: gray, sharp: nil, tone: tone, width: w, height: h, dpi: dpi, paper: paper)
                    let after = BlackAndWhite.ink(gray: gray, sharp: nil, tone: tone, width: w, height: h, dpi: dpi,
                                                  removeShadows: true, paper: paper)
                    let removed = (0..<(w * h)).map { before[$0] == 0 && after[$0] != 0 ? UInt8(0) : 255 }
                    let clean = BlackAndWhite.cleanLevel(paper)
                    let side = Int(0.05 * dpi)
                    var glyphs: [String] = [], rules: [String] = []
                    for b in ShadowRemoval.Components(removed, w, h).blobs {
                        guard b.minX > side, b.maxX < w - 1 - side else { continue }
                        let bh = Double(b.height) / dpi, bw = Double(b.width) / dpi
                        let mid: Int = ((b.minY + b.maxY) / 2) * w + (b.minX + b.maxX) / 2; let onClean = Int(paper[mid]) >= clean
                        if bh >= 0.05, bh <= 0.25, bw >= 0.3 * bh, Double(b.count) >= 0.15 * Double(b.width * b.height) {
                            glyphs.append("\(b.minX),\(b.minY) \(b.width)x\(b.height)\(onClean ? " clean" : "")")
                        }
                        if bh >= 0.3, bw <= 0.03, onClean { rules.append("\(b.minX),\(b.minY) \(b.width)x\(b.height)") }
                    }
                    if !glyphs.isEmpty { print("GROKC S3 \(tag) at \(Int(dpi)) dpi: glyph-sized marks Remove shadows clears \(glyphs.prefix(12))") }
                    if !rules.isEmpty { print("GROKC S2 \(tag) at \(Int(dpi)) dpi: upright rules on clean paper it clears \(rules.prefix(12))") }
                }
            }
            print("GROKC done \(name): \(m.pages.count) pages")
        }
    }

    /// `LayeredScan.pictureArea`'s groups that pass every test but touching the window.
    static func layeredEdgePictures(_ page: BookPage, _ pdfPage: PDFPage, _ layers: LayeredScan.Layers,
                                    _ crops: [CropRect]) -> [[String]] {
        let dpi = 50.0
        var decoded: [(PDFRenderer.DrawnImage, CGImage)] = []
        for patch in layers.patches {
            guard let image = LayeredScan.patchImage(patch) else { return crops.map { _ in ["undecodable patch"] } }
            decoded.append((patch, image))
        }
        guard !decoded.isEmpty,
              let color = LayeredScan.straightened(page, pdfPage, dpi: dpi, { ctx, scale in
                  LayeredScan.drawPatches(decoded, of: pdfPage, in: ctx, scale: scale) }),
              let text = LayeredScan.straightened(page, pdfPage, dpi: dpi, { ctx, scale in
                  LayeredScan.drawText(layers, of: pdfPage, in: ctx, scale: scale) }) else { return crops.map { _ in [] } }
        let w = color.width, h = color.height
        let paper = LayeredScan.maxFilter(color.pixels, w, h, radius: 10)
        let nearInk = LayeredScan.minFilter(text.pixels, w, h, radius: 2)
        let split = page.isSpread ? max(1, min(w - 1, Int(page.splitX * Double(w)))) : w
        return crops.map { crop in
            let px = crop.normalized().pixelRect(in: CGSize(width: w, height: h)).integral
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard !px.isNull, px.width >= 1, px.height >= 1 else { return [] }
            let c = (x: Int(px.minX), y: Int(px.minY), w: Int(px.width), h: Int(px.height))
            let leftHalf = c.x + c.w / 2 < split
            let lo = leftHalf ? 0 : split, hi = leftHalf ? split : w
            let x0 = max(lo, c.x - 15), x1 = min(hi, c.x + c.w + 15)
            let y0 = max(0, c.y - 15), y1 = min(h, c.y + c.h + 15)
            let ww = x1 - x0, wh = y1 - y0
            guard ww > 2, wh > 2 else { return [] }
            var mark = [Bool](repeating: false, count: ww * wh)
            for y in 0..<wh { for x in 0..<ww {
                let i = (y0 + y) * w + x0 + x
                mark[y * ww + x] = Int(paper[i]) - Int(color.pixels[i]) >= 51 && nearInk[i] > 230
            } }
            var found: [String] = []
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
                    let qx = x0 + x, qy = y0 + y
                    if qx >= c.x, qx < c.x + c.w, qy >= c.y, qy < c.y + c.h { inside += 1 }
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < ww, ny < wh, mark[ny * ww + nx] else { continue }
                        mark[ny * ww + nx] = false
                        stack.append(ny * ww + nx)
                    }
                }
                // Inside the crop by a picture's size (not only a strip along the edge).
                if atEdge, maxX - minX >= 19, maxY - minY >= 19, inside * 2 >= size, Double(inside) / 2500 > LayeredScan.pictureLimit {
                    found.append("\(maxX - minX + 1)x\(maxY - minY + 1) cells at \(x0 + minX),\(y0 + minY), \(HillClimb.r(Double(inside) / 2500, 2)) sq in inside")
                }
            }
            return found
        }
    }

    /// `BlackAndWhite.pictureCells`' groups of picture size that it throws out as running off.
    static func runOffPictures(_ paper: [UInt8], _ gray: [UInt8], _ w: Int, _ h: Int, dpi: Double) -> [String] {
        let step = max(1, Int((dpi / 50).rounded()))
        let sw = (w + step - 1) / step, sh = (h + step - 1) / step
        var small = [UInt8](repeating: 255, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw { small[y * sw + x] = paper[(y * step) * w + x * step] } }
        let usual = BlackAndWhite.cleanLevel(small) + 20
        var mark = small.map { Int($0) * 5 <= usual * 4 }
        let cellDPI = dpi / Double(step)
        let edge = max(1, Int((0.1 * cellDPI).rounded())), span = Int((0.4 * cellDPI).rounded())
        let inward = max(1, Int((0.1 * dpi).rounded()))
        func dark(_ x: Int, _ y: Int) -> Bool { Int(gray[y * w + x]) * 5 <= usual * 4 }
        func runsIn(_ lines: Range<Int>, _ at: (Int, Int) -> Bool) -> Bool {
            guard !lines.isEmpty else { return false }
            var joined = 0
            for l in lines where (0..<inward).allSatisfy({ at(l, $0) }) { joined += 1 }
            return joined * 10 >= lines.count * 3
        }
        var found: [String] = []
        var stack: [Int] = []
        for start in mark.indices where mark[start] {
            mark[start] = false
            stack = [start]
            var size = 0, minX = sw, maxX = 0, minY = sh, maxY = 0
            while let k = stack.popLast() {
                size += 1
                let x = k % sw, y = k / sw
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < sw, ny < sh, mark[ny * sw + nx] else { continue }
                    mark[ny * sw + nx] = false
                    stack.append(ny * sw + nx)
                }
            }
            let x0 = minX * step, x1 = min(w, (maxX + 1) * step), y0 = minY * step, y1 = min(h, (maxY + 1) * step)
            let runsOff = (minX < edge && inward < w && runsIn(y0..<y1) { y, d in dark(d, y) })
                || (maxX >= sw - edge && inward < w && runsIn(y0..<y1) { y, d in dark(w - 1 - d, y) })
                || (minY < edge && inward < h && runsIn(x0..<x1) { x, d in dark(x, d) })
                || (maxY >= sh - edge && inward < h && runsIn(x0..<x1) { x, d in dark(x, h - 1 - d) })
            let area = Double(size) / (cellDPI * cellDPI)
            // Plate-sized and not a thin strip down a side: over an inch each way.
            if runsOff, maxX - minX >= span, maxY - minY >= span, area > LayeredScan.pictureLimit,
               Double(maxX - minX + 1) >= cellDPI, Double(maxY - minY + 1) >= cellDPI {
                found.append("\(HillClimb.r(Double(x1 - x0) / dpi, 2))x\(HillClimb.r(Double(y1 - y0) / dpi, 2)) in at \(x0),\(y0), \(HillClimb.r(area, 2)) sq in")
            }
        }
        return found
    }

    /// GROK_SURVEY2=Book,Book: on plain scans, in Black and white without Remove shadows,
    /// what plain thresholding (60 under the paper map) calls ink and the export clears:
    /// upright lines 0.4 inch long within 0.05 inch of a left or right side (6), flat
    /// lines within 0.15 inch of the top or foot (6), and narrow letter-sized marks within
    /// 0.05 inch of what `bands` clears (4); and turned pages under 250 DPI with a picture
    /// on one side (8).
    @Test("Survey 2", .enabled(if: ProcessInfo.processInfo.environment["GROK_SURVEY2"] != nil))
    func survey2() async throws {
        for name in Self.env["GROK_SURVEY2"]!.split(separator: ",").map(String.init) {
            guard let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == name }) else { continue }
            let m = HillClimb.makeModel()
            await HillClimb.load(url, into: m)
            let doc = try #require(AppModel.reopen(url, password: nil))
            for page in m.pages {
                guard let pdfPage = doc.page(at: page.sourceIndex), LayeredScan.layers(of: pdfPage) == nil,
                      !page.outputCrops(direction: m.direction).isEmpty else { continue }
                let scan = PDFRenderer.scanDPI(of: pdfPage) ?? 300
                let dpi = min(200, scan)
                guard let r = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi),
                      let images = PDFExporter.outputImages(of: page, rendered: r, settings: PDFExporter.Settings()) else { continue }
                let turned = abs(page.leftSkew) >= 0.01 || (page.isSpread && abs(page.rightSkew) >= 0.01)
                var pictures: [Bool] = []
                for (k, image) in images.enumerated() {
                    let tag = "\(name) p\(page.sourceIndex + 1) crop \(k)"
                    let w = image.width, h = image.height
                    let gray = BlackAndWhite.grayPixels(image)
                    let paper = BlackAndWhite.background(gray, w, h, dpi: dpi)
                    pictures.append(BlackAndWhite.holdsPicture(paper, gray, w, h, dpi: dpi))
                    let tone = BlackAndWhite.holdsTones(gray, width: w, height: h)
                    let out = BlackAndWhite.ink(gray: gray, sharp: nil, tone: tone, width: w, height: h, dpi: dpi, paper: paper)
                    let raw = (0..<(w * h)).map { Int(gray[$0]) < min(128, Int(paper[$0]) - 60) || Int(gray[$0]) < Int(paper[$0]) - 60 ? UInt8(0) : 255 }
                    let cleared = BlackAndWhite.bands(gray.map { $0 < 128 }, w, h, dpi: dpi)
                    let nearBand = LayeredScan.minFilter(cleared.map { $0 ? 0 : 255 }, w, h, radius: Int(0.05 * dpi))
                    let rim = Int(0.05 * dpi), side = Int(0.15 * dpi), thin = max(2, Int(0.015 * dpi))
                    var lines: [String] = [], flats: [String] = [], narrow: [String] = []
                    let cc = ShadowRemoval.Components(raw, w, h)
                    for (j, b) in cc.blobs.enumerated() {
                        let gone = cc.count(j, where: { out[$0] != 0 })
                        guard gone * 10 >= b.count * 9 else { continue }
                        if b.height >= Int(0.4 * dpi), b.width <= 4 * thin, b.count <= thin * b.height,
                           b.minX < rim || b.maxX >= w - rim {
                            lines.append("\(b.minX),\(b.minY) \(b.width)x\(b.height)")
                        }
                        if b.width >= Int(0.4 * dpi), b.height <= 4 * thin, b.count <= thin * b.width,
                           b.minY < side || b.maxY >= h - side {
                            flats.append("\(b.minX),\(b.minY) \(b.width)x\(b.height)")
                        }
                        let bh = Double(b.height) / dpi, bw = Double(b.width) / dpi
                        if bh >= 0.02, bh <= 0.2, bw <= 0.03, cc.count(j, where: { nearBand[$0] == 0 }) > 0,
                           cc.count(j, where: { cleared[$0] }) == 0 {
                            let mid = ((b.minY + b.maxY) / 2) * w + (b.minX + b.maxX) / 2
                            if Int(paper[mid]) >= BlackAndWhite.cleanLevel(paper) - 40 { narrow.append("\(b.minX),\(b.minY) \(b.width)x\(b.height)") }
                        }
                    }
                    if !lines.isEmpty { print("GROKC 6 \(tag) at \(Int(dpi)) dpi: upright lines by a side cleared \(lines.prefix(8))") }
                    if !flats.isEmpty { print("GROKC 6top \(tag) at \(Int(dpi)) dpi: flat lines by the top or foot cleared \(flats.prefix(8))") }
                    if !narrow.isEmpty { print("GROKC 4 \(tag) at \(Int(dpi)) dpi: narrow marks by a band cleared \(narrow.count): \(narrow.prefix(8))") }
                }
                if scan < 250, turned, pictures.contains(true), pictures.contains(false) {
                    print("GROKC 8 \(name) p\(page.sourceIndex + 1): turned, \(Int(scan)) DPI, picture on one side \(pictures)")
                }
            }
            print("GROKC done2 \(name): \(m.pages.count) pages")
        }
    }

    @Test("Debug", .enabled(if: ProcessInfo.processInfo.environment["GROK_DEBUG"] != nil))
    func debugPage() async throws {
        let f = Self.env["GROK_DEBUG"]!.split(separator: ":").map(String.init)   // Book:page:k
        guard let (m, url, page) = await HillClimbShadowTests.loadCase(("debug", f[0], Int(f[1])!)) else { return }
        let doc = try #require(AppModel.reopen(url, password: nil))
        var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false, enhanceMode: .blackAndWhite)
        settings.matchScanResolution = m.matchScanResolution
        let pairs = HillClimbShadowTests.bwPairs(page, doc.page(at: page.sourceIndex)!, settings: settings)
        guard let p = pairs.first(where: { $0.mode == "bw" && $0.k == Int(f[2])! }) else { print("GROKD no pair"); return }
        let cc = ShadowRemoval.Components(p.off, p.w, p.h)
        let lines = ShadowRemoval.textLines(cc.blobs, dpi: p.dpi)
        print("GROKD w \(p.w) h \(p.h) dpi \(p.dpi) t \(lines?.t ?? -1) left \(lines?.left ?? -1) right \(lines?.right ?? -1) lines \(lines?.middles.count ?? -1)")
        for (k, b) in cc.blobs.enumerated() where b.count >= 8 {
            let gone = cc.count(k, where: { p.on[$0] != 0 })
            guard gone * 10 > b.count * 7 else { continue }
            print("GROKD lost \(b.minX),\(b.minY) \(b.width)x\(b.height) count \(b.count) member \(lines?.lineMembers.contains(k) ?? false) chained \(lines?.chained.contains(k) ?? false)")
        }
        // GROK_DEBUG_AT=x,y;x,y (with GROK_CORPUS): the scan, Black and white without and
        // with Remove shadows about each point, at 100%, in one sheet.
        guard let at = Self.env["GROK_DEBUG_AT"] else { return }
        var color = settings; color.enhanceMode = .color
        let src = try #require(doc.page(at: page.sourceIndex))
        let scan = PDFRenderer.renderCGImage(page: src, dpi: p.dpi).flatMap { PDFExporter.outputImages(of: page, rendered: $0, settings: color) }?[p.k]
        let gray = scan.map(BlackAndWhite.grayPixels)
        var rows: [[(String, CGImage)]] = []
        for pt in at.split(separator: ";") {
            let c = pt.split(separator: ",").compactMap { Int($0) }
            guard c.count == 2 else { continue }
            let pad = 150, x0 = max(0, c[0] - pad), y0 = max(0, c[1] - pad)
            let x1 = min(p.w - 1, c[0] + pad), y1 = min(p.h - 1, c[1] + pad)
            func cut(_ px: [UInt8]) -> CGImage? {
                var o = [UInt8](repeating: 255, count: (x1 - x0 + 1) * (y1 - y0 + 1))
                for y in y0...y1 { for x in x0...x1 { o[(y - y0) * (x1 - x0 + 1) + x - x0] = px[y * p.w + x] } }
                return BlackAndWhite.image(o, width: x1 - x0 + 1, height: y1 - y0 + 1)
            }
            var row: [(String, CGImage)] = []
            if let gray, gray.count == p.w * p.h, let g = cut(gray) { row.append(("scan \(c[0]),\(c[1])", g)) }
            if let a = cut(p.off) { row.append(("bw", a)) }
            if let b = cut(p.on) { row.append(("bw + Remove shadows", b)) }
            rows.append(row)
        }
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        if let im = BWShowTests.grid(rows, height: nil) {
            HillClimb.png(im, to: Self.out.appendingPathComponent("debug-\(f[0])-\(f[1])-\(f[2]).png"))
        }
    }

    @Test("Show", .enabled(if: ProcessInfo.processInfo.environment["GROK_SHOW"] != nil))
    func show() async throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        for item in Self.env["GROK_SHOW"]!.split(separator: ",") {
            let f = item.split(separator: ":").map(String.init)
            guard f.count == 3, let n = Int(f[2]) else { continue }
            guard let (m, url, page) = await HillClimbShadowTests.loadCase((f[0], f[1], n)) else { print("GROKC show \(f[0]): not loaded"); continue }
            var variants: [(label: String, pages: [CGImage])] = []
            for (mode, enhance) in [("Color", EnhanceMode.color), ("Black and white", EnhanceMode.blackAndWhite)] {
                for remove in [false, true] {
                    var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false, enhanceMode: enhance)
                    settings.matchScanResolution = m.matchScanResolution
                    settings.removeShadows = remove
                    let pages = try HillClimbShadowTests.exported(page, from: url, settings: settings,
                                                                  name: "grok-\(f[0])-\(variants.count).pdf")
                    variants.append(("\(mode)" + (remove ? ", Remove shadows" : ""), pages))
                }
            }
            let doc = try #require(AppModel.reopen(url, password: nil))
            let src = try #require(doc.page(at: page.sourceIndex))
            let first = variants[0].pages[0]
            let crop = page.outputCrops(direction: m.direction).first!
            let dpi = Double(first.width) / (crop.width * src.bounds(for: .cropBox).width / 72)
            var gray = PDFExporter.Settings(); gray.direction = m.direction
            gray.enhanceMode = EnhanceMode.grayscale
            let scans = PDFRenderer.renderCGImage(page: src, dpi: dpi)
                .flatMap { PDFExporter.outputImages(of: page, rendered: $0, settings: gray) } ?? []
            var rows: [[(String, CGImage)]] = [scans.enumerated().map { ("scan (gray) — page \($0.offset + 1)", $0.element) }]
            for v in variants { rows.append(v.pages.enumerated().map { ("\(v.label) — page \($0.offset + 1)", $0.element) }) }
            if let image = BWShowTests.grid(rows, height: 1400) {
                HillClimb.png(image, to: Self.out.appendingPathComponent("\(f[0]).png"))
            }
            var cropRows: [[(String, CGImage)]] = []
            let count = variants[0].pages.count
            for k in 0..<count {
                let before = variants[2].pages[k]
                let side = count == 2 ? (k == 0 ? 1 : -1) : BWShowTests.darkerSide(before)
                let r = BWShowTests.foldRect(before, side: side,
                                             dpi: dpi * Double(before.width) / Double(variants[0].pages[k].width))
                var row: [(String, CGImage)] = []
                if k < scans.count, let s = BWShowTests.cut(scans[k], r, from: before) { row.append(("scan (gray) — page \(k + 1)", s)) }
                for v in variants where k < v.pages.count {
                    if let s = BWShowTests.cut(v.pages[k], r, from: before) { row.append((v.label, s)) }
                }
                cropRows.append(row)
            }
            if let image = BWShowTests.grid(cropRows, height: nil) {
                HillClimb.png(image, to: Self.out.appendingPathComponent("\(f[0])-100pct.png"))
            }
            print("GROKC show \(f[0]) pages=\(count) dpi=\(HillClimb.r(dpi, 1)) layered=\(LayeredScan.layers(of: src) != nil)")
        }
    }
}

/// GROK_OFFHASH=Book,Book (with HILLCLIMB_DIR): each book Auto-detected and exported whole in
/// Color, Grayscale and Black and white without Remove shadows; prints a SHA-256 of every
/// page's image data per mode, to compare two builds (the options off must not change).
/// GROK_HASH_ON=1 adds the three modes with Remove shadows (`color-on`, `gray-on`, `bw-on`)
/// and prints each page's own hash too (`GROKPAGE`), to find the pages that changed.
/// GROK_PAGES=1 prints the pages' hashes without it; GROK_MODES=bw,... runs only those
/// labels. Each export's wall time is printed (`GROKTIME`). GROK_PNG=<folder> with
/// GROK_PNG_PAGES=Book:k,... (output page, 1-based) draws those pages of each mode there at
/// their own resolution, `<Book>-p<k>-<label>.png`.
@Suite("Grok off-mode hashes", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["GROK_OFFHASH"] != nil
                    && ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct GrokOffHashes {
    @Test("Hash the off modes")
    func hashes() async throws {
        for name in ProcessInfo.processInfo.environment["GROK_OFFHASH"]!.split(separator: ",").map(String.init) {
            guard let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == name }) else { continue }
            let m = HillClimb.makeModel()
            await HillClimb.load(url, into: m)
            let doc = try #require(AppModel.reopen(url, password: nil))
            let on = ProcessInfo.processInfo.environment["GROK_HASH_ON"] != nil
            let modes: [(String, EnhanceMode, Bool)] = [("color", .color, false), ("gray", .grayscale, false), ("bw", .blackAndWhite, false)]
                + (on ? [("color-on", .color, true), ("gray-on", .grayscale, true), ("bw-on", .blackAndWhite, true)] : [])
            let only = ProcessInfo.processInfo.environment["GROK_MODES"]?.split(separator: ",").map(String.init)
            let perPage = on || ProcessInfo.processInfo.environment["GROK_PAGES"] != nil
            for (label, mode, remove) in modes where only?.contains(label) ?? true {
                var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false, enhanceMode: mode)
                settings.matchScanResolution = m.matchScanResolution
                settings.removeShadows = remove
                let out = HillClimb.scratch.appendingPathComponent("offhash-\(name)-\(label).pdf")
                let t0 = HillClimb.now()
                _ = try PDFExporter.export(pages: m.pages, from: doc, to: out, settings: settings)
                print("GROKTIME \(name) \(label) \(HillClimb.r(HillClimb.now() - t0, 2)) s")
                let made = try #require(CGPDFDocument(out as CFURL))
                var hasher = SHA256()
                for k in 1...max(1, made.numberOfPages) {
                    guard let p = made.page(at: k), let dict = p.dictionary else { continue }
                    var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?
                    guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res,
                          CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { continue }
                    var datas: [Data] = []
                    CGPDFDictionaryApplyBlock(xo, { _, object, _ in
                        var stream: CGPDFStreamRef?
                        var format = CGPDFDataFormat.raw
                        if CGPDFObjectGetValue(object, .stream, &stream), let stream,
                           let data = CGPDFStreamCopyData(stream, &format) { datas.append(data as Data) }
                        return true
                    }, nil)
                    var page = SHA256()
                    for d in datas.sorted(by: { $0.count < $1.count }) { hasher.update(data: d); page.update(data: d) }
                    if let dir = ProcessInfo.processInfo.environment["GROK_PNG"],
                       (ProcessInfo.processInfo.environment["GROK_PNG_PAGES"] ?? "").split(separator: ",").contains(Substring("\(name):\(k)")),
                       let pdf = PDFDocument(url: out)?.page(at: k - 1), let ref = pdf.pageRef,
                       let px = PDFRenderer.drawnContent(ref)?.images.first?.pixelWidth,
                       let im = PDFRenderer.renderCGImage(page: pdf, dpi: Double(px) * 72 / pdf.bounds(for: .cropBox).width) {
                        HillClimb.png(im, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-p\(k)-\(label).png"))
                    }
                    if perPage { print("GROKPAGE \(name) \(label) \(k) \(page.finalize().map { String(format: "%02x", $0) }.joined().prefix(16))") }
                }
                try? FileManager.default.removeItem(at: out)
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                print("GROKHASH \(name) \(label) pages=\(made.numberOfPages) \(digest)")
            }
        }
    }
}
