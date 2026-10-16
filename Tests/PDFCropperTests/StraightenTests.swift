import Testing
import Foundation
import CoreGraphics
@testable import PDFCropper

/// Auto-straighten, run through the app's own per-page pipeline: a page turned
/// by a known angle must come out level. The tilt is measured independently of
/// the detector, from where each line's ink sits at its two ends.
@Suite("Straightening")
struct StraightenTests {

    static let w = 1000, h = 1400
    static let rows = (0..<12).map { 150 + $0 * 100 }      // line centers, from the top
    static let ends = (left: 120..<280, right: 720..<880)  // where each line's ends are measured

    /// A page of widely spaced text lines (so a tilted line never runs into the next).
    /// `paper` below 1 gives tinted stock with one white speck, as on old scans.
    static func page(paper: Double = 1) -> CGImage {
        Fixtures.image(w, h) { c in
            if paper < 1 {
                c.setFillColor(CGColor(gray: paper, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
                c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 950, y: 20, width: 6, height: 6))
            }
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for (i, y) in rows.enumerated() {
                var x = 100
                while x < 900 {
                    let len = 20 + (x * 7 + i * 13) % 50
                    c.fill(CGRect(x: x, y: h - y - 6, width: min(len, 900 - x), height: 12))
                    x += len + 12
                }
            }
        }
    }

    /// Median tilt in degrees (+ = right end higher) of the lines in `img`, whose
    /// left edge is at `x0` px.
    static func tilt(_ img: CGImage, x0: Int = 0, rows: [Int] = rows,
                     ends: (left: Range<Int>, right: Range<Int>) = ends) -> Double {
        let g = GrayBuffer(cgImage: img, maxDim: max(img.width, img.height))!
        // Where the ink sits in each end window, both across and along the line:
        // the slope runs between those two points, not between the windows' edges.
        func centroid(_ xs: Range<Int>, near y: Int) -> (x: Double, y: Double)? {
            var sw = 0.0, sx = 0.0, sy = 0.0
            for yy in max(0, y - 45)..<min(g.height, y + 45) {
                for x in xs {   // weighted by darkness, so edge pixels place the ink to a fraction of a pixel
                    let w = Double(255 - Int(g.value(x + x0, yy))) / 255
                    if w > 0.02 { sw += w; sx += w * Double(x); sy += w * Double(yy) }
                }
            }
            return sw > 0 ? (sx / sw, sy / sw) : nil
        }
        let angles = rows.compactMap { y -> Double? in
            guard let l = centroid(ends.left, near: y), let r = centroid(ends.right, near: y) else { return nil }
            return atan2(l.y - r.y, r.x - l.x) * 180 / .pi
        }.sorted()
        return angles[angles.count / 2]
    }

    @Test("The tilt measure itself reads a known turn", arguments: [-2.0, 0.5])
    func measureIsTrue(degrees: Double) {
        let turned = ImageTransform.rotateInPlace(Self.page(), degrees: degrees, pivot: CGPoint(x: 0.5, y: 0.5))
        #expect(abs(Self.tilt(Self.page())) < 0.02)
        #expect(abs(Self.tilt(turned) - degrees) < 0.05)
    }

    @Test("A turned page comes out level", arguments: [-2.0, -0.7, 0.4, 1.5])
    func singleComesOutLevel(degrees: Double) {
        let turned = ImageTransform.rotateInPlace(Self.page(), degrees: degrees, pivot: CGPoint(x: 0.5, y: 0.5))
        let a = AppModel.analyzePage(turned, deskew: true, as: .single)
        let out = ImageTransform.deskewedComposite(turned, splitX: 0.5, leftDegrees: a.leftSkew,
                                                   rightDegrees: 0, isSpread: false)
        #expect(abs(Self.tilt(out)) <= 0.15, "turned \(degrees)°, corrected by \(a.leftSkew)°")
    }

    @Test("A page on tinted paper comes out level too", arguments: [0.55, 0.7])
    func tintedPaper(paper: Double) {
        let turned = ImageTransform.rotateInPlace(Self.page(paper: paper), degrees: 1.2, pivot: CGPoint(x: 0.5, y: 0.5))
        let a = AppModel.analyzePage(turned, deskew: true, as: .single)
        let out = ImageTransform.deskewedComposite(turned, splitX: 0.5, leftDegrees: a.leftSkew,
                                                   rightDegrees: 0, isSpread: false)
        #expect(abs(Self.tilt(out)) <= 0.15, "corrected by \(a.leftSkew)°")
        #expect(a.result.leftCrop.width < 0.9 && a.result.leftCrop.height < 0.9)   // the text, not the sheet
    }

