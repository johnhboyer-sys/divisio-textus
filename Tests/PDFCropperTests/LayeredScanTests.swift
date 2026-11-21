import Testing
import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import PDFCropper

/// PDFs stored in layers, as some scanners make them: a 300 DPI 1-bit text layer
/// (an image mask painted near-black) over small low-resolution JPEG patches.
/// Written by hand, so the file holds exactly that and nothing Quartz adds.
enum LayeredFixture {
    /// Page size in points (5 × 3 inches) and the text layer's pixel grid.
    static let size = CGSize(width: 360, height: 216)
    static let maskWidth = 1500, maskHeight = 900

    /// The text layer: 1 = paper, 0 = ink (a mask's samples), rows top first.
    /// Lines of "words" made of strokes 3 px wide, so letters are fine detail.
    static func textBits(skipping hole: CGRect? = nil) -> [UInt8] {
        let rowBytes = (maskWidth + 7) / 8
        var bits = [UInt8](repeating: 0xFF, count: rowBytes * maskHeight)
        func ink(_ x: Int, _ y: Int) { bits[y * rowBytes + x / 8] &= ~UInt8(0x80 >> (x % 8)) }
        var rng = HCRandom(7)
        for line in 0..<14 {
            let top = 90 + line * 52
            var x = 150
            while x < maskWidth - 200 {
                let word = rng.int(60, 180)
                for s in stride(from: x, to: x + word, by: 12) {
                    let tall = rng.chance(0.3) ? 34 : 24
                    for y in (top + 34 - tall)..<(top + 34) {
                        for dx in 0..<3 where hole.map({ !$0.contains(CGPoint(x: s + dx, y: y)) }) ?? true {
                            ink(s + dx, y)
                        }
                    }
                    for dx in 0..<9 where hole.map({ !$0.contains(CGPoint(x: s + dx, y: top + 33)) }) ?? true {
                        ink(s + dx, top + 33)
                    }
                }
                x += word + 30
            }
        }
        return bits
    }

    /// A JPEG of `w` × `h` pixels, each colored by `color(x, y)`.
    static func jpeg(_ w: Int, _ h: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Data {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let c = color(x, y)
            px[(y * w + x) * 4] = c.0; px[(y * w + x) * 4 + 1] = c.1; px[(y * w + x) * 4 + 2] = c.2
        } }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    struct Patch {
        var jpeg: Data
        var width: Int, height: Int
        var rect: CGRect      // where it lands, in points
    }

    /// Paper tint over the whole page at 75 DPI, and a darker shadow strip at the right edge.
    static func paper() -> [Patch] {
        let tint = jpeg(375, 225) { _, _ in (238, 232, 205) }
        let shadow = jpeg(30, 225) { x, _ in let v = UInt8(200 - x * 4); return (v, v - 6, v - 30) }
        return [Patch(jpeg: tint, width: 375, height: 225, rect: CGRect(x: 0, y: 0, width: 360, height: 216)),
                Patch(jpeg: shadow, width: 30, height: 225, rect: CGRect(x: 331.2, y: 0, width: 28.8, height: 216))]
    }

    /// Where the picture sits, in points, and in text-layer pixels (top-left origin).
    static let pictureRect = CGRect(x: 120, y: 60, width: 108, height: 90)
    static var pictureHole: CGRect {
        let s = 300.0 / 72
        return CGRect(x: pictureRect.minX * s, y: (size.height - pictureRect.maxY) * s,
                      width: pictureRect.width * s, height: pictureRect.height * s)
    }

    /// A photo-like patch at 150 DPI: shaded, with detail.
    static func picture() -> Patch {
        var rng = HCRandom(3)
        let w = 225, h = 188
        let data = jpeg(w, h) { x, y in
            let v = 40 + (x * 150 / w) + Int((sin(Double(y) / 7) * 30)) + rng.int(-25, 25)
            let g = UInt8(max(0, min(255, v)))
            return (g, UInt8(max(0, Int(g) - 20)), UInt8(max(0, Int(g) - 50)))
        }
        return Patch(jpeg: data, width: w, height: h, rect: pictureRect)
    }

    struct Page {
        var bits: [UInt8]
        var patches: [Patch]
        var maskTurn: Double = 0        // degrees the text layer is placed turned by
        var maskColor = "0.08 g"
        var extra = ""                  // more content, drawn last
    }

