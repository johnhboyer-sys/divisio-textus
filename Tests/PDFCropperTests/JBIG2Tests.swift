import Testing
import Foundation
import PDFKit
@testable import PDFCropper

@Suite("JBIG2")
struct JBIG2Tests {

    /// Packed rows, 1 white, from a pixel rule (true: black); padding bits set to `pad`.
    static func rows(_ w: Int, _ h: Int, pad: Bool = true, black: (Int, Int) -> Bool) -> [UInt8] {
        let rowBytes = (w + 7) / 8
        var data = [UInt8](repeating: 0xFF, count: rowBytes * h)
        for y in 0..<h {
            for x in 0..<(rowBytes * 8) where x < w ? black(x, y) : !pad {
                data[y * rowBytes + x / 8] &= ~(0x80 >> UInt8(x % 8))
            }
        }
        return data
    }

    /// A one-page PDF of a JBIG2 image stream, drawn one point per pixel.
    static func pdf(_ stream: Data, _ w: Int, _ h: Int, _ name: String) -> URL {
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func obj(_ body: Data) { offsets.append(out.count); out.append(body) }
        let content = "q \(w) 0 0 \(h) 0 0 cm /Im1 Do Q"
        obj(Data("1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n".utf8))
        obj(Data("2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n".utf8))
        obj(Data("3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)] /Contents 4 0 R /Resources << /XObject << /Im1 5 0 R >> >> >> endobj\n".utf8))
        obj(Data("4 0 obj << /Length \(content.utf8.count) >> stream\n\(content)\nendstream endobj\n".utf8))
        var im = Data("5 0 obj << /Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /Length \(stream.count) >> stream\n".utf8)
        im.append(stream); im.append(Data("\nendstream endobj\n".utf8))
        obj(im)
        let xref = out.count
        var table = "xref\n0 6\n0000000000 65535 f \n"
        for o in offsets { table += String(repeating: "0", count: 10 - String(o).count) + String(o) + " 00000 n \n" }
        out.append(Data((table + "trailer << /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n").utf8))
        let url = Fixtures.url(name)
        try? out.write(to: url)
        return url
    }