    @Test("A two-column page whose columns' lines don't line up comes out level", arguments: [-0.8, 0.5])
    func twoColumns(degrees: Double) {
        let leftRows = (0..<12).map { 150 + $0 * 100 }, rightRows = leftRows.map { $0 + 15 }
        let page = Fixtures.image(Self.w, Self.h) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for (rows, x0, x1) in [(leftRows, 100, 460), (rightRows, 540, 900)] {
                for (i, y) in rows.enumerated() {
                    var x = x0
                    while x < x1 {
                        let len = 20 + (x * 7 + i * 13) % 50
                        c.fill(CGRect(x: x, y: Self.h - y - 6, width: min(len, x1 - x), height: 12))
                        x += len + 12
                    }
                }
            }
        }
        let turned = ImageTransform.rotateInPlace(page, degrees: degrees, pivot: CGPoint(x: 0.5, y: 0.5))
        let a = AppModel.analyzePage(turned, deskew: true, as: .single)
        let out = ImageTransform.deskewedComposite(turned, splitX: 0.5, leftDegrees: a.leftSkew,
                                                   rightDegrees: 0, isSpread: false)
        let left = Self.tilt(out, rows: leftRows, ends: (110..<190, 370..<450))
        let right = Self.tilt(out, rows: rightRows, ends: (550..<630, 810..<890))
        #expect(abs(left) <= 0.15 && abs(right) <= 0.15, "turned \(degrees)°, corrected by \(a.leftSkew)°")
    }

    @Test("Text is straightened by its lines, not by a picture set level beside it")
    func pictureDoesNotWin() {
        // Text turned 0.6°, then a big dark plate drawn level on top of the left half.
        let turned = ImageTransform.rotateInPlace(Self.page(), degrees: 0.6, pivot: CGPoint(x: 0.5, y: 0.5))
        let withPlate = Fixtures.image(Self.w, Self.h) { c in
            c.draw(turned, in: CGRect(x: 0, y: 0, width: Self.w, height: Self.h))
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 60, y: 300, width: 520, height: 900))
            c.setFillColor(CGColor(gray: 0.15, alpha: 1)); c.fill(CGRect(x: 80, y: 320, width: 480, height: 860))
        }
        let a = AppModel.analyzePage(withPlate, deskew: true, as: .single)
        #expect(abs(a.leftSkew + 0.6) <= 0.15, "corrected by \(a.leftSkew)°")
    }

    @Test("A sparse page of short centered lines comes out level", arguments: [-0.4, 0.3])
    func sparseShortLines(degrees: Double) {
        // Seven short centered lines, as on a title page.
        let rows = [200, 310, 420, 860, 970, 1080, 1190]
        let page = Fixtures.image(Self.w, Self.h) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for (i, y) in rows.enumerated() {
                var x = 330
                while x < 670 { let len = 12 + (x * 7 + i) % 18; c.fill(CGRect(x: x, y: Self.h - y - 5, width: min(len, 670 - x), height: 10)); x += len + 6 }
            }
        }
        let ends = (left: 335..<420, right: 580..<665)
        let turned = ImageTransform.rotateInPlace(page, degrees: degrees, pivot: CGPoint(x: 0.5, y: 0.5))
        let read = Self.tilt(turned, rows: rows, ends: ends)
        #expect(abs(read - degrees) < 0.05, "the measure read \(read)°")   // the measure reads the turn
        let a = AppModel.analyzePage(turned, deskew: true, as: .single)
        let out = ImageTransform.deskewedComposite(turned, splitX: 0.5, leftDegrees: a.leftSkew,
                                                   rightDegrees: 0, isSpread: false)
        #expect(abs(Self.tilt(out, rows: rows, ends: ends)) <= 0.15, "turned \(degrees)°, corrected by \(a.leftSkew)°")
    }

    @Test("Each half of a spread comes out level, each turned its own way")
    func spreadHalvesComeOutLevel() {
        let l = ImageTransform.rotateInPlace(Self.page(), degrees: -1.2, pivot: CGPoint(x: 0.5, y: 0.5))
        let r = ImageTransform.rotateInPlace(Self.page(), degrees: 0.8, pivot: CGPoint(x: 0.5, y: 0.5))
        let spread = Fixtures.image(2 * Self.w, Self.h) { c in
            c.draw(l, in: CGRect(x: 0, y: 0, width: Self.w, height: Self.h))
            c.draw(r, in: CGRect(x: Self.w, y: 0, width: Self.w, height: Self.h))
        }
        let a = AppModel.analyzePage(spread, deskew: true, as: .spread)
        let out = ImageTransform.deskewedComposite(spread, splitX: a.result.splitX, leftDegrees: a.leftSkew,
                                                   rightDegrees: a.rightSkew, isSpread: true)
        #expect(abs(Self.tilt(out)) <= 0.15, "left corrected by \(a.leftSkew)°")
        #expect(abs(Self.tilt(out, x0: Self.w)) <= 0.15, "right corrected by \(a.rightSkew)°")
    }

    @Test("A straightened spread keeps its split on a soft binding shadow, and the crops leave it out")
    func shadowSurvivesStraightening() {
        let l = ImageTransform.rotateInPlace(Self.page(), degrees: -1.2, pivot: CGPoint(x: 0.5, y: 0.5))
        let r = ImageTransform.rotateInPlace(Self.page(), degrees: 0.8, pivot: CGPoint(x: 0.5, y: 0.5))
        let spread = Fixtures.image(2 * Self.w, Self.h) { c in
            c.draw(l, in: CGRect(x: 0, y: 0, width: Self.w, height: Self.h))
            c.draw(r, in: CGRect(x: Self.w, y: 0, width: Self.w, height: Self.h))
            for x in (Self.w - 40)..<(Self.w + 40) {             // 62% grey at the fold, fading out
                let d = abs(Double(x - Self.w)) / 40
                c.setFillColor(CGColor(gray: 0.62 + 0.38 * d * d, alpha: 1))
                c.fill(CGRect(x: x, y: 0, width: 1, height: Self.h))
            }
        }
        let a = AppModel.analyzePage(spread, deskew: true)
        #expect(a.result.classification == .spread)
        #expect(abs(a.result.splitX - 0.5) < 0.01, "split \(a.result.splitX)")
        #expect(a.result.leftCrop.maxX < 0.495 && a.result.rightCrop.minX > 0.505,
                "crops end at \(a.result.leftCrop.maxX) and start at \(a.result.rightCrop.minX)")
    }
}