    /// Write the pages as a PDF by hand: objects, cross-reference table, trailer.
    static func write(_ name: String, _ pages: [Page]) -> URL {
        var objects: [Data] = []        // object n is objects[n - 1]
        func add(_ d: Data) -> Int { objects.append(d); return objects.count }
        func stream(_ dict: String, _ body: Data) -> Data {
            var d = Data("<< \(dict) /Length \(body.count) >>\nstream\n".utf8)
            d.append(body); d.append(Data("\nendstream".utf8))
            return d
        }
        let pagesID = 1
        objects.append(Data())          // the page tree, filled in at the end
        var kids: [Int] = []
        for page in pages {
            var xobjects = ""
            var content = ""
            for (k, p) in page.patches.enumerated() {
                let id = add(stream("/Type /XObject /Subtype /Image /Width \(p.width) /Height \(p.height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", p.jpeg))
                xobjects += "/P\(k) \(id) 0 R "
                content += "q \(p.rect.width) 0 0 \(p.rect.height) \(p.rect.minX) \(p.rect.minY) cm /P\(k) Do Q\n"
            }
            let mask = add(stream("/Type /XObject /Subtype /Image /Width \(maskWidth) /Height \(maskHeight) /ImageMask true /BitsPerComponent 1", Data(page.bits)))
            xobjects += "/T \(mask) 0 R"
            let r = page.maskTurn * .pi / 180
            let w = Double(size.width), h = Double(size.height)
            // Turned about the page's center.
            let t = CGAffineTransform(translationX: w / 2, y: h / 2).rotated(by: r).translatedBy(x: -w / 2, y: -h / 2)
            let m = CGAffineTransform(scaleX: w, y: h).concatenating(t)
            content += "q \(page.maskColor) \(m.a) \(m.b) \(m.c) \(m.d) \(m.tx) \(m.ty) cm /T Do Q\n" + page.extra
            let contents = add(stream("", Data(content.utf8)))
            kids.append(add(Data("<< /Type /Page /Parent \(pagesID) 0 R /MediaBox [0 0 \(w) \(h)] /Resources << /XObject << \(xobjects) >> >> /Contents \(contents) 0 R >>".utf8)))
        }
        objects[pagesID - 1] = Data("<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>".utf8)
        let catalog = add(Data("<< /Type /Catalog /Pages \(pagesID) 0 R >>".utf8))

        var file = Data("%PDF-1.4\n%\u{e2}\u{e3}\u{cf}\u{d3}\n".utf8)
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(file.count)
            file.append(Data("\(i + 1) 0 obj\n".utf8)); file.append(o); file.append(Data("\nendobj\n".utf8))
        }
        let xref = file.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root \(catalog) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        file.append(Data(table.utf8))
        let url = Fixtures.url(name)
        try! file.write(to: url)
        return url
    }
}

@Suite("Layered scans")
struct LayeredScanTests {

    private var noOCR: PDFExporter.Settings {
        var s = PDFExporter.Settings()
        s.ocr = false
        return s
    }

    private func single(_ index: Int = 0, skew: Double = 0) -> BookPage {
        BookPage(sourceIndex: index, classification: .single, leftCrop: .full, leftSkew: skew, analyzed: true)
    }