    /// Page 1 drawn by Quartz at one pixel per point, 8-bit gray.
    static func quartz(_ url: URL, _ w: Int, _ h: Int) -> [UInt8]? {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        ctx.setFillColor(gray: 0.5, alpha: 1)       // neither black nor white: a page not drawn shows
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .none
        ctx.drawPDFPage(page)
        guard let p = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: w * h))
    }

    static let pdftoppm = "/opt/homebrew/bin/pdftoppm"

    /// Page 1 drawn by poppler at 4 pixels per point, 8-bit gray; nil if it fails. (Below
    /// 4 times its pixels poppler smooths an image, so 1:1 would not show the bits.)
    static func poppler(_ url: URL) -> (px: [UInt8], w: Int, h: Int)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pdftoppm)
        p.arguments = ["-r", "288", "-gray", "-f", "1", "-l", "1", url.path]
        let pipe = Pipe(), err = Pipe()
        p.standardOutput = pipe
        p.standardError = err
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        // P5 header: "P5", width, height, maxval, one whitespace, then the pixels.
        let bytes = [UInt8](data)
        var i = 0, fields: [Int] = []
        func skipSpace() { while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 } }
        guard bytes.count > 2, bytes[0] == 0x50, bytes[1] == 0x35 else { return nil }
        i = 2
        while fields.count < 3 {
            skipSpace()
            var v = 0, digits = 0
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { v = v * 10 + Int(bytes[i] - 0x30); i += 1; digits += 1 }
            guard digits > 0 else { return nil }
            fields.append(v)
        }
        i += 1
        let (w, h) = (fields[0], fields[1])
        guard fields[2] == 255, bytes.count - i == w * h else { return nil }
        return (Array(bytes[i...]), w, h)
    }

    /// Black (0) or white (255) per pixel, as `rows` holds it.
    static func expected(_ rows: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        let rowBytes = (w + 7) / 8
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { out[y * w + x] = rows[y * rowBytes + x / 8] & (0x80 >> UInt8(x % 8)) != 0 ? 255 : 0 } }
        return out
    }

    /// Encode, wrap and draw with Quartz (and poppler when asked): the same bits back.
    @discardableResult
    func roundTrip(_ w: Int, _ h: Int, _ name: String, tpgd: Bool = true, poppler: Bool = false,
                   pad: Bool = true, black: (Int, Int) -> Bool) throws -> Int {
        let rows = Self.rows(w, h, pad: pad, black: black)
        let stream = rows.withUnsafeBytes { JBIG2Generic.encode($0, width: w, height: h, rowBytes: (w + 7) / 8, typicalPrediction: tpgd) }
        #expect(!stream.isEmpty, "\(name)")
        let url = Self.pdf(stream, w, h, "jbig2-\(name).pdf")
        let want = Self.expected(rows, w, h)
        let got = try #require(Self.quartz(url, w, h), "\(name)")
        #expect(got == want, "\(name): Quartz draws other pixels")
        if poppler {
            let p = try #require(Self.poppler(url), "\(name): pdftoppm failed")
            #expect(p.w == 4 * w && p.h == 4 * h, "\(name): pdftoppm size \(p.w)x\(p.h)")
            var big = [UInt8](repeating: 0, count: 16 * w * h)
            for y in 0..<(4 * h) { for x in 0..<(4 * w) { big[y * 4 * w + x] = want[(y / 4) * w + x / 4] } }
            #expect(p.px == big, "\(name): pdftoppm draws other pixels")
        }
        return stream.count
    }

    static func noise(_ w: Int, _ h: Int, oneIn: Int, seed: UInt64) -> [Bool] {
        var s = seed
        return (0..<(w * h)).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Int(s >> 33) % oneIn == 0
        }
    }

    /// Lines of letter-sized marks of uneven widths and heights, with specks between.
    static func textRule(_ w: Int, _ h: Int) -> (Int, Int) -> Bool {
        var seed: UInt64 = 12345
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
        var ink = [Bool](repeating: false, count: w * h)
        var y = 40
        while y + 40 < h {
            var x = 60
            while x + 40 < w - 60 {
                let bw = 8 + next(20), bh = 18 + next(14)
                for yy in (y + 32 - bh)..<(y + 32) { for xx in x..<(x + bw) where next(9) != 0 { ink[yy * w + xx] = true } }
                x += bw + 3 + next(6) + (next(6) == 0 ? 18 : 0)
            }
            y += 48
        }
        for _ in 0..<(w * h / 400) { ink[next(w * h)] = true }
        return { x, y in ink[y * w + x] }
    }

    static func image(_ w: Int, _ h: Int, _ rule: (Int, Int) -> Bool) -> CGImage {
        let rowBytes = (w + 7) / 8
        return CGImage(width: w, height: h, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: CGDataProvider(data: Data(rows(w, h, black: rule)) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func cases(poppler: Bool) throws {
        let t = JBIG2Tests()
        for tpgd in [true, false] {
            let tag = tpgd ? "" : "-notp"
            try t.roundTrip(300, 200, "white" + tag, tpgd: tpgd, poppler: poppler) { _, _ in false }
            try t.roundTrip(300, 200, "black" + tag, tpgd: tpgd, poppler: poppler) { _, _ in true }
            try t.roundTrip(1, 1, "one-white" + tag, tpgd: tpgd, poppler: poppler) { _, _ in false }
            try t.roundTrip(1, 1, "one-black" + tag, tpgd: tpgd, poppler: poppler) { _, _ in true }
            for w in [1, 7, 8, 9, 2801] {
                let n = noise(w, 60, oneIn: 3, seed: UInt64(w))
                try t.roundTrip(w, 60, "width\(w)" + tag, tpgd: tpgd, poppler: poppler) { x, y in n[y * w + x] || y % 7 == 0 }
            }
            let n = noise(700, 500, oneIn: 2, seed: 99)
            try t.roundTrip(700, 500, "noise" + tag, tpgd: tpgd, poppler: poppler) { x, y in n[y * 700 + x] }
            try t.roundTrip(1001, 700, "text" + tag, tpgd: tpgd, poppler: poppler, black: textRule(1001, 700))
            try t.roundTrip(333, 211, "last-row-column" + tag, tpgd: tpgd, poppler: poppler) { x, y in x == 332 || y == 210 }
            try t.roundTrip(333, 211, "last-pixel" + tag, tpgd: tpgd, poppler: poppler) { x, y in x == 332 && y == 210 }
        }
        // Padding bits that are not white are ignored.
        try t.roundTrip(13, 40, "dirty-padding", poppler: poppler, pad: false) { x, y in (x + y) % 5 == 0 }
    }

    @Test("A row stride too big for the rows gives no data, not a crash (Codex review)")
    func badStride() {
        let rows = [UInt8](repeating: 0xFF, count: 4)
        rows.withUnsafeBytes { buf in
            #expect(JBIG2Generic.encode(buf, width: 1, height: 2, rowBytes: Int.max).isEmpty)
            #expect(JBIG2Generic.encode(buf, width: 8, height: 5, rowBytes: 1).isEmpty)
            #expect(!JBIG2Generic.encode(buf, width: 8, height: 4, rowBytes: 1).isEmpty)
        }
    }

    @Test("Quartz draws every JBIG2 pixel as coded")
    func quartzDecodes() throws { try Self.cases(poppler: false) }

    @Test("Poppler draws every JBIG2 pixel as coded",
          .enabled(if: FileManager.default.isExecutableFile(atPath: JBIG2Tests.pdftoppm)))
    func popplerDecodes() throws { try Self.cases(poppler: true) }

    @Test("A text page is smaller as JBIG2 than as Group 4")
    func smallerThanGroup4() throws {
        let data = Self.rows(2400, 1800, black: Self.textRule(2400, 1800))
        let jb = data.withUnsafeBytes { JBIG2Generic.encode($0, width: 2400, height: 1800, rowBytes: 300) }
        let g4 = data.withUnsafeBytes { CCITTG4.encode($0, width: 2400, height: 1800, rowBytes: 300) }
        #expect(!jb.isEmpty && jb.count < g4.count, "JBIG2 \(jb.count) Group 4 \(g4.count)")
    }

    /// Recode a Quartz PDF of `image`; the filter it came out with. Same pixels either way.
    func recompress(_ image: CGImage, _ name: String, jbig2: Bool) throws -> String? {
        let src = CCITTTests.pdf(image, name + ".pdf")
        let copy = Fixtures.url(name + "-jb.pdf")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: src, to: copy)
        #expect(PDFCCITT.recompress(at: copy, jbig2: jbig2), "\(name)")
        let before = try #require(PDFDocument(url: src)), after = try #require(PDFDocument(url: copy))
        #expect(after.pageCount == 1)
        let a = try #require(before.page(at: 0).flatMap { PDFRenderer.renderCGImage(page: $0, dpi: 300) })
        let b = try #require(after.page(at: 0).flatMap { PDFRenderer.renderCGImage(page: $0, dpi: 300) })
        #expect(HillClimb.rgbx(a) == HillClimb.rgbx(b), "\(name): pixels differ")
        return CCITTTests.filter(copy)
    }

    @Test("Recompress stores pages as JBIG2, or Group 4 with JBIG2 off; same pixels")
    func recompressPicks() throws {
        #expect(try recompress(Self.image(2400, 1800, Self.textRule(2400, 1800)), "jb-text", jbig2: true) == "JBIG2Decode")
        let white = Self.image(2400, 1800) { _, _ in false }
        #expect(try recompress(white, "jb-white", jbig2: true) == "JBIG2Decode")
        #expect(try recompress(white, "jb-text-off", jbig2: false) == "CCITTFaxDecode")
        // JBIG2 is a PDF 1.4 filter; Quartz writes 1.3.
        let head = { (name: String) in try String(decoding: Data(contentsOf: Fixtures.url(name)).prefix(8), as: UTF8.self) }
        #expect(try head("jb-text-jb.pdf") == "%PDF-1.4")
        #expect(try head("jb-text-off-jb.pdf") == "%PDF-1.3")
    }
}
