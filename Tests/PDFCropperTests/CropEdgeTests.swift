import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFCropper

/// Whole page crops end at the page's own edge (John, 2026-11-23): scanner bed is
/// left out, the book's margins kept. (A comb binding's teeth stay, to the split:
/// Remove shadows clears them, John 2026-11-23.)
@Suite("Crop to the page's edge")
struct CropEdgeTests {

    static let w = AnalysisTests.width, h = AnalysisTests.height

    /// Wallace as scanned: the black band (x 28 to 240) and its streaks (to 275) sit
    /// inside the glass's white frame, 28 px wide at the left, top and bottom (the
    /// same on all three sides, as on the real scans; about 2% of the height). Text
    /// from 380; the gutter a white gap at 0.57.
    static func framedBand() -> CGImage {
        Fixtures.image(w, h) { c in
            let frame = 28
            c.setFillColor(CGColor(gray: 0.02, alpha: 1))
            c.fill(CGRect(x: frame, y: frame, width: 240 - frame, height: h - 2 * frame))
            for x in stride(from: 240, to: 275, by: 4) { c.fill(CGRect(x: x, y: frame, width: 2, height: h - 2 * frame)) }
            let g = Int(0.57 * Double(w))
            AnalysisTests.text(c, 380, g - 80)
            AnalysisTests.text(c, g + 80, w - 180)
        }
    }

    @Test("A black band inside the glass's white frame is bed, not page")
    func bandInsideFrame() {
        let r = PageAnalyzer.analyze(cgImage: Self.framedBand(), target: .page)
        #expect(r.classification == .spread)
        // Band and streaks end at 275 px; the text starts at 380.
        #expect(r.leftCrop.minX >= 274.0 / Double(Self.w) && r.leftCrop.minX <= 380.0 / Double(Self.w),
                "left page starts at \(r.leftCrop.minX * Double(Self.w)) px")
        let t = PageAnalyzer.analyze(cgImage: Self.framedBand())
        #expect(t.leftCrop.minX >= 274.0 / Double(Self.w), "text crop starts at \(t.leftCrop.minX * Double(Self.w)) px")
    }

    /// Codex review: a black plate 2% in from the scan's left edge (40 px), its top
    /// and foot 2% (26 px) in from the scan's, to x = 20%, text beyond it. Its
    /// margins are thin and even, but unlike the glass's frame they are not one
    /// width all round: it is print.
    @Test("A black plate with thin even margins by the scan's edge stays")
    func plateWithThinMargins() {
        let img = Fixtures.image(Self.w, Self.h) { c in
            c.setFillColor(CGColor(gray: 0.05, alpha: 1))
            c.fill(CGRect(x: 40, y: 26, width: 360, height: Self.h - 52))
            AnalysisTests.text(c, 480, 1040)
            AnalysisTests.text(c, 1200, 1840)
        }
        let W = Double(Self.w)
        for target in [CropTarget.text, .page] {
            let r = PageAnalyzer.analyze(cgImage: img, target: target)
            #expect(r.leftCrop.minX * W <= 41, "\(target): left page from \(r.leftCrop.minX * W) px, plate from 40")
        }
        #expect(PageAnalyzer.findBook(img) == nil, "trim \(String(describing: PageAnalyzer.findBook(img)))")
    }

    /// Codex review, round 2: a picture 1.5% (30 px) in from the scan's left edge,
    /// top and foot alike, to x = 20%, text beyond it. Its margins match like the
    /// glass's frame, but it is printed in tones, not solid black.
    @Test("A halftone picture with equal thin margins by the scan's edge stays")
    func halftoneWithEqualMargins() {
        let img = Fixtures.image(Self.w, Self.h) { c in
            // Dark (5% grey) and darkish (35%) bands 8 px each: all of it dark
            // beside paper, but only half of it as black as bed.
            for y in stride(from: 30, to: Self.h - 30, by: 8) {
                c.setFillColor(CGColor(gray: (y / 8) % 2 == 0 ? 0.05 : 0.35, alpha: 1))
                c.fill(CGRect(x: 30, y: y, width: 370, height: min(8, Self.h - 30 - y)))
            }
            AnalysisTests.text(c, 480, 1040)
            AnalysisTests.text(c, 1200, 1840)
        }
        let W = Double(Self.w)
        for target in [CropTarget.text, .page] {
            let r = PageAnalyzer.analyze(cgImage: img, target: target)
            #expect(r.leftCrop.minX * W <= 31, "\(target): left page from \(r.leftCrop.minX * W) px, picture from 30")
        }
        #expect(PageAnalyzer.findBook(img) == nil, "trim \(String(describing: PageAnalyzer.findBook(img)))")
    }

    /// Freudenthal's fold: a line 3 px wide, dark (60% grey) down the top 40% of
    /// the page and paler (75%) below, leaning 5 px over the height, off the middle
    /// of the white gap between the two pages' text (left text to 880 px, right
    /// from 1028, fold at 952).
    static func faintFold() -> CGImage {
        Fixtures.image(w, h) { c in
            AnalysisTests.text(c, 160, 880)
            AnalysisTests.text(c, 1028, 1840)
            for y in 0..<h {
                let down = h - 1 - y                                   // rows from the top
                c.setFillColor(CGColor(gray: down < h * 2 / 5 ? 0.6 : 0.75, alpha: 1))
                c.fill(CGRect(x: 949.5 + 5 * Double(down) / Double(h), y: Double(y), width: 3, height: 1))
            }
        }
    }

    @Test("A faint fold line in a white gap is the split, not the middle of the gap's wider half")
    func faintFoldLine() {
        let r = PageAnalyzer.analyze(cgImage: Self.faintFold())
        #expect(r.classification == .spread)
        #expect(abs(r.splitX * Double(Self.w) - 952) <= 5, "split at \(r.splitX * Double(Self.w)) px, fold at 952")
    }
}