    /// The bits per component of each image an output page draws.
    private func imageDepths(_ url: URL, page: Int) -> [Int] {
        guard let doc = CGPDFDocument(url as CFURL), let p = doc.page(at: page + 1), let dict = p.dictionary else { return [] }
        var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res,
              CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return [] }
        var depths: [Int] = []
        CGPDFDictionaryApplyBlock(xo, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) {
                var bpc: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(d, "BitsPerComponent", &bpc)
                depths.append(bpc)
            }
            return true
        }, nil)
        return depths
    }

    /// Ink pixels of the text layer's bits, rows top first.
    private func ink(_ bits: [UInt8]) -> [Bool] {
        let w = LayeredFixture.maskWidth, rowBytes = (w + 7) / 8
        return (0..<(w * LayeredFixture.maskHeight)).map { i in
            bits[(i / w) * rowBytes + (i % w) / 8] & UInt8(0x80 >> (i % w % 8)) == 0
        }
    }

    @Test("A layered page is found; plain scans and other pages are not")
    func detection() throws {
        let bits = LayeredFixture.textBits()
        let sharp = LayeredFixture.Patch(jpeg: LayeredFixture.jpeg(1500, 900) { _, _ in (200, 200, 200) },
                                         width: 1500, height: 900, rect: CGRect(origin: .zero, size: LayeredFixture.size))
        let url = LayeredFixture.write("detect.pdf", [
            .init(bits: bits, patches: LayeredFixture.paper()),
            .init(bits: bits, patches: LayeredFixture.paper(), maskColor: "1 0 0 rg"),        // red text
            .init(bits: bits, patches: LayeredFixture.paper(), extra: "0 0 50 50 re f\n"),    // a drawn box
            .init(bits: bits, patches: [sharp]),                                              // a sharp color image
        ])
        let doc = try #require(PDFDocument(url: url))
        let layers = try #require(LayeredScan.layers(of: doc.page(at: 0)!))
        #expect(abs(layers.dpi - 300) < 0.5 && layers.patches.count == 2)
        for k in 1...3 { #expect(LayeredScan.layers(of: doc.page(at: k)!) == nil) }
        // A plain scan: one full-page image, no mask.
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let plain = Fixtures.writePDF("plain.pdf", media: letter, pages: [{ $0.draw(Fixtures.scan(1275, 1650), in: letter) }])
        #expect(LayeredScan.layers(of: PDFDocument(url: plain)!.page(at: 0)!) == nil)
        #expect(LayeredScan.layers(of: Fixtures.markedPage()) == nil)
    }

    @Test("A layered page exports its text layer alone, 1 bit, pixel for pixel")
    func textLayerExport() throws {
        let bits = LayeredFixture.textBits()
        let url = LayeredFixture.write("text.pdf", [.init(bits: bits, patches: LayeredFixture.paper())])
        let doc = try #require(PDFDocument(url: url))
        let out = Fixtures.url("text-out.pdf")
        _ = try PDFExporter.export(pages: [single()], from: doc, to: out, settings: noOCR)
        #expect(imageDepths(out, page: 0) == [1])
        let made = try #require(PDFDocument(url: out)?.page(at: 0))
        #expect(abs(made.bounds(for: .mediaBox).width - LayeredFixture.size.width) < 0.5)
        // Drawn again at 300 DPI it is the text layer: no tint, no blur.
        let again = HillClimb.gray(try #require(PDFRenderer.renderCGImage(page: made, dpi: 300)))
        let want = ink(bits)
        #expect(again.count == want.count)
        #expect(zip(again, want).filter { ($0.0 < 128) != $0.1 }.count == 0)
        #expect(Set(again).isSubset(of: [0, 255]))
    }

    @Test("Straightened, the text layer is turned once and keeps its letters")
    func straightenedTextLayer() throws {
        let bits = LayeredFixture.textBits()
        // Placed turned 1.5° on the page; straightening turns it back, so the export
        // should be the layer as it was stored.
        let url = LayeredFixture.write("turned.pdf", [.init(bits: bits, patches: LayeredFixture.paper(), maskTurn: 1.5)])
        let doc = try #require(PDFDocument(url: url))
        let out = Fixtures.url("turned-out.pdf")
        _ = try PDFExporter.export(pages: [single(skew: -1.5)], from: doc, to: out, settings: noOCR)
        #expect(imageDepths(out, page: 0) == [1])
        let made = try #require(PDFDocument(url: out)?.page(at: 0))
        let again = HillClimb.gray(try #require(PDFRenderer.renderCGImage(page: made, dpi: 300)))
        let want = ink(bits)
        let inkCount = want.filter { $0 }.count
        let differ = zip(again, want).filter { ($0.0 < 128) != $0.1 }.count
        #expect(Double(differ) < 0.02 * Double(inkCount), "\(differ) of \(inkCount) ink pixels differ")
    }

    @Test("A page whose color layer holds a picture keeps its color export")
    func pictureKeepsColor() throws {
        let bits = LayeredFixture.textBits(skipping: LayeredFixture.pictureHole)
        let url = LayeredFixture.write("picture.pdf", [
            .init(bits: bits, patches: LayeredFixture.paper() + [LayeredFixture.picture()]),
            .init(bits: bits, patches: LayeredFixture.paper()),
        ])
        let doc = try #require(PDFDocument(url: url))
        let pages = [single(0), single(1)]
        let out = Fixtures.url("picture-out.pdf")
        _ = try PDFExporter.export(pages: pages, from: doc, to: out, settings: noOCR)
        #expect(imageDepths(out, page: 0) == [8])
        #expect(imageDepths(out, page: 1) == [1])
        // The picture page is the color export, as before.
        let made = try #require(PDFDocument(url: out)?.page(at: 0))
        let again = HillClimb.rgbx(try #require(PDFRenderer.renderCGImage(page: made, dpi: 300)))
        let src = try #require(PDFRenderer.renderCGImage(page: doc.page(at: 0)!, dpi: 300))
        let truth = HillClimb.rgbx(try #require(PDFExporter.outputImages(of: pages[0], rendered: src, settings: noOCR)?.first))
        #expect(again.count == truth.count)
        let meanDiff = zip(again, truth).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / max(1, truth.count)
        #expect(meanDiff < 4)
    }

    @Test("Straightening by transform lands where the app's straightened render does")
    func straightenMatchesComposite() {
        let w = 400, h = 300
        let source = Fixtures.image(w, h, gray: true) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for i in 0..<12 { c.fill(CGRect(x: 20 + i * 30, y: 30, width: 8, height: 240)) }
        }
        for page in [BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, leftSkew: 2, analyzed: true),
                     BookPage(sourceIndex: 0, classification: .spread, splitX: 0.45, leftCrop: .full, rightCrop: .full,
                              leftSkew: -1.5, rightSkew: 2.5, analyzed: true)] {
            let want = HillClimb.gray(ImageTransform.deskewedComposite(source, splitX: page.splitX, leftDegrees: page.leftSkew,
                                                                      rightDegrees: page.rightSkew, isSpread: page.isSpread))
            let got = HillClimb.gray(Fixtures.image(w, h, gray: true) { c in
                c.interpolationQuality = .high
                LayeredScan.drawStraightened(page, width: w, height: h, in: c) {
                    $0.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            })
            let meanDiff = zip(want, got).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / (w * h)
            #expect(meanDiff < 2)
        }
    }

    @Test("Review 4: in Color without Remove shadows a layered page is its text layer alone, as before")
    func colorIsTextLayerAlone() throws {
        let bits = LayeredFixture.textBits()
        // Print only in the color layer: a dark rule across the top.
        let rule = LayeredFixture.Patch(jpeg: LayeredFixture.jpeg(200, 4) { _, _ in (40, 40, 40) }, width: 200, height: 4,
                                        rect: CGRect(x: 40, y: 200, width: 200, height: 2))
        let url = LayeredFixture.write("color-text.pdf", [.init(bits: bits, patches: LayeredFixture.paper() + [rule])])
        let doc = try #require(PDFDocument(url: url))
        let want = ink(bits)
        func drawn(_ settings: PDFExporter.Settings, _ name: String) throws -> [UInt8] {
            let out = Fixtures.url(name)
            _ = try PDFExporter.export(pages: [single()], from: doc, to: out, settings: settings)
            return HillClimb.gray(try #require(PDFRenderer.renderCGImage(page: PDFDocument(url: out)!.page(at: 0)!, dpi: 300)))
        }
        let color = try drawn(noOCR, "color-text-out.pdf")
        #expect(color.count == want.count)
        #expect(zip(color, want).filter { ($0.0 < 128) != $0.1 }.count == 0)
        // Black and white keeps the color layer's print too.
        var bw = noOCR
        bw.enhanceMode = .blackAndWhite
        let both = try drawn(bw, "color-text-bw.pdf")
        #expect(zip(both, want).filter { $0.0 < 128 && !$0.1 }.count > 500)
    }

    @Test("Review 6: with Remove shadows the Export view shows a layered picture page as the export makes it")
    @MainActor func picturePreviewRemovesShadows() async throws {
        let bits = LayeredFixture.textBits(skipping: LayeredFixture.pictureHole)
        let url = LayeredFixture.write("picture-preview.pdf", [
            .init(bits: bits, patches: LayeredFixture.paper() + [LayeredFixture.picture()])])
        let m = testModel()
        m.load(url: url); await waitUntilIdle(m)
        m.removeShadows = true
        let page = try #require(m.pages.first)
        let shown = try #require(m.outputPreview(for: page).first)
        // As the export makes it, at the view's 40 DPI.
        let doc = try #require(PDFDocument(url: url))
        var settings = PDFExporter.Settings(direction: m.direction, enhanceMode: m.enhanceMode)
        settings.removeShadows = true
        let small = try #require(PDFRenderer.renderCGImage(page: doc.page(at: 0)!, dpi: 40))
        let plain = try #require(PDFExporter.outputImages(of: page, rendered: small, settings: settings)?.first)
        let want = try #require(ShadowRemoval.page(plain, dpi: 40))
        #expect(HillClimb.rgbx(shown) == HillClimb.rgbx(want))
    }

    @Test("The Export view shows a layered page's text layer, gray at its small size")
    @MainActor func preview() async throws {
        let bits = LayeredFixture.textBits()
        let url = LayeredFixture.write("preview.pdf", [.init(bits: bits, patches: LayeredFixture.paper())])
        let m = testModel()
        m.load(url: url); await waitUntilIdle(m)
        let page = try #require(m.pages.first)
        let shown = m.outputPreview(for: page)
        #expect(shown.count == page.outputCrops(direction: m.direction).count)
        let image = try #require(shown.first)
        #expect(image.colorSpace?.model == .monochrome)
        // No tint: between the lines the paper is white (tinted, none of it would be).
        let white = HillClimb.gray(image).filter { $0 == 255 }.count
        #expect(white * 4 > image.width * image.height)
    }
}
