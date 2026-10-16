import Testing
import Foundation
import CoreGraphics
@testable import PDFCropper

/// "Whole page" crops: the sheet of paper, margins included, without the
/// scanner background around it or the facing page.
@Suite("Whole-page crops")
struct PaperTests {

    static let w = 1000, h = 1400

    /// Text-like bars inside the box (pixels, top-left origin) on context `c`.
    static func text(_ c: CGContext, _ box: CGRect) {
        c.setFillColor(CGColor(gray: 0.1, alpha: 1))
        var y = Int(box.minY) + 20
        var i = 0
        while y + 12 < Int(box.maxY) {
            var x = Int(box.minX)
            while x < Int(box.maxX) {
                let len = 20 + (x * 7 + i * 13) % 50
                c.fill(CGRect(x: x, y: h - y - 12, width: min(len, Int(box.maxX) - x), height: 12))
                x += len + 12
            }
            y += 40; i += 1
        }
    }

    /// A sheet of paper (`paper` grey) at `sheet` on a `background` scan, with text
    /// set inside 10% margins.
    static func scan(sheet: CGRect, paper: Double = 1, background: Double = 0.05, text body: Bool = true) -> CGImage {
        Fixtures.image(w, h) { c in
            c.setFillColor(CGColor(gray: background, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.setFillColor(CGColor(gray: paper, alpha: 1))
            c.fill(CGRect(x: sheet.minX, y: Double(h) - sheet.maxY, width: sheet.width, height: sheet.height))
            if body { text(c, sheet.insetBy(dx: sheet.width / 10, dy: sheet.height / 10)) }
        }
    }

    static func expectNear(_ r: CropRect, _ x: Double, _ y: Double, _ maxX: Double, _ maxY: Double,
                           tol: Double = 0.006, _ note: String = "") {
        #expect(abs(r.minX - x) <= tol && abs(r.minY - y) <= tol && abs(r.maxX - maxX) <= tol && abs(r.maxY - maxY) <= tol,
                "\(note) got x \(r.minX)…\(r.maxX), y \(r.minY)…\(r.maxY); want x \(x)…\(maxX), y \(y)…\(maxY)")
    }

    static func paper(_ img: CGImage, _ side: Range<Double> = 0..<1) -> CropRect {
        PageAnalyzer.paperBounds(GrayBuffer(cgImage: img)!, xRange: side)
    }

    @Test("A scan cut at the paper's edge is all page")
    func allPaper() {
        let img = Self.scan(sheet: CGRect(x: 0, y: 0, width: Self.w, height: Self.h))
        Self.expectNear(Self.paper(img), 0, 0, 1, 1)
    }

    @Test("The sheet is found on a dark scanner background", arguments: [0.05, 0.3])
    func sheetOnBackground(background: Double) {
        let img = Self.scan(sheet: CGRect(x: 80, y: 60, width: 840, height: 1280), background: background)
        Self.expectNear(Self.paper(img), 0.08, 60.0 / 1400, 0.92, 1340.0 / 1400)
    }

    @Test("Tinted paper on a grey background")
    func tintedSheet() {
        let img = Self.scan(sheet: CGRect(x: 50, y: 100, width: 900, height: 1200), paper: 0.78, background: 0.3)
        Self.expectNear(Self.paper(img), 0.05, 100.0 / 1400, 0.95, 1300.0 / 1400)
    }

    @Test("A blank sheet is still found")
    func blankSheet() {
        let img = Self.scan(sheet: CGRect(x: 80, y: 60, width: 840, height: 1280), text: false)
        Self.expectNear(Self.paper(img), 0.08, 60.0 / 1400, 0.92, 1340.0 / 1400)
    }

    @Test("A dark plate printed near the edge is page, not background")
    func plateNearEdge() {
        let img = Fixtures.image(Self.w, Self.h) { c in
            c.setFillColor(CGColor(gray: 0.12, alpha: 1)); c.fill(CGRect(x: 0, y: 200, width: 600, height: 1000))
            Self.text(c, CGRect(x: 650, y: 150, width: 300, height: 1100))
        }
        Self.expectNear(Self.paper(img), 0, 0, 1, 1)
    }

    @Test("Paper darkening toward its edges (old stock, a curl) stays page")
    func darkenedEdges() {
        let img = Fixtures.image(Self.w, Self.h) { c in
            for x in 0..<60 {                    // 60% grey at the edge, fading in
                let d = Double(x) / 60
                c.setFillColor(CGColor(gray: 0.6 + 0.4 * d, alpha: 1))
                c.fill(CGRect(x: x, y: 0, width: 1, height: Self.h))
                c.fill(CGRect(x: Self.w - 1 - x, y: 0, width: 1, height: Self.h))
            }
            Self.text(c, CGRect(x: 100, y: 140, width: 800, height: 1120))
        }
        Self.expectNear(Self.paper(img), 0, 0, 1, 1)
    }

    @Test("A black scanner band behind a white strip, and the book block's streaks, are not page")
    func wallaceBand() {
        let img = AnalysisTests.wallaceSpread()
        let r = PageAnalyzer.analyze(cgImage: img, target: .page)
        #expect(r.classification == .spread)
        // Band and streaks end at x = 275 px of 2000; the gutter is at 0.57.
        Self.expectNear(r.leftCrop, 275.0 / 2000, 0, r.splitX, 1, tol: 0.004, "left")
        Self.expectNear(r.rightCrop, r.splitX, 0, 1, 1, tol: 0.004, "right")
    }

    @Test("A black fold between the pages is left out of both")
    func blackFold() {
        let sw = 2 * Self.w
        let img = Fixtures.image(sw, Self.h) { c in
            Self.text(c, CGRect(x: 120, y: 150, width: 760, height: 1100))
            Self.text(c, CGRect(x: 1120, y: 150, width: 760, height: 1100))
            c.setFillColor(CGColor(gray: 0.04, alpha: 1)); c.fill(CGRect(x: 970, y: 0, width: 60, height: Self.h))
        }
        let r = PageAnalyzer.analyze(cgImage: img, target: .page)
        Self.expectNear(r.leftCrop, 0, 0, 970.0 / 2000, 1, tol: 0.004, "left")
        Self.expectNear(r.rightCrop, 1030.0 / 2000, 0, 1, 1, tol: 0.004, "right")
    }

    @Test("A straightened page's crop keeps clear of the corners the turn left empty")
    func turnedCorners() {
        // Tinted paper filling the scan, so any fill corner shows up white.
        let page = Self.scan(sheet: CGRect(x: 0, y: 0, width: Self.w, height: Self.h), paper: 0.8)
        let turned = ImageTransform.rotateInPlace(page, degrees: 1.5, pivot: CGPoint(x: 0.5, y: 0.5))
        let a = AppModel.analyzePage(turned, deskew: true, as: .single, target: .page)
        #expect(abs(a.leftSkew + 1.5) < 0.2)
        let out = ImageTransform.deskewedComposite(turned, splitX: 0.5, leftDegrees: a.leftSkew,
                                                   rightDegrees: 0, isSpread: false)
        let g = GrayBuffer(cgImage: out, maxDim: Self.h)!
        let c = a.result.leftCrop
        var white = 0
        for y in Int(c.minY * Double(g.height)).advanced(by: 1)..<Int(c.maxY * Double(g.height)) - 1 {
            for x in Int(c.minX * Double(g.width)) + 1..<Int(c.maxX * Double(g.width)) - 1 where g.value(x, y) > 235 { white += 1 }
        }
        #expect(white == 0, "\(white) fill pixels inside \(c)")
        #expect(c.width * c.height > 0.9, "crop \(c)")
    }

    @Test("A sheet turned on a dark background comes out level, cropped at its edges")
    func turnedSheet() {
        // Turned as it lay on the scanner: background all round, no fill corners.
        // Straightening it then leaves fill corners wider than a scanner's light
        // edge strip, which the crop must not mistake for paper.
        let sheet = Self.scan(sheet: CGRect(x: 100, y: 80, width: 800, height: 1240))
        let turned = Fixtures.image(Self.w, Self.h) { c in
            c.setFillColor(CGColor(gray: 0.05, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: Self.w, height: Self.h))
            c.translateBy(x: Double(Self.w) / 2, y: Double(Self.h) / 2)
            c.rotate(by: -3.5 * .pi / 180)
            c.translateBy(x: -Double(Self.w) / 2, y: -Double(Self.h) / 2)
            c.draw(sheet, in: CGRect(x: 0, y: 0, width: Self.w, height: Self.h))
        }
        let a = AppModel.analyzePage(turned, deskew: true, as: .single, target: .page)
        #expect(abs(a.leftSkew - 3.5) < 0.2, "straightened by \(a.leftSkew)°")
        Self.expectNear(a.result.leftCrop, 0.1, 80.0 / 1400, 0.9, 1320.0 / 1400, tol: 0.01)
    }

    @Test("On a tight scan turned a long way, the whole page still holds all the text")
    func tightScanKeepsText() {
        // Text to within 2% of the paper's edges, which fill the scan.
        let page = Fixtures.image(Self.w, Self.h) { c in Self.text(c, CGRect(x: 20, y: 10, width: 960, height: 1370)) }
        let turned = ImageTransform.rotateInPlace(page, degrees: 2.5, pivot: CGPoint(x: 0.5, y: 0.5))
        let a = AppModel.analyzePage(turned, deskew: true, as: .single, target: .page)
        let out = ImageTransform.deskewedComposite(turned, splitX: 0.5, leftDegrees: a.leftSkew,
                                                   rightDegrees: 0, isSpread: false)
        // Every printed pixel of the straightened page lies inside the crop.
        let g = GrayBuffer(cgImage: out, maxDim: Self.h)!, c = a.result.leftCrop
        var outside = 0
        for y in 0..<g.height {
            for x in 0..<g.width where g.value(x, y) < 128 {
                let nx = (Double(x) + 0.5) / Double(g.width), ny = (Double(y) + 0.5) / Double(g.height)
                if nx < c.minX || nx > c.maxX || ny < c.minY || ny > c.maxY { outside += 1 }
            }
        }
        #expect(outside == 0, "\(outside) text pixels outside \(c)")
    }

    @Test("The corners a turn leaves empty cost no more paper than they must")
    func tightestUprightBox() {
        // A blank tinted sheet filling an 800 px square, straightened by 6°: the
        // largest upright square inside it is inset 36 px a side (plus a pixel and
        // a half kept clear of the turned edge).
        let sheet = Fixtures.image(800, 800) { c in
            c.setFillColor(CGColor(gray: 0.8, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
        }
        let turned = ImageTransform.rotateInPlace(sheet, degrees: 6, pivot: CGPoint(x: 0.5, y: 0.5))
        let r = PageAnalyzer.paperBounds(GrayBuffer(cgImage: turned)!, xRange: 0..<1, turned: 6)
        #expect(r.minX * 800 <= 39 && r.minY * 800 <= 39 && r.maxX * 800 >= 761 && r.maxY * 800 >= 761, "\(r)")
        #expect(r.minX * 800 >= 36 && r.minY * 800 >= 36, "\(r)")
    }

    @Test("Text-block crops are unchanged by default")
    func textByDefault() {
        let img = Self.scan(sheet: CGRect(x: 80, y: 60, width: 840, height: 1280))
        let r = PageAnalyzer.analyze(cgImage: img, as: .single)
        #expect(r.leftCrop.minX > 0.15 && r.leftCrop.maxX < 0.85)
    }
}
