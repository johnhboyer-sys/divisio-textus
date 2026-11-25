import Testing
import Foundation
import PDFKit
@testable import PDFCropper

@Suite("CCITT G4")
struct CCITTTests {

    /// A 1-bit gray image, 1 white, from a pixel rule (true: black).
    static func bits(_ w: Int, _ h: Int, black: (Int, Int) -> Bool) -> CGImage {
        let rowBytes = (w + 7) / 8
        var data = [UInt8](repeating: 0xFF, count: rowBytes * h)
        for y in 0..<h { for x in 0..<w where black(x, y) { data[y * rowBytes + x / 8] &= ~(0x80 >> UInt8(x % 8)) } }
        return CGImage(width: w, height: h, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Lines of letter-sized marks of uneven widths and heights.
    static func text(_ w: Int, _ h: Int) -> CGImage {
        var seed: UInt64 = 12345
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
        var boxes: [(Int, Int, Int, Int)] = []
        var y = 40
        while y + 40 < h {
            var x = 60
            while x + 40 < w - 60 {
                let bw = 8 + next(20), bh = 18 + next(14)
                boxes.append((x, y + 32 - bh, bw, bh))
                x += bw + 3 + next(6) + (next(6) == 0 ? 18 : 0)
            }
            y += 48
        }
        return bits(w, h) { x, y in
            boxes.contains { x >= $0.0 && x < $0.0 + $0.2 && y >= $0.1 && y < $0.1 + $0.3 }
        }
    }

    /// A one-page PDF drawing `image` at 300 ppi.
    static func pdf(_ image: CGImage, _ name: String) -> URL {
        let media = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / 300, height: Double(image.height) * 72 / 300)
        return Fixtures.writePDF(name, media: media, pages: [{ $0.draw(image, in: media) }])
    }

    /// The first image's /Filter name on page 1.
    static func filter(_ url: URL) -> String? {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1)?.dictionary else { return nil }
        var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(page, "Resources", &res), let res,
              CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return nil }
        var found: String?
        CGPDFDictionaryApplyBlock(xo, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard found == nil, CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return true }
            var name: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(dict, "Filter", &name), let name { found = String(cString: name) }
            return true
        }, nil)
        return found
    }

    static func rendered(_ url: URL) -> [UInt8]? {
        guard let page = PDFDocument(url: url)?.page(at: 0),
              let image = PDFRenderer.renderCGImage(page: page, dpi: 300) else { return nil }
        return HillClimb.rgbx(image)
    }

    /// Recode a copy; the copy draws the same pixels. Returns whether it changed.
    @discardableResult
    func roundTrip(_ image: CGImage, _ name: String) throws -> Bool {
        let src = Self.pdf(image, name + ".pdf")
        let copy = Fixtures.url(name + "-g4.pdf")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: src, to: copy)
        let before = try Data(contentsOf: copy)
        let changed = PDFCCITT.recompress(at: copy)
        if changed {
            #expect(Self.filter(copy) == "CCITTFaxDecode", "\(name)")
            #expect(try Data(contentsOf: copy).count < before.count, "\(name)")
        } else {
            #expect(try Data(contentsOf: copy) == before, "\(name) changed though it says not")
        }
        let a = try #require(Self.rendered(src)), b = try #require(Self.rendered(copy))
        #expect(a == b, "\(name): pixels differ")
        return changed
    }

    @Test("Pages recoded as Group 4 draw every pixel the same")
    func patterns() throws {
        // Even rows of marks repeat, and Flate may win there: recoded or not, the same pixels.
        try roundTrip(Self.text(2400, 900), "text")
        try roundTrip(Self.text(1001, 700), "odd-width")
        try roundTrip(Self.bits(1, 400) { _, y in y % 3 == 0 }, "one-column")
        #expect(try roundTrip(Self.bits(900, 600) { _, _ in false }, "white"))
        #expect(try roundTrip(Self.bits(900, 600) { _, _ in true }, "black"))
        // Runs over 2560: whole rows white, black, and long runs either side.
        #expect(try roundTrip(Self.bits(6000, 300) { x, y in
            switch y % 6 { case 0: return false; case 1: return true; case 2: return x >= 3000
                           case 3: return x < 2700; case 4: return x == 2561 || x == 5999; default: return x % 2900 < 3 }
        }, "long-runs"))
        try roundTrip(Self.bits(800, 800) { x, y in (x + y) % 2 == 0 }, "checkerboard")
        #expect(try roundTrip(Self.bits(1200, 1200) { x, y in
            (x == 0 || x == 1199 || x == 1 || x == 1198) && y % 37 == 0 || (y == 0 || y == 1199) && x % 41 == 0
        }, "edge-specks"))
    }

    @Test("Noise: recoded only if smaller, and the same either way")
    func noise() throws {
        var g = SystemRandomNumberGenerator()
        let black = (0..<(1500 * 1500)).map { _ in Int.random(in: 0..<20, using: &g) == 0 }
        try roundTrip(Self.bits(1500, 1500) { x, y in black[y * 1500 + x] }, "noise")
    }

    @Test("A PDF of an 8-bit gray image is left as it was")
    func grayUntouched() throws {
        let gray = Fixtures.image(600, 400, gray: true) { c in
            c.setFillColor(CGColor(gray: 0.4, alpha: 1)); c.fill(CGRect(x: 50, y: 50, width: 300, height: 200))
        }
        let url = Self.pdf(gray, "gray8.pdf")
        let before = try Data(contentsOf: url)
        #expect(!PDFCCITT.recompress(at: url))
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("A file cut short or not a PDF is left as it was")
    func badFiles() throws {
        let full = try Data(contentsOf: Self.pdf(Self.bits(900, 600) { x, y in (x / 5 + y / 5) % 3 == 0 }, "cut-src.pdf"))
        for (name, data) in [("cut.pdf", full.prefix(full.count / 2)), ("junk.pdf", Data("not a pdf at all".utf8)),
                             ("tail.pdf", full.prefix(full.count - 30))] {
            let url = Fixtures.url(name)
            try Data(data).write(to: url)
            #expect(!PDFCCITT.recompress(at: url), "\(name)")
            #expect(try Data(contentsOf: url) == Data(data), "\(name)")
        }
    }

    /// A one-page PDF written by hand: `image` is the image dictionary's extra keys, `content`
    /// the page's drawing, the image 40 x 40, 1 bit, all black.
    static func handPDF(_ name: String, image: String, content: String, resources extra: String = "") -> URL {
        let data = Data(repeating: 0, count: 5 * 40)
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func obj(_ body: Data) { offsets.append(out.count); out.append(body) }
        obj(Data("1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n".utf8))
        obj(Data("2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n".utf8))
        obj(Data("3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << /XObject << /Im1 5 0 R >> \(extra) >> >> endobj\n".utf8))
        obj(Data("4 0 obj << /Length \(content.utf8.count) >> stream\n\(content)\nendstream endobj\n".utf8))
        var im = Data("5 0 obj << /Type /XObject /Subtype /Image /Width 40 /Height 40 /BitsPerComponent 1 \(image) /Length \(data.count) >> stream\n".utf8)
        im.append(data); im.append(Data("\nendstream endobj\n".utf8))
        obj(im)
        let xref = out.count
        var table = "xref\n0 6\n0000000000 65535 f \n"
        for o in offsets { table += String(repeating: "0", count: 10 - String(o).count) + String(o) + " 00000 n \n" }
        out.append(Data((table + "trailer << /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n").utf8))
        let url = Fixtures.url(name)
        try? out.write(to: url)
        return url
    }

    static func bitonal(_ url: URL) -> Bool? { PDFDocument(url: url)?.page(at: 0).map(PDFRenderer.isBitonalScan) }

    @Test("A 1-bit gray image counts as black and white only if it draws pure black and white (Codex review)")
    func bitonalScanNeedsPureInk() {
        let draw = "q 200 0 0 200 0 0 cm /Im1 Do Q"
        #expect(Self.bitonal(Self.handPDF("plain1.pdf", image: "/ColorSpace /DeviceGray", content: draw)) == true)
        #expect(Self.bitonal(Self.handPDF("inverted1.pdf", image: "/ColorSpace /DeviceGray /Decode [1 0]", content: draw)) == true)
        // Black drawn as light gray.
        #expect(Self.bitonal(Self.handPDF("pale1.pdf", image: "/ColorSpace /DeviceGray /Decode [0.8 1]", content: draw)) == false)
        // A stencil in dark red, or under a graphics state that may make it see-through.
        #expect(Self.bitonal(Self.handPDF("red-stencil.pdf", image: "/ImageMask true", content: "0.3 0 0 rg " + draw)) == false)
        #expect(Self.bitonal(Self.handPDF("black-stencil.pdf", image: "/ImageMask true", content: "0 g " + draw)) == true)
        #expect(Self.bitonal(Self.handPDF("faded1.pdf", image: "/ColorSpace /DeviceGray",
                                          content: "/GS1 gs " + draw, resources: "/ExtGState << /GS1 << /ca 0.3 /CA 0.3 >> >>")) == false)
    }

    @Test("A page with forms nested too deep to read is not taken for black and white (Codex review)")
    func bitonalScanNeedsAllFormsRead() {
        // The page draws a 1-bit image and a form that draws itself: past the depth read,
        // it could paint anything.
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << /XObject << /Im1 5 0 R /F1 6 0 R >> >> >>",
        ]
        let page = "q 200 0 0 200 0 0 cm /Im1 Do Q /F1 Do", form = "/F1 Do"
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() { offsets.append(out.count); out.append(Data("\(i + 1) 0 obj \(body) endobj\n".utf8)) }
        offsets.append(out.count)
        out.append(Data("4 0 obj << /Length \(page.utf8.count) >> stream\n\(page)\nendstream endobj\n".utf8))
        offsets.append(out.count)
        out.append(Data("5 0 obj << /Type /XObject /Subtype /Image /Width 40 /Height 40 /BitsPerComponent 1 /ColorSpace /DeviceGray /Length 200 >> stream\n".utf8))
        out.append(Data(repeating: 0, count: 200)); out.append(Data("\nendstream endobj\n".utf8))
        offsets.append(out.count)
        out.append(Data("6 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources << /XObject << /F1 6 0 R >> >> /Length \(form.utf8.count) >> stream\n\(form)\nendstream endobj\n".utf8))
        let xref = out.count
        var table = "xref\n0 7\n0000000000 65535 f \n"
        for o in offsets { table += String(repeating: "0", count: 10 - String(o).count) + String(o) + " 00000 n \n" }
        out.append(Data((table + "trailer << /Size 7 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n").utf8))
        let url = Fixtures.url("deep-forms.pdf")
        try? out.write(to: url)
        #expect(Self.bitonal(url) == false)
    }

    @Test("Offsets past 2 GB are written in full in the xref table (Codex review)")
    func largeOffsets() {
        #expect(PDFCCITT.offsetField(3_000_000_000) == "3000000000")
        #expect(PDFCCITT.offsetField(146) == "0000000146")
        #expect(PDFCCITT.offsetField(10_000_000_000) == nil)
    }

    @Test("An export of a black and white scan stores its page as Group 4")
    func exportUsesGroup4() throws {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = Fixtures.writePDF("g4-export-src.pdf", media: letter, pages: [{ $0.draw(Fixtures.scan(2550, 3300), in: letter) }])
        let doc = try #require(PDFDocument(url: url))
        let page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        var s = PDFExporter.Settings()
        s.ocr = false
        let out = Fixtures.url("g4-export-out.pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: out, settings: s)
        #expect(Self.filter(out) == "CCITTFaxDecode")
        #expect(PDFDocument(url: out)?.pageCount == 1)
    }
}