/// Oesterle scan 35: a blank left page whose edge clutter (the slanted edges of
/// the leaves below it, a dark line along the scan's foot) reads as print filling
/// its whole half, so it is not called blank; the white of the page then passes
/// for the gutter (0.395, the comb at about 0.525). Its split goes to the book's
/// usual one, as beside a blank page. Run on the real scans (HILLCLIMB_DIR).
@Suite("Crop to the page's edge: Oesterle scan 35", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct CropEdgeOesterleTests {
    @Test("A spread whose one side holds only edge clutter gets the book's usual split")
    func clutteredBlankPage() async throws {
        let src = try #require(HillClimb.bookURLs().first { $0.lastPathComponent.hasPrefix("Oesterle") })
        let doc = try #require(PDFDocument(url: src))
        let out = PDFDocument()
        for (k, n) in (32...38).enumerated() { out.insert(try #require(doc.page(at: n)?.copy() as? PDFPage), at: k) }
        let url = HillClimb.scratch.appendingPathComponent("oesterle-32-38-\(UUID().uuidString).pdf")
        try #require(out.write(to: url))
        defer { try? FileManager.default.removeItem(at: url) }
        let m = HillClimb.makeModel()
        await HillClimb.load(url, into: m)
        try #require(m.pages.count == 7)
        let p = m.pages[3]                                        // scan 35
        #expect(p.classification == .spread && p.splitX > 0.49 && p.splitX < 0.56, "scan 35: split \(p.splitX)")
    }
}

/// Codex review: a spread rightly split off the book's usual place, beside a plate
/// filling most of its half, keeps its split: a plate has margins, where a blank
/// page's edge clutter runs the scan's whole height.
@Suite("Crop to the page's edge: plate on a shifted spread", .serialized)
@MainActor
struct CropEdgePlateSplitTests {
    @Test("A plate filling most of its half on a shifted spread keeps the spread's own split")
    func shiftedPlateKeepsSplit() async throws {
        let media = CGRect(x: 0, y: 0, width: 1000, height: 650)
        func draw(_ c: CGContext, plate: Bool) {
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            if plate {
                // The fold at 580: a plate 534 × 598 pt (92% of the half each way), text right.
                // A picture in halftone dots, as printed: dark and light parts, no solid black.
                for y in stride(from: 26.0, to: 624, by: 4) {
                    for x in stride(from: 23.0, to: 557, by: 4) where Int(x + y) % 8 == 1 || Int(x * 3 + y) % 7 < 3 {
                        c.fill(CGRect(x: x, y: y, width: 3, height: 3))
                    }
                }
                for row in 0..<30 { c.fill(CGRect(x: 640, y: 560 - Double(row) * 16, width: 320, height: 5)) }
            } else {
                for row in 0..<30 {
                    c.fill(CGRect(x: 80, y: 560 - Double(row) * 16, width: 360, height: 5))
                    c.fill(CGRect(x: 560, y: 560 - Double(row) * 16, width: 360, height: 5))
                }
            }
        }
        let pages: [(CGContext) -> Void] = (0..<6).map { i in { c in draw(c, plate: i == 3) } }
        let url = Fixtures.writePDF("plate-split-\(UUID().uuidString).pdf", media: media, pages: pages)
        let m = testModel()
        m.setCropTarget(.page)
        m.load(url: url)
        await waitUntilIdle(m)
        try #require(m.pages.count == 6)
        let p = m.pages[3]
        #expect(p.classification == .spread && p.splitX > 0.56 && p.splitX < 0.64, "plate spread: split \(p.splitX)")
        #expect(p.leftCrop.minX <= 0.023 && p.leftCrop.maxX >= 0.557, "plate side \(p.leftCrop)")
    }
}

/// John, 2026-11-23: beyond a page's outer edge, a band the page's height (the edges
/// of the leaves below it, Freudenthal scan 80; a strip of bed, tilted by
/// straightening, Riezler's right pages) is no print: the page stops at its edge.
@Suite("Crop to the page's edge: bands beyond the edge")
struct CropEdgeBandTests {
    static let w = AnalysisTests.width, h = AnalysisTests.height

    /// The real pages, as the app analyses them (HILLCLIMB_DIR).
    @Test("Leaf edges (Freudenthal 80) and a tilted bed strip (Riezler 45, 52) are left out",
          .enabled(if: ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil),
          arguments: [("Freudenthal", 80, true, 0.045), ("Riezler", 52, false, 0.978), ("Riezler", 45, false, 0.978)])
    func realBands(book: String, page: Int, left: Bool, edge: Double) throws {
        let url = try #require(HillClimb.bookURLs().first { $0.lastPathComponent.hasPrefix(book) })
        let doc = try #require(PDFDocument(url: url))
        let pdfPage = try #require(doc.page(at: page))
        let cg = try #require(PDFRenderer.renderCGImage(page: pdfPage, dpi: 110))
        let r = AppModel.analyzePage(cg, deskew: true, target: .page, findTrim: true).result
        if left { #expect(r.leftCrop.minX >= edge, "\(book) \(page): left page from \(r.leftCrop.minX)") }
        else { #expect(r.rightCrop.maxX <= edge, "\(book) \(page): right page to \(r.rightCrop.maxX)") }
    }

    /// Codex review: a narrow illustration (60 px, 6% of its page) as tall as the
    /// text beside it, a 10 px gap from the text, margins above and below it. It
    /// does not run the scan's height, so it is print.
    @Test("A narrow illustration as tall as the text, with margins above and below, stays")
    func narrowIllustrationStays() {
        let img = Fixtures.image(Self.w, Self.h) { c in
            c.setFillColor(CGColor(gray: 0.3, alpha: 1))
            c.fill(CGRect(x: 100, y: 100, width: 60, height: Self.h - 240))
            AnalysisTests.text(c, 170, 900)
            AnalysisTests.text(c, 1100, 1800)
        }
        let r = PageAnalyzer.analyze(cgImage: img, as: .spread, split: 0.5, target: .page)
        #expect(r.leftCrop.minX * Double(Self.w) <= 100, "left page from \(r.leftCrop.minX * Double(Self.w)) px")
    }

    /// The score's synth-2-0: a soft shadow at the page's left edge, bed bands, a
    /// tilt of 0.75°, and the left side of a printed frame round the text just
    /// inside the shadow. The frame is print, and stays.
    @Test("A frame's side beside a soft edge shadow stays (synth-2-0)")
    func frameBesideShadow() throws {
        let s = try #require(HCSynth.book(2, pages: 1).specs.first)
        let scan = try #require(HCSynth.render(s, .scan))
        let a = AppModel.analyzePage(scan, deskew: true, target: .page, findTrim: true)
        let crop = a.result.leftCrop.normalized().pixelRect(in: CGSize(width: s.W, height: s.H)).integral.insetBy(dx: -1, dy: -1)
        var cut = 0
        for (k, leaf) in s.leaves.enumerated() where !leaf.items.isEmpty {
            let mask = try #require(HCSynth.render(s, .print(k)))
            let comp = ImageTransform.deskewedComposite(mask, splitX: a.result.splitX, leftDegrees: a.leftSkew,
                                                        rightDegrees: a.rightSkew, isSpread: a.result.classification == .spread)
            let g = HillClimb.gray(comp)
            for y in 0..<s.H { for x in 0..<s.W where g[y * s.W + x] < 100 && !crop.contains(CGPoint(x: x, y: y)) { cut += 1 } }
        }
        #expect(cut == 0, "\(cut) print pixels outside the crop \(a.result.leftCrop)")
    }

    /// Codex review, round 3: a dark illustration 60 px wide with margins of 50 px
    /// (3.8%) above and below, a 10 px gap, then text. It covers over 90% of the
    /// scan's height but runs off neither its top nor its foot: print.
    @Test("An illustration with thin margins above and below is no band")
    func illustrationWithThinMargins() {
        let img = Fixtures.image(Self.w, Self.h) { c in
            c.setFillColor(CGColor(gray: 0.2, alpha: 1))
            c.fill(CGRect(x: 100, y: 50, width: 60, height: Self.h - 100))
            AnalysisTests.text(c, 170, 900)
        }
        let g = GrayBuffer(cgImage: img)!
        let e = PageAnalyzer.outerBand(g, text: CropRect(x: 0.04, y: 0, width: 0.42, height: 1), fromLeft: true, pageWidth: 0.5)
        #expect(e == nil, "page edge put at \(String(describing: e.map { $0 * Double(Self.w) })) px")
    }

    /// Codex review, round 3: leaves' edges x 0 to 50, the whole height, then 6 px
    /// on, line numbers beside the text's lines (x 56 to 76), a gap, the text from
    /// 110. The numbers are print: the band must not take them in.
    @Test("Line numbers just past a band of leaves' edges stay")
    func lineNumbersBesideLeafEdges() {
        let img = Fixtures.image(Self.w, Self.h) { c in
            for x in stride(from: 0, to: 50, by: 5) {
                c.setFillColor(CGColor(gray: 0.3, alpha: 1))
                c.fill(CGRect(x: x, y: 0, width: 3, height: Self.h))
            }
            AnalysisTests.text(c, 56, 76)
            AnalysisTests.text(c, 110, 900)
        }
        let g = GrayBuffer(cgImage: img)!
        let e = PageAnalyzer.outerBand(g, text: CropRect(x: 0, y: 0, width: 0.46, height: 1), fromLeft: true, pageWidth: 0.5)
        #expect(e.map { $0 * Double(Self.w) <= 56 } ?? true, "page edge put at \(String(describing: e.map { $0 * Double(Self.w) })) px")
    }

    /// Codex review, round 4: a solid band of leaves' edges (x 0 to 80), 5 px of
    /// white, then line numbers (x 85 to 95), first on every line and then on only
    /// two lines, a gap, the text from 120. The numbers are print either way.
    @Test("Line numbers close against a solid band stay, many or few", arguments: [0..<34, 10..<12])
    func lineNumbersAgainstBand(numbered: Range<Int>) {
        let img = Fixtures.image(Self.w, Self.h) { c in
            c.setFillColor(CGColor(gray: 0.3, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 80, height: Self.h))
            AnalysisTests.text(c, 85, 95, rows: numbered)
            AnalysisTests.text(c, 120, 900)
        }
        let g = GrayBuffer(cgImage: img)!
        let e = PageAnalyzer.outerBand(g, text: CropRect(x: 0, y: 0, width: 0.46, height: 1), fromLeft: true, pageWidth: 0.5)
        #expect(e.map { $0 * Double(Self.w) <= 85 } ?? true, "page edge put at \(String(describing: e.map { $0 * Double(Self.w) })) px")
    }

    @Test("A picture by the page's outer edge, wider than a band, stays")
    func pictureByEdgeStays() {
        // A grey-toned picture x 40 to 280 (12%), y 100 to 1200, a gap, then text.
        let img = Fixtures.image(Self.w, Self.h) { c in
            for y in stride(from: 100, to: Self.h - 100, by: 6) {
                c.setFillColor(CGColor(gray: (y / 6) % 2 == 0 ? 0.2 : 0.5, alpha: 1))
                c.fill(CGRect(x: 40, y: y, width: 240, height: 6))
            }
            AnalysisTests.text(c, 300, 900)
            AnalysisTests.text(c, 1100, 1800)
        }
        for target in [CropTarget.text, .page] {
            let r = PageAnalyzer.analyze(cgImage: img, as: .spread, split: 0.5, target: target)
            #expect(r.leftCrop.minX * Double(Self.w) <= 41, "\(target): left page from \(r.leftCrop.minX * Double(Self.w)) px")
        }
    }
}
