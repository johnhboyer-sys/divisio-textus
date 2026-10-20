import Testing
import Foundation
import PDFKit
import CoreText
@testable import PDFCropper

/// Page analysis on layouts taken from a real scan (Wallace 1992): a black
/// scanner band along the left edge behind a thin white strip, ragged streaks
/// where it meets the page block, and a clean white gutter off center.
@Suite("Page analysis")
struct AnalysisTests {

    static let width = 2000, height = 1300

    /// Text-like bars between x0 and x1 (pixels), rows from the top.
    static func text(_ c: CGContext, _ x0: Int, _ x1: Int, rows: Range<Int> = 0..<34) {
        c.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for r in rows { c.fill(CGRect(x: x0, y: height - 140 - r * 32, width: x1 - x0, height: 9)) }
    }

    /// The Wallace-style spread: white strip, black band, streaks, then two pages
    /// whose gutter is a clean white gap centered at `gutter` (0...1).
    static func wallaceSpread(gutter: Double = 0.57, titleOnly: Bool = false, blankLeft: Bool = false,
                              hairline: Bool = false) -> CGImage {
        Fixtures.image(width, height) { c in
            c.setFillColor(CGColor(gray: 0.02, alpha: 1))
            c.fill(CGRect(x: 20, y: 0, width: 220, height: height))                    // black band
            for x in stride(from: 240, to: 275, by: 4) {                               // ragged streaks
                c.fill(CGRect(x: x, y: 0, width: 2, height: height))
            }
            let g = Int(gutter * Double(width))
            if !blankLeft {
                text(c, 380, g - 80)                                                   // left page
            } else if hairline {
                c.setFillColor(CGColor(gray: 0.02, alpha: 1))                          // a stray scan line
                c.fill(CGRect(x: 340, y: 700, width: 300, height: 2))
            } else {
                c.setFillColor(CGColor(gray: 0.1, alpha: 1))                           // a speck of dust
                c.fill(CGRect(x: 600, y: 700, width: 6, height: 6))
            }
            if titleOnly {                                                             // a part title:
                let center = (g + 80 + width - 180) / 2                                // one short line
                text(c, center - 160, center + 160, rows: 8..<10)
            } else {
                text(c, g + 80, width - 180)                                           // right page
            }
        }
    }

    @Test("A black scanner band behind a white strip is trimmed off the left page")
    func bandBehindWhiteStrip() {
        let r = PageAnalyzer.analyze(cgImage: Self.wallaceSpread())
        #expect(r.classification == .spread)
        // Band and streaks end at x = 275 px (0.1375); the text starts at 380 (0.19).
        #expect(r.leftCrop.minX > 0.13 && r.leftCrop.minX < 0.19)
    }

    @Test("A clean white gutter is found even off center, and crops don't cross it",
          arguments: [0.47, 0.5, 0.57, 0.64])
    func whiteGutter(gutter: Double) {
        let r = PageAnalyzer.analyze(cgImage: Self.wallaceSpread(gutter: gutter))
        let gapLeft = gutter - 80.0 / Double(Self.width), gapRight = gutter + 80.0 / Double(Self.width)
        #expect(r.splitX > gapLeft && r.splitX < gapRight)
        #expect(r.leftCrop.maxX <= gapRight && r.rightCrop.minX >= gapLeft)
    }

    @Test("A narrow white gutter between two pages of text is still found, not a column of text")
    func narrowGutter() {
        let image = Fixtures.image(Self.width, Self.height) { c in
            Self.text(c, 150, 980)
            Self.text(c, 1010, 1850)      // a 1.5% gap: the pages were trimmed close at the binding
        }
        let r = PageAnalyzer.analyze(cgImage: image)
        #expect(r.splitX > 980.0 / 2000 && r.splitX < 1010.0 / 2000)
    }

    @Test("The split stays clear of a running head close to the gutter")
    func runningHeadNearGutter() {
        let image = Fixtures.image(Self.width, Self.height) { c in
            Self.text(c, 150, 940)
            Self.text(c, 1100, 1850)
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            c.fill(CGRect(x: 1010, y: Self.height - 40, width: 190, height: 12))   // the right page's running head, high up
        }
        let r = PageAnalyzer.analyze(cgImage: image)
        #expect(r.splitX > 940.0 / 2000 && r.splitX < 1010.0 / 2000)
    }

    @Test("A soft grey shadow along a page's edge is not cropped in")
    func softShadowTrimmed() throws {
        let page = Fixtures.image(1300, 2000) { c in
            for x in 0..<70 {                                    // fades from 60% grey to paper
                c.setFillColor(CGColor(gray: 0.6 + 0.4 * Double(x) / 70, alpha: 1))
                c.fill(CGRect(x: x, y: 0, width: 1, height: 2000))
            }
            AnalysisTests.text(c, 200, 1100, rows: 0..<30)
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.minX > 60.0 / 1300)
        #expect(r.crop.height < 0.6)                             // the text's height, not the page's
    }

    @Test("A wedge of scanner bed beside a turned page is trimmed, its fringe too")
    func wedgeOfBackgroundTrimmed() throws {
        // As on Freudenthal 1999 p19: the page turned on the scanner leaves a
        // wedge of black bed, 7.5% of the width at the top and none at the
        // bottom, edged with a fringe of grey streaks.
        let page = Fixtures.image(1300, 2000) { c in
            for y in 0..<2000 {
                let edge = 98 * (1 - Double(y) / 2200)                  // from the top down
                c.setFillColor(CGColor(gray: 0.02, alpha: 1)); c.fill(CGRect(x: 0, y: Double(1999 - y), width: edge, height: 1))
                for k in stride(from: 0, to: 15, by: 4) where (y / 6 + k) % 3 != 0 {
                    c.setFillColor(CGColor(gray: 0.65, alpha: 1)); c.fill(CGRect(x: edge + Double(k), y: Double(1999 - y), width: 2, height: 1))
                }
            }
            AnalysisTests.text(c, 250, 1100, rows: 0..<30)
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.minX > 200.0 / 1300 && r.crop.minX < 250.0 / 1300, "crop starts at \(r.crop.minX * 1300) px")
        #expect(r.crop.height < 0.6, "crop height \(r.crop.height)")   // the text's height, not the page's
    }

    @Test("A soft grey binding shadow is the gutter, and neither page's crop takes it in")
    func softGutterShadow() {
        let image = Fixtures.image(Self.width, Self.height) { c in
            Self.text(c, 150, 900)
            Self.text(c, 1100, 1850)
            for x in 950..<1050 {                                // 62% grey at the fold, fading out
                let d = abs(Double(x) - 1000) / 50
                c.setFillColor(CGColor(gray: 0.62 + 0.38 * d * d, alpha: 1))
                c.fill(CGRect(x: x, y: 0, width: 1, height: Self.height))
            }
        }
        let r = PageAnalyzer.analyze(cgImage: image)
        #expect(abs(r.splitX - 0.5) < 0.01)
        #expect(r.leftCrop.maxX < 0.485 && r.rightCrop.minX > 0.515)
        #expect(r.leftCrop.height < 0.95 && r.rightCrop.height < 0.95)
    }

    @Test("A dark photograph beside the gutter is not mistaken for the binding shadow")
    func photoIsNotShadow() {
        let image = Fixtures.image(Self.width, Self.height) { c in
            c.setFillColor(CGColor(gray: 0.15, alpha: 1))
            c.fill(CGRect(x: 160, y: 250, width: 750, height: 900))        // a frontispiece reaching the middle
            Self.text(c, 160, 900, rows: 34..<36)                          // its caption
            c.setFillColor(CGColor(gray: 0.55, alpha: 1))
            c.fill(CGRect(x: 999, y: 0, width: 3, height: Self.height))   // the fold: a thin grey line
            Self.text(c, 1100, 1850)
        }
        let r = PageAnalyzer.analyze(cgImage: image)
        #expect(abs(r.splitX - 0.5) < 0.01, "split \(r.splitX)")
    }

    @Test("A binding shadow is still taken as the gutter")
    func shadowGutter() {
        let image = Fixtures.image(Self.width, Self.height) { c in
            Self.text(c, 150, 960)
            Self.text(c, 1080, 1850)
            c.setFillColor(CGColor(gray: 0.3, alpha: 1))
            c.fill(CGRect(x: 1000, y: 0, width: 40, height: Self.height))               // shadow
        }
        let r = PageAnalyzer.analyze(cgImage: image)
        #expect(abs(r.splitX - 0.51) < 0.015)
    }

    @Test("A blank page keeps the book's split, and its crop stays on its own side",
          arguments: [false, true])
    @MainActor
    func blankPage(hairline: Bool) async throws {
        let images = (0..<5).map { i in Self.wallaceSpread(blankLeft: i == 2, hairline: hairline) }
        let media = CGRect(x: 0, y: 0, width: 1000, height: 650)
        let url = Fixtures.writePDF("blank-\(UUID().uuidString).pdf", media: media,
                                    pages: images.map { img in { $0.draw(img, in: media) } })
        let m = testModel()
        m.load(url: url)
        await waitUntilIdle(m)
        let blank = m.pages[2]
        #expect(abs(blank.splitX - m.pages[0].splitX) < 0.02)
        #expect(blank.leftCrop.maxX <= blank.splitX + 0.015)
        #expect(abs(blank.leftCrop.height - m.pages[0].leftCrop.height) < 0.03)   // the usual size
        #expect(blank.rightCrop.minX >= blank.splitX - 0.015)
    }

    @Test("Whole pages too: a blank page keeps the book's split, and both its pages fit it")
    @MainActor
    func blankPageWholePage() async throws {
        let images = (0..<5).map { i in Self.wallaceSpread(blankLeft: i == 2) }
        let media = CGRect(x: 0, y: 0, width: 1000, height: 650)
        let url = Fixtures.writePDF("blankwhole-\(UUID().uuidString).pdf", media: media,
                                    pages: images.map { img in { $0.draw(img, in: media) } })
        let m = testModel()
        m.load(url: url)
        await waitUntilIdle(m)
        m.setCropTarget(.page)
        await waitUntilIdle(m)
        let blank = m.pages[2], split = blank.splitX
        #expect(abs(split - m.pages[0].splitX) < 0.02)
        // The band and streaks end at 0.1375; each page runs to the split.
        #expect(abs(blank.leftCrop.minX - 0.1375) < 0.01 && blank.leftCrop.maxX <= split + 0.001 && blank.leftCrop.maxX > split - 0.01,
                "left \(blank.leftCrop), split \(split)")
        #expect(blank.rightCrop.minX >= split - 0.001 && blank.rightCrop.minX < split + 0.01 && blank.rightCrop.maxX > 0.99,
                "right \(blank.rightCrop), split \(split)")
    }

    @Test("A stray hairline alone is not content; a thin rule or line of text is",
          arguments: [(1, true), (2, true), (3, false), (5, false)])
    func hairline(thickness: Int, blank: Bool) throws {
        // Already at analysis size (800 px tall), so nothing is resampled away.
        let page = Fixtures.image(520, 800) { c in
            c.setFillColor(CGColor(gray: 0.05, alpha: 1))
            c.fill(CGRect(x: 200, y: 400, width: 100, height: thickness))
        }
        let g = try #require(GrayBuffer(cgImage: page))
        #expect(g.height == 800)
        #expect(PageAnalyzer.contentBounds(g, xRange: 0.0..<1.0).blank == blank)
    }

    @Test("One line sticking out past the rest stays inside the crop, on either side")
    func longLineKept() throws {
        let page = Fixtures.image(1300, 2000) { c in
            AnalysisTests.text(c, 300, 1000, rows: 0..<40)           // the text block
            AnalysisTests.text(c, 300, 1150, rows: 12..<13)          // one longer line
            AnalysisTests.text(c, 160, 1000, rows: 30..<31)          // one line set out to the left
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.maxX >= 1150.0 / 1300)
        #expect(r.crop.minX <= 160.0 / 1300)

        // Small type in one half of a spread: wider word gaps, relative to the half.
        let small = Fixtures.image(2000, 1300) { c in
            AnalysisTests.text(c, 300, 800, rows: 0..<30)
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            var x = 300
            while x < 960 { c.fill(CGRect(x: x, y: 600, width: 40, height: 8)); x += 40 + 13 }   // one longer line
        }
        let h = try #require(GrayBuffer(cgImage: small)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<0.5) }
        #expect(h.crop.maxX >= 950.0 / 2000)

        // Tiny type comes out light: its thin strokes are paler than the main ink.
        let light = Fixtures.image(1300, 2000) { c in
            AnalysisTests.text(c, 300, 1000, rows: 0..<40)
            c.setFillColor(CGColor(gray: 0.78, alpha: 1))                // pale strokes, gaps a word wide
            var x = 140
            while x < 300 { c.fill(CGRect(x: x, y: 776, width: 12, height: 9)); x += 12 + 8 }
        }
        let p = try #require(GrayBuffer(cgImage: light)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(p.crop.minX <= 140.0 / 1300)

        // A speck well out in the margin is still not content.
        let specked = Fixtures.image(1300, 2000) { c in
            AnalysisTests.text(c, 300, 1000, rows: 0..<40)
            c.setFillColor(CGColor(gray: 0.1, alpha: 1)); c.fill(CGRect(x: 1180, y: 1000, width: 5, height: 5))
        }
        let s = try #require(GrayBuffer(cgImage: specked)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(s.crop.maxX < 1100.0 / 1300)
    }

    @Test("Shading toward a page's edge and the book block's edge lines are not content")
    func edgeShadingAndForeEdge() throws {
        // Tinted paper darkening over its last 6% toward the right edge.
        let shaded = Fixtures.image(1300, 2000) { c in
            c.setFillColor(CGColor(gray: 0.6, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1300, height: 2000))
            for x in 1222..<1300 {
                c.setFillColor(CGColor(gray: 0.6 - 0.12 * Double(x - 1222) / 78, alpha: 1))
                c.fill(CGRect(x: x, y: 0, width: 1, height: 2000))
            }
            AnalysisTests.text(c, 150, 1150, rows: 0..<30)
        }
        let s = try #require(GrayBuffer(cgImage: shaded)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(s.crop.maxX < 1190.0 / 1300)

        // Blotchy shading, as scanned: mottled, partly dark enough to pass for ink.
        var mottle = SplitMix(seed: 7)
        let blotchy = Fixtures.image(1300, 2000) { c in
            c.setFillColor(CGColor(gray: 0.6, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1300, height: 2000))
            for y in stride(from: 0, to: 2000, by: 6) {
                for x in stride(from: 1190, to: 1300, by: 6) {
                    let depth = Double(x - 1190) / 110
                    c.setFillColor(CGColor(gray: 0.6 - 0.18 * depth * Double.random(in: 0.4...1.2, using: &mottle), alpha: 1))
                    c.fill(CGRect(x: x, y: y, width: 6, height: 6))
                }
            }
            AnalysisTests.text(c, 150, 1150, rows: 0..<30)
        }
        let b = try #require(GrayBuffer(cgImage: blotchy)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(b.crop.maxX < 1190.0 / 1300)

        // Thin grey lines down the left: the edges of the other pages in the book.
        let foreEdge = Fixtures.image(1300, 2000) { c in
            c.setFillColor(CGColor(gray: 0.45, alpha: 1))
            for x in [40, 46, 53, 61] { c.fill(CGRect(x: x, y: 0, width: 2, height: 2000)) }
            AnalysisTests.text(c, 200, 1100, rows: 0..<30)
        }
        let f = try #require(GrayBuffer(cgImage: foreEdge)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(f.crop.minX > 150.0 / 1300)
    }

    @Test("A thin scan-edge line below the text is not content; a footer line and a folio are")
    func scanEdgeLine() throws {
        let page = Fixtures.image(1300, 2000) { c in
            AnalysisTests.text(c, 200, 1100, rows: 0..<30)                      // ends near y = 2000 - 1100
            c.setFillColor(CGColor(gray: 0.2, alpha: 1))
            c.fill(CGRect(x: 100, y: 60, width: 1000, height: 3))                // the scan's edge, low down
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.maxY < 0.92, "bottom \(r.crop.maxY)")   // the text ends at 0.884

        let footer = Fixtures.image(1300, 2000) { c in
            AnalysisTests.text(c, 200, 1100, rows: 0..<30)
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            c.fill(CGRect(x: 300, y: 120, width: 700, height: 14))               // a printer's line at the foot
            c.fill(CGRect(x: 640, y: 60, width: 20, height: 14))                 // and a folio
        }
        let f = try #require(GrayBuffer(cgImage: footer)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(f.crop.maxY > 1 - 60.0 / 2000, "bottom \(f.crop.maxY)")
    }

    @Test("A running foot set off to the side below the text stays inside the crop")
    func runningFootKept() throws {
        let page = Fixtures.image(1300, 2000) { c in
            AnalysisTests.text(c, 500, 1150, rows: -20..<30)                     // a full-height text column, right of center
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            var x = 120
            while x < 440 { c.fill(CGRect(x: x, y: 180, width: 9, height: 14)); x += 9 + 15 }   // letterspaced small caps
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.minX <= 120.0 / 1300, "left \(r.crop.minX)")
        #expect(r.crop.maxY >= 1 - 180.0 / 2000, "bottom \(r.crop.maxY)")
    }

    @Test("Text running into a shadowed page edge keeps its last letters")
    func textIntoShadowedEdge() throws {
        let page = Fixtures.image(1300, 2000) { c in
            c.setFillColor(CGColor(gray: 0.3, alpha: 1)); c.fill(CGRect(x: 1290, y: 0, width: 10, height: 2000))  // the page edge's shadow
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for r in 0..<12 {                                                       // lines of letters running into it
                var x = 150
                while x < 1288 { c.fill(CGRect(x: x, y: 1300 - 140 - r * 32, width: min(7, 1288 - x), height: 9)); x += 7 + 5 }
            }
            AnalysisTests.text(c, 150, 1100, rows: 12..<36)
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.maxX >= 1285.0 / 1300, "right \(r.crop.maxX)")
    }

    @Test("Letters printed over a darkening page edge stay; the bare shadow beyond them doesn't")
    func lettersOverGradient() throws {
        func page(lettersReachEdge: Bool) -> CGImage {
            Fixtures.image(1300, 2000) { c in
                for x in 1240..<1300 {                                              // darkening over the last 5%
                    let d = Double(x - 1240) / 60
                    c.setFillColor(CGColor(gray: 1 - 0.75 * d, alpha: 1)); c.fill(CGRect(x: x, y: 0, width: 1, height: 2000))
                }
                c.setFillColor(CGColor(gray: 0.05, alpha: 1))
                for r in 0..<36 {
                    let end = lettersReachEdge && r < 10 ? 1290 : 1150
                    var x = 150
                    while x < end { c.fill(CGRect(x: x, y: 1300 - 140 - r * 32, width: min(7, end - x), height: 9)); x += 7 + 5 }
                }
            }
        }
        let reach = try #require(GrayBuffer(cgImage: page(lettersReachEdge: true))).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(reach.crop.maxX >= 1285.0 / 1300, "right \(reach.crop.maxX)")
        let bare = try #require(GrayBuffer(cgImage: page(lettersReachEdge: false))).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(bare.crop.maxX < 1240.0 / 1300, "right \(bare.crop.maxX)")
    }

    @Test("Line numbers printed over a steep edge shadow stay; the shadow itself doesn't")
    func lineNumbersOnShadow() throws {
        func page(numbers: Bool) -> CGImage {
            Fixtures.image(1300, 2000) { c in
                for x in 1210..<1300 {                                              // a steep dark edge: paper to 25% grey
                    let d = min(1, Double(x - 1210) / 40)
                    c.setFillColor(CGColor(gray: 1 - 0.75 * d, alpha: 1)); c.fill(CGRect(x: x, y: 0, width: 1, height: 2000))
                }
                AnalysisTests.text(c, 150, 1180, rows: -20..<30)
                guard numbers else { return }
                c.setFillColor(CGColor(gray: 0.02, alpha: 1))
                for r in stride(from: -18, to: 30, by: 5) {                          // "1020"-style numbers on the shadow
                    for k in 0..<4 { c.fill(CGRect(x: 1215 + k * 11, y: 1300 - 140 - r * 32, width: 7, height: 12)) }
                }
            }
        }
        let with = try #require(GrayBuffer(cgImage: page(numbers: true))).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(with.crop.maxX >= 1255.0 / 1300, "right \(with.crop.maxX)")
        let bare = try #require(GrayBuffer(cgImage: page(numbers: false))).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(bare.crop.maxX < 1215.0 / 1300, "right \(bare.crop.maxX)")
    }

    @Test("Scanner noise in a black band is not ink: the crop doesn't follow it across the band")
    func noisyBlackBand() throws {
        // As on Freudenthal 1999: the bed beyond the page is black with specks
        // of 1–15% grey, which pass for ink "darker than its neighbours".
        var rng = SplitMix(seed: 3)
        let page = Fixtures.image(1300, 2000) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 1200, y: 0, width: 100, height: 2000))
            for _ in 0..<6000 {
                c.setFillColor(CGColor(gray: Double(rng.next() % 15 + 1) / 100, alpha: 1))
                c.fill(CGRect(x: 1200 + Int(rng.next() % 100), y: Int(rng.next() % 2000), width: 3, height: 3))
            }
            AnalysisTests.text(c, 150, 1100, rows: 0..<30)
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.maxX < 1200.0 / 1300, "right \(r.crop.maxX * 1300) px")
    }

    @Test("A narrow black binding shadow beside the text is not followed as print")
    func narrowBindingShadow() throws {
        // As on Simon 1990: by the fold the shadow is a black stripe 16 px wide,
        // just past the text, with paper on both sides of it, as a printed rule
        // would have; lower down it widens to the page's edge. Print strokes run
        // a line's height at most; this one runs unbroken for 44% of the page.
        let page = Fixtures.image(1000, 1600) { c in
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for r in 0..<48 {                                                  // letters, to x = 940
                var x = 330
                while x < 940 {
                    let len = 8 + (x * 7 + r * 13) % 14
                    c.fill(CGRect(x: x, y: 40 + r * 32, width: min(len, 940 - x), height: 9)); x += len + 4
                }
            }
            c.setFillColor(CGColor(gray: 0.01, alpha: 1))
            c.fill(CGRect(x: 952, y: 900, width: 16, height: 700))             // upper part: the stripe
            c.fill(CGRect(x: 988, y: 900, width: 12, height: 700))
            c.fill(CGRect(x: 950, y: 0, width: 50, height: 900))               // lower part: black to the edge
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.maxX < 0.958, "right \(r.crop.maxX * 1000) px")
    }

    @Test("A page's crop never reaches past the split into the facing page")
    func cropStaysOnItsSide() throws {
        // Text running right up to the split on both sides.
        let spread = Fixtures.image(Self.width, Self.height) { c in
            Self.text(c, 300, 990)
            Self.text(c, 1010, 1700)
        }
        let g = try #require(GrayBuffer(cgImage: spread))
        #expect(!PageAnalyzer.contentBounds(g, xRange: 0.5..<1.0).blank)
        #expect(PageAnalyzer.contentBounds(g, xRange: 0.0..<0.5).crop.maxX <= 0.5)
        #expect(PageAnalyzer.contentBounds(g, xRange: 0.5..<1.0).crop.minX >= 0.5)

        // A sliver right at the split, narrower than the smallest crop allowed,
        // grows away from the split, not across it. (Short marks: one tall,
        // steady line flush with the edge is the book block's edge, not content.)
        let sliver = Fixtures.image(800, 520) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 360, height: 520))       // scanner band
            for y in stride(from: 220, to: 320, by: 25) { c.fill(CGRect(x: 397, y: y, width: 3, height: 12)) }
        }
        let s = PageAnalyzer.contentBounds(try #require(GrayBuffer(cgImage: sliver)), xRange: 0.0..<0.5)
        #expect(!s.blank && s.crop.maxX <= 0.5 + 1e-9)

        // Even a region narrower than the smallest crop keeps its crop inside it.
        let dot = Fixtures.image(800, 520) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 397, y: 200, width: 3, height: 100))
            c.fill(CGRect(x: 794, y: 200, width: 3, height: 100))
        }
        let gd = try #require(GrayBuffer(cgImage: dot))
        for range in [0.49..<0.5, 0.99..<1.0] {
            let c = PageAnalyzer.contentBounds(gd, xRange: range).crop
            #expect(c.minX >= range.lowerBound - 1e-9 && c.maxX <= range.upperBound + 1e-9)
        }
    }

    @Test("A dark picture near a page edge is content, not a scanner band")
    func darkPictureKept() {
        // A single portrait page: a dark plate starting 2% in, 70% of the height.
        let page = Fixtures.image(1300, 2000) { c in
            c.setFillColor(CGColor(gray: 0.05, alpha: 1))
            c.fill(CGRect(x: 26, y: 300, width: 500, height: 1400))
            AnalysisTests.text(c, 620, 1200, rows: 0..<20)
        }
        let r = PageAnalyzer.analyze(cgImage: page)
        #expect(r.leftCrop.minX < 0.03)           // the plate stays in the crop
    }

    @Test("A lone page number below the text stays inside the crop")
    func pageNumberKept() {
        let page = Fixtures.image(1300, 2000) { c in
            AnalysisTests.text(c, 200, 1100, rows: 0..<40)          // body, top part of the page
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            c.fill(CGRect(x: 640, y: 120, width: 14, height: 24))   // a single-digit folio near the bottom
        }
        let r = PageAnalyzer.analyze(cgImage: page)
        #expect(r.leftCrop.maxY > 1 - 144.0 / 2000)  // reaches down past the folio
    }

    @Test("A real off-center gutter is not overridden by the book's usual split")
    @MainActor
    func realSplitKept() async throws {
        let images = (0..<5).map { i in Self.wallaceSpread(gutter: i == 2 ? 0.66 : 0.52) }
        let media = CGRect(x: 0, y: 0, width: 1000, height: 650)
        let url = Fixtures.writePDF("realsplit-\(UUID().uuidString).pdf", media: media,
                                    pages: images.map { img in { $0.draw(img, in: media) } })
        let m = testModel()
        m.load(url: url)
        await waitUntilIdle(m)
        #expect(abs(m.pages[2].splitX - 0.66) < 0.04)
    }

    @Test("A small page's usual crop still includes what was found on it")
    @MainActor
    func usualCropKeepsContent() async throws {
        // Five spreads; the third's right page holds only a short line low on the page.
        let images = (0..<5).map { i in
            i == 2 ? Fixtures.image(Self.width, Self.height) { c in
                c.setFillColor(CGColor(gray: 0.02, alpha: 1))
                c.fill(CGRect(x: 20, y: 0, width: 220, height: Self.height))
                Self.text(c, 380, 1060)
                Self.text(c, 1300, 1600, rows: 35..<36)               // below the usual text block
            } : Self.wallaceSpread()
        }
        let media = CGRect(x: 0, y: 0, width: 1000, height: 650)
        let url = Fixtures.writePDF("lowline-\(UUID().uuidString).pdf", media: media,
                                    pages: images.map { img in { $0.draw(img, in: media) } })
        let m = testModel()
        m.load(url: url)
        await waitUntilIdle(m)
        let lowLineBottom = Double(140 + 35 * 32 + 9) / Double(Self.height)  // top-left coords
        #expect(m.pages[2].rightCrop.maxY >= lowLineBottom)
    }

    @Test("A nearly empty page gets the book's usual crop, not a sliver")
    @MainActor
    func nearlyEmptyPage() async throws {
        // Five spreads; the third's right page holds only a one-line title.
        let images = (0..<5).map { i in Self.wallaceSpread(titleOnly: i == 2) }
        let media = CGRect(x: 0, y: 0, width: 1000, height: 650)
        let url = Fixtures.writePDF("near-empty-\(UUID().uuidString).pdf", media: media,
                                    pages: images.map { img in { $0.draw(img, in: media) } })
        let m = testModel()
        m.load(url: url)
        await waitUntilIdle(m)
        let usual = m.pages[0].rightCrop
        let title = m.pages[2].rightCrop
        #expect(title.height > usual.height * 0.8)
        #expect(title.width > usual.width * 0.8)
        // Ordinary pages keep their own detected crops.
        #expect(m.pages[1].rightCrop.height > 0.7)
    }

    @Test("Tiny and degenerate images don't crash (Codex GPT-6.1-Sol review)")
    func degenerateImages() throws {
        for (w, h) in [(1, 1), (100, 1), (1, 100), (2, 2), (3, 800)] {
            let g = try #require(GrayBuffer(cgImage: Fixtures.image(w, h)))
            _ = PageAnalyzer.contentBounds(g, xRange: 0.0..<1.0)
            _ = PageAnalyzer.contentBounds(g, xRange: 0.5..<0.5000001)
            _ = PageAnalyzer.detectGutter(g)
            _ = DeskewDetector.detect(Fixtures.image(w, h))
        }
        // Rows pass but no column does: two dots, far apart vertically.
        let dots = Fixtures.image(800, 800) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 300, y: 200, width: 9, height: 1)); c.fill(CGRect(x: 300, y: 600, width: 9, height: 1))
        }
        _ = PageAnalyzer.contentBounds(try #require(GrayBuffer(cgImage: dots)), xRange: 0.0..<1.0)
    }

    @Test("Marginal line numbers and a printed rule stay; a pale grey shadow is not followed")
    func marginsReviewCases() throws {
        // Line numbers in a narrow column of the margin, every few lines.
        let numbered = Fixtures.image(1300, 2000) { c in
            AnalysisTests.text(c, 330, 1150, rows: 0..<30)
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for r in stride(from: 0, to: 30, by: 3) { c.fill(CGRect(x: 160, y: 1300 - 140 - r * 32, width: 16, height: 9)) }
        }
        let n = try #require(GrayBuffer(cgImage: numbered)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(n.crop.minX <= 160.0 / 1300, "left \(n.crop.minX)")

        // A printed rule under a heading, well inside the page.
        let ruled = Fixtures.image(1300, 2000) { c in
            AnalysisTests.text(c, 200, 1100, rows: 4..<30)
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            c.fill(CGRect(x: 200, y: 1300 - 60, width: 900, height: 4))
        }
        let rr = try #require(GrayBuffer(cgImage: ruled)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(rr.crop.minY <= 1 - (1300.0 - 56) / 2000, "top \(rr.crop.minY)")

        // A light grey shadow (paler than ink, darker than paper) beside the text.
        let shaded = Fixtures.image(1300, 2000) { c in
            AnalysisTests.text(c, 150, 975, rows: 0..<30)
            c.setFillColor(CGColor(gray: 0.8, alpha: 1)); c.fill(CGRect(x: 990, y: 0, width: 310, height: 2000))
        }
        let sh = try #require(GrayBuffer(cgImage: shaded)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(sh.crop.maxX < 1050.0 / 1300, "right \(sh.crop.maxX)")
    }

    @Test("A page whose only ink is one outlined box can still be straightened from it")
    func boxOnlyPage() {
        let page = Fixtures.image(1000, 1000) { c in
            c.setStrokeColor(CGColor(gray: 0, alpha: 1)); c.setLineWidth(4)
            c.stroke(CGRect(x: 200, y: 200, width: 600, height: 600))
        }
        let turned = ImageTransform.rotateInPlace(page, degrees: 1.0, pivot: CGPoint(x: 0.5, y: 0.5))
        #expect(abs(DeskewDetector.detect(turned, excludeCenterBand: false) + 1.0) <= 0.15)
    }

    @Test("Dust doesn't pass for marks or a line; a dashed fore-edge streak is still edge (Codex review 2)")
    func dustAndDashedStreak() throws {
        func page(_ draw: (CGContext) -> Void) -> CGImage {
            Fixtures.image(800, 800) { c in
                c.setFillColor(CGColor(gray: 0.1, alpha: 1))
                for y in stride(from: 100, to: 700, by: 20) { c.fill(CGRect(x: 300, y: 800 - y - 8, width: 300, height: 8)) }   // text
                draw(c)
            }
        }
        // Two flecks in a trimmed shadow.
        let flecks = page { c in
            c.setFillColor(CGColor(gray: 100.0 / 255, alpha: 1)); c.fill(CGRect(x: 760, y: 0, width: 40, height: 800))
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 790, y: 800 - 203, width: 1, height: 3)); c.fill(CGRect(x: 790, y: 800 - 303, width: 1, height: 3))
        }
        let f = PageAnalyzer.contentBounds(try #require(GrayBuffer(cgImage: flecks)), xRange: 0.0..<1.0)
        #expect(f.crop.maxX < 0.8, "right \(f.crop.maxX)")
        // A small dust patch between lines, off to the side.
        let patch = page { c in c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 100, y: 800 - 113, width: 9, height: 3)) }
        let p = PageAnalyzer.contentBounds(try #require(GrayBuffer(cgImage: patch)), xRange: 0.0..<1.0)
        #expect(p.crop.minX > 0.3, "left \(p.crop.minX)")
        // A dashed streak down the left: the book block's edge, broken up.
        let dashed = page { c in
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for y in stride(from: 100, to: 700, by: 30) { c.fill(CGRect(x: 50, y: 800 - y - 20, width: 2, height: 20)) }
        }
        let d = PageAnalyzer.contentBounds(try #require(GrayBuffer(cgImage: dashed)), xRange: 0.0..<1.0)
        #expect(d.crop.minX > 0.3, "left \(d.crop.minX)")
    }

    @Test("A gutter shadow with a ragged edge is not cropped in")
    func raggedGutterShadow() throws {
        // As on Simon 1990 (pp. 82–83): the right page's gutter shadow is black
        // and widens down the page; its edge is ragged, each row ending anywhere
        // in 16 px, so the columns there thin out from solid to paper. Too thin
        // to trim as part of the shadow and too wide to be the book block's
        // edge, they were taken for the ends of lines. The text starts 6 px past
        // the last of them.
        var rng = SplitMix(seed: 11)
        let page = Fixtures.image(400, 600) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for y in 0..<600 {
                let edge = 10 + 10 * y / 599 + Int(rng.next() % 16)           // shadow: x = 2 ..< edge
                c.fill(CGRect(x: 2, y: 599 - y, width: edge - 2, height: 1))
            }
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for r in 0..<28 {                                                  // letters from x = 42
                var x = 42
                while x < 380 {
                    let len = 5 + (x * 7 + r * 13) % 9
                    c.fill(CGRect(x: x, y: 20 + r * 20, width: min(len, 380 - x), height: 9)); x += len + 3
                }
            }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.minX > 36.0 / 400, "left \(r.crop.minX * 400) px")    // 42 px, less the padding
    }

    @Test("A spiral binding's loops down the gutter are not cropped in")
    func spiralBinding() {
        // As on Oesterle 1955: dark loops 34 px tall every 80 px, straddling a
        // black fold 20 px wide, each paler near its ends where it catches the light, and
        // darker again at its rims.
        let image = Fixtures.image(Self.width, Self.height) { c in
            Self.text(c, 150, 900)
            Self.text(c, 1110, 1850)
            c.setFillColor(CGColor(gray: 0.05, alpha: 1)); c.fill(CGRect(x: 990, y: 0, width: 20, height: Self.height))
            for y in stride(from: 10, to: Self.height, by: 80) {
                c.setFillColor(CGColor(gray: 0.3, alpha: 1)); c.fill(CGRect(x: 945, y: y + 2, width: 6, height: 30))
                c.setFillColor(CGColor(gray: 0.5, alpha: 1)); c.fill(CGRect(x: 951, y: y, width: 20, height: 34))
                c.setFillColor(CGColor(gray: 0.25, alpha: 1)); c.fill(CGRect(x: 971, y: y, width: 58, height: 34))
                c.setFillColor(CGColor(gray: 0.5, alpha: 1)); c.fill(CGRect(x: 1029, y: y, width: 20, height: 34))
                c.setFillColor(CGColor(gray: 0.3, alpha: 1)); c.fill(CGRect(x: 1049, y: y + 2, width: 6, height: 30))
            }
        }
        let r = PageAnalyzer.analyze(cgImage: image)
        #expect(abs(r.splitX - 0.5) < 0.01, "split \(r.splitX)")
        #expect(r.leftCrop.maxX < 0.465, "left page ends at \(r.leftCrop.maxX)")      // text ends at 0.45; loops from 0.4725
        #expect(r.rightCrop.minX > 0.535, "right page starts at \(r.rightCrop.minX)")  // loops end at 0.5275; text from 0.555
        #expect(r.leftCrop.height < 0.95 && r.rightCrop.height < 0.95)
    }

    @Test("A narrow picture by the edge, inside the page, is not taken for a wedge of scanner bed (Codex review 3)")
    func pictureByEdgeKept() throws {
        // A black block 20 px wide, 10 px in from the edge, 100–220 px from the
        // top; text below it. Its edge is as steady as a wedge's, but it has
        // paper above and below: a wedge of bed runs on from a corner of the scan.
        let page = Fixtures.image(520, 800) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 10, y: 800 - 220, width: 20, height: 120))
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for y in stride(from: 250, to: 690, by: 16) { c.fill(CGRect(x: 150, y: 800 - y - 8, width: 320, height: 8)) }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.minX < 10.0 / 520, "left \(r.crop.minX * 520) px")
        #expect(r.crop.minY < 100.0 / 800, "top \(r.crop.minY * 800) px")
    }

    @Test("Print over a dark edge shadow stays: tall strokes, and black on a near-black shadow (Codex review 3)",
          arguments: [(0.475, 40), (0.133, 10)])
    func printOverDarkShadow(shade: Double, strokeHeight: Int) throws {
        // A shadow 40 px wide down the right edge, grey `shade` (140 and 45 of
        // 255 once drawn); strokes of a heading 2 px wide run from the text over
        // it, `strokeHeight` px tall.
        let page = Fixtures.image(520, 800, gray: true) { c in
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for y in stride(from: 250, to: 690, by: 16) { c.fill(CGRect(x: 150, y: 800 - y - 8, width: 320, height: 8)) }
            c.setFillColor(CGColor(gray: shade, alpha: 1)); c.fill(CGRect(x: 480, y: 0, width: 40, height: 800))
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for x in stride(from: 470, through: 510, by: 5) { c.fill(CGRect(x: x, y: 800 - 300 - strokeHeight, width: 2, height: strokeHeight)) }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.maxX >= 510.0 / 520, "right \(r.crop.maxX * 520) px")
    }

    /// Lines of words on a 520 × 800 page, between x0 and x1, from 60 px down.
    static func words(_ c: CGContext, _ x0: Int, _ x1: Int, rows: Range<Int> = 0..<34) {
        c.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for r in rows {
            var x = x0
            while x < x1 {
                let len = 6 + (x * 7 + r * 13) % 12
                c.fill(CGRect(x: x, y: 800 - 60 - r * 20 - 8, width: min(len, x1 - x), height: 8)); x += len + 4
            }
        }
    }

    @Test("The fold's line is not cropped in, though its head spreads at the top of the scan")
    func foldWithSmudgedHead() throws {
        // As on Freudenthal 1999: the fold is a grey line 30 px in from the
        // split, spreading at the top of the scan into a smudge 25 px wide.
        let page = Fixtures.image(520, 800) { c in
            Self.words(c, 60, 440)
            c.setFillColor(CGColor(gray: 0.45, alpha: 1)); c.fill(CGRect(x: 489, y: 0, width: 2, height: 800))
            for y in 0..<24 { let half = (24 - y) * 12 / 24; c.fill(CGRect(x: 490 - half, y: 799 - y, width: 2 * half + 1, height: 1)) }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.maxX < 460.0 / 520, "right \(r.crop.maxX * 520) px")   // the text ends at 440
        #expect(r.crop.minY > 40.0 / 800, "top \(r.crop.minY * 800) px")
    }

    @Test("A corner of scanner bed at the top of the scan doesn't stretch the crop up")
    func bedCornerAtTop() throws {
        // As on Freudenthal 1999 p. 195: black bed down the right edge, and at
        // the top of the scan a wedge of it reaching 15 px further in, from
        // row 4 to row 23, past the text's right edge.
        let page = Fixtures.image(520, 800) { c in
            Self.words(c, 60, 460)
            c.setFillColor(CGColor(gray: 0.05, alpha: 1))
            c.fill(CGRect(x: 505, y: 0, width: 15, height: 800))
            for y in 4..<24 { c.fill(CGRect(x: 490 + (y - 4) * 3 / 4, y: 799 - y, width: 505 - 490 - (y - 4) * 3 / 4, height: 1)) }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.minY > 40.0 / 800, "top \(r.crop.minY * 800) px")       // the text starts at 60
        #expect(r.crop.maxX < 480.0 / 520, "right \(r.crop.maxX * 520) px")    // and ends at 460
    }

    @Test("A wide band of scanner bed, slanted by straightening, is not cropped in")
    func wideSlantedBed() throws {
        // As on Freudenthal 1999 p. 180, straightened 3.5°: black bed 22–40 px
        // wide down the page, then 20 px of grey shadow, the turn's white corner
        // below; 8% of the width at the top, 13% at the foot.
        let page = Fixtures.image(520, 800) { c in
            for y in 10..<800 {
                let corner = y > 420 ? (y - 420) * 22 / 380 : 0, edge = 22 + 18 * y / 800
                c.setFillColor(CGColor(gray: 0.05, alpha: 1)); c.fill(CGRect(x: corner, y: 799 - y, width: edge - corner + corner / 2, height: 1))
                c.setFillColor(CGColor(gray: 0.6, alpha: 1)); c.fill(CGRect(x: edge + corner / 2, y: 799 - y, width: 20, height: 1))
                c.setFillColor(CGColor(gray: 0.82, alpha: 1)); c.fill(CGRect(x: edge + corner / 2 + 20, y: 799 - y, width: 7, height: 1))
            }
            Self.words(c, 150, 480)
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.minX > 130.0 / 520, "left \(r.crop.minX * 520) px")    // the text starts at 150
        #expect(r.crop.maxY < 760.0 / 800, "bottom \(r.crop.maxY * 800) px")  // and ends at 728
    }

    /// Lines of words on a page `h` px tall, between x0 and x1 and from y0 to
    /// y1 (from the top), a line every 16 px.
    static func body(_ c: CGContext, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, h: Int = 800) {
        c.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for (r, y) in stride(from: y0, to: y1 - 8, by: 16).enumerated() {
            var x = x0
            while x < x1 {
                let len = 6 + (x * 7 + r * 13) % 12
                c.fill(CGRect(x: x, y: h - y - 8, width: min(len, x1 - x), height: 8)); x += len + 4
            }
        }
    }

    @Test("A running head or folio near the scan's top or bottom stays, even outside the text's columns (Codex review 4)")
    func headAndFolioNearScanEdge() throws {
        // Two glyphs 18 px from the top, left of the text block.
        let head = Fixtures.image(520, 800) { c in
            Self.body(c, 150, 439, 100, 687)
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for x in [80, 92] { c.fill(CGRect(x: x, y: 800 - 18 - 10, width: 8, height: 10)) }
        }
        let h = try #require(GrayBuffer(cgImage: head)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(h.crop.minX <= 80.0 / 520 && h.crop.minY <= 18.0 / 800, "\(h.crop)")
        // A folio 13 px from the foot, left of a narrow text block.
        let foot = Fixtures.image(520, 800) { c in
            Self.body(c, 300, 449, 100, 687)
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 250, y: 800 - 788, width: 20, height: 10))
        }
        let f = try #require(GrayBuffer(cgImage: foot)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(f.crop.maxY >= 787.0 / 800 && f.crop.minX <= 250.0 / 520, "\(f.crop)")
    }

    @Test("Marks set at a steady pitch in the margin are not taken for a binding (Codex review 4)")
    func regularMarginMarks() throws {
        // Ten solid dashes 22 × 8 px, 8 px from the edge, every 70 px.
        let page = Fixtures.image(520, 800) { c in
            Self.body(c, 150, 439, 100, 687)
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for y in stride(from: 60, through: 690, by: 70) { c.fill(CGRect(x: 8, y: 800 - y - 8, width: 22, height: 8)) }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.minX <= 8.0 / 520, "left \(r.crop.minX * 520) px")
    }

    @Test("Line numbers in the inner and outer margins of a spread stay, beside a fold")
    func marginalNumbersOnSpread() {
        // Bekker-style numbers ("5", "10", "15", ...) every fifth line, in both
        // margins of both pages; a grey fold down the middle.
        func number(_ c: CGContext, _ x: Int, _ y: Int, _ n: Int) {
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            var x = x
            for d in String(n) {
                let top = Self.height - y - 22
                switch d {
                case "1": c.fill(CGRect(x: x + 4, y: top, width: 3, height: 22))
                case "0": c.stroke(CGRect(x: x + 1, y: top + 1, width: 9, height: 20))
                default:                                                       // "5": three bars and two sides
                    c.fill(CGRect(x: x, y: top + 19, width: 11, height: 3)); c.fill(CGRect(x: x, y: top + 10, width: 11, height: 3))
                    c.fill(CGRect(x: x, y: top, width: 11, height: 3))
                    c.fill(CGRect(x: x, y: top + 10, width: 3, height: 12)); c.fill(CGRect(x: x + 8, y: top, width: 3, height: 12))
                }
                x += 14
            }
        }
        let image = Fixtures.image(Self.width, Self.height) { c in
            c.setStrokeColor(CGColor(gray: 0.1, alpha: 1)); c.setLineWidth(3)
            Self.text(c, 300, 900)
            Self.text(c, 1100, 1700)
            c.setFillColor(CGColor(gray: 0.55, alpha: 1)); c.fill(CGRect(x: 999, y: 0, width: 3, height: Self.height))
            for (i, r) in stride(from: 4, to: 34, by: 5).enumerated() {
                let y = 140 + r * 32 - 6, n = 5 * (i + 1)
                number(c, 200, y, n); number(c, 935, y, n)                    // left page: outer, inner
                number(c, 1030, y, n); number(c, 1740, y, n)                  // right page: inner, outer
            }
        }
        let r = PageAnalyzer.analyze(cgImage: image)
        #expect(abs(r.splitX - 0.5) < 0.01, "split \(r.splitX)")
        #expect(r.leftCrop.minX <= 200.0 / 2000 && r.leftCrop.maxX >= 963.0 / 2000, "left \(r.leftCrop)")
        #expect(r.rightCrop.minX <= 1030.0 / 2000 && r.rightCrop.maxX >= 1768.0 / 2000, "right \(r.rightCrop)")
    }

    @Test("A dark picture at a slant, with paper above and below, is not taken for scanner bed (Codex review 4)")
    func slantedPictureKept() throws {
        let page = Fixtures.image(520, 800) { c in
            Self.body(c, 150, 439, 100, 687)
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for y in 72...727 { c.fill(CGRect(x: 10, y: 799 - y, width: 50 + 35 * y / 800, height: 1)) }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.minX <= 10.0 / 520, "left \(r.crop.minX * 520) px")
    }

    @Test("A heading's tall strokes over a shadow stay when a short stroke shares their columns (Codex review 4)")
    func tallAndShortStrokesOverShadow() throws {
        let page = Fixtures.image(520, 800, gray: true) { c in
            Self.body(c, 150, 439, 100, 687)
            c.setFillColor(CGColor(gray: 0.475, alpha: 1)); c.fill(CGRect(x: 480, y: 0, width: 40, height: 800))   // 140 of 255
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for x in stride(from: 450, through: 510, by: 5) {
                c.fill(CGRect(x: x, y: 800 - 300 - 40, width: 2, height: 40))
                c.fill(CGRect(x: x, y: 800 - 400 - 8, width: 2, height: 8))
            }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.maxX >= 510.0 / 520, "right \(r.crop.maxX * 520) px")
    }

    @Test("Marks at a steady pitch in the inner margin are not taken for a binding (Codex review 5)",
          arguments: [(1040, 528, 22, 16), (1040, 528, 22, 20), (1040, 528, 22, 24), (1040, 532, 4, 16), (800, 408, 22, 16), (800, 410, 4, 16)])
    func innerMarginMarks(width: Int, x: Int, markWidth: Int, markHeight: Int) throws {
        // The right page of a spread: blocks or strokes ("I") every 70 px, a few
        // pixels from the gutter, nothing between them.
        let page = Fixtures.image(width, 800) { c in
            Self.body(c, width / 2 + 150, width - 70, 100, 700)
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for y in stride(from: 60, to: 760, by: 70) { c.fill(CGRect(x: x, y: 800 - y - markHeight, width: markWidth, height: markHeight)) }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.5..<1.0) }
        #expect(r.crop.minX * Double(width) <= Double(x), "left \(r.crop.minX * Double(width)) px")
    }

    @Test("A glyph near the page's side in the scan's top 4% stays (Codex review 5)", arguments: [4, 8])
    func glyphNearSideAtTop(x: Int) throws {
        let page = Fixtures.image(520, 800) { c in
            Self.body(c, 150, 439, 100, 687)
            c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: x, y: 800 - 18 - 10, width: 8, height: 10))
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.minX * 520 <= Double(x) && r.crop.minY * 800 <= 18, "\(r.crop)")
    }

    @Test("A folio two or three rows thin, off to the side at the foot, stays (Codex review 5)", arguments: [2, 3])
    func thinFolioAtFoot(height: Int) throws {
        let page = Fixtures.image(520, 800) { c in
            Self.body(c, 300, 460, 100, 687)
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for x in [250, 262] { c.fill(CGRect(x: x, y: 800 - 778 - height, width: 8, height: height)) }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(r.crop.maxY * 800 >= Double(778 + height) && r.crop.minX * 520 <= 250, "\(r.crop)")
    }

    /// Text in Times set as a 110-dpi scan would show it at analysis size,
    /// its ink's top-left corner at (x, y) from the page's top-left.
    static func glyphs(_ c: CGContext, _ text: String, x: Int, y: Int, pt: Double, pageHeight: Int) {
        let scratch = CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        scratch.setFillColor(gray: 1, alpha: 1); scratch.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        let font = CTFontCreateWithName("Times-Roman" as CFString, pt * 110 / 72 * 800 / 1210, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        scratch.textPosition = CGPoint(x: 10, y: 30); CTLineDraw(line, scratch)
        let image = scratch.makeImage()!, g = GrayBuffer(cgImage: image, maxDim: 400)!
        let xs = (0..<400).filter { xx in (0..<100).contains { g.value(xx, $0) < 191 } }
        let ys = (0..<100).filter { yy in (0..<400).contains { g.value($0, yy) < 191 } }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(),
              let ink = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)) else { return }
        c.saveGState(); c.setBlendMode(.multiply)
        c.draw(ink, in: CGRect(x: x, y: pageHeight - y - ink.height, width: ink.width, height: ink.height))
        c.restoreGState()
    }

    /// Words as grey boxes, 10 × 8 px every 14 px, a line every 20 px from y = 100.
    static func boxes(_ c: CGContext, _ x0: Int, _ x1: Int, pageHeight: Int = 800) {
        c.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for y in stride(from: 100, to: 700, by: 20) {
            for x in stride(from: x0, to: x1 - 8, by: 14) { c.fill(CGRect(x: x, y: pageHeight - y - 8, width: min(10, x1 - x), height: 8)) }
        }
    }

    @Test("Print at the scan's very edge stays: a running head touching the side, a folio on the first row (Codex review 6)")
    func printAtScanEdge() throws {
        let head = Fixtures.image(520, 800, gray: true) { c in
            Self.boxes(c, 150, 450); Self.glyphs(c, "HISTORY", x: 0, y: 18, pt: 12, pageHeight: 800)
        }
        let h = try #require(GrayBuffer(cgImage: head)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(h.crop.minX * 520 <= 1 && h.crop.minY * 800 <= 18, "running head: \(h.crop)")
        let folio = Fixtures.image(520, 800, gray: true) { c in
            Self.boxes(c, 300, 460); Self.glyphs(c, "123", x: 320, y: 0, pt: 6, pageHeight: 800)
        }
        let f = try #require(GrayBuffer(cgImage: folio)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.0..<1.0) }
        #expect(f.crop.minY * 800 <= 1, "folio: \(f.crop)")
    }

    @Test("Numbers beside a printed rule in the inner margin stay (Codex review 6)", arguments: ["123", "III"])
    func numbersBesideRule(text: String) throws {
        // The right page of a spread: a 1-px rule down the inner margin, and
        // numbers left of it every 70 px from the top.
        let page = Fixtures.image(800, 800, gray: true) { c in
            Self.boxes(c, 550, 750)
            c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 420, y: 800 - 760, width: 1, height: 720))
            for y in stride(from: 60, to: 760, by: 70) { Self.glyphs(c, text, x: 408, y: y, pt: 12, pageHeight: 800) }
        }
        let r = try #require(GrayBuffer(cgImage: page)).pipe { PageAnalyzer.contentBounds($0, xRange: 0.5..<1.0) }
        #expect(r.crop.minX * 800 <= 408 && r.crop.minY * 800 <= 60, "\(r.crop)")
    }

    /// A grey page drawn pixel by pixel, at its own size (no resampling).
    static func pixels(_ w: Int, _ h: Int, _ draw: (inout Pixels) -> Void) -> GrayBuffer {
        var p = Pixels(w: w, h: h, v: [UInt8](repeating: 255, count: w * h))
        draw(&p)
        let provider = CGDataProvider(data: Data(p.v) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return GrayBuffer(cgImage: image, maxDim: max(w, h))!
    }
    struct Pixels {
        let w: Int, h: Int
        var v: [UInt8]
        mutating func box(_ x: Int, _ y: Int, _ bw: Int, _ bh: Int, _ value: UInt8 = 0) {
            for yy in max(0, y)..<min(h, y + bh) { for xx in max(0, x)..<min(w, x + bw) { v[yy * w + xx] = value } }
        }
        /// Words: grey boxes 10 × 8 every 14 px, a line every 20 px from y = 100 to 700.
        mutating func body(_ x0: Int, _ x1: Int) {
            for y in stride(from: 100, to: 700, by: 20) { for x in stride(from: x0, to: x1 - 8, by: 14) { box(x, y, min(10, x1 - x), 8, 25) } }
        }
    }

    @Test("Print a pixel or two from the scanner bed stays: a running head, a folio (review 7, Grok and orchestrator cases)")
    func printBesideBed() throws {
        // The bed down the left edge, a head 2 px past it at the top.
        let head = Self.pixels(520, 800) { p in
            p.box(0, 0, 34, 800); for x in [36, 46, 56, 66] { p.box(x, 4, 8, 12) }; p.body(200, 470)
        }
        let h = PageAnalyzer.contentBounds(head, xRange: 0.0..<1.0).crop
        #expect(h.minX * 520 <= 36 && h.minY * 800 <= 4, "head: \(h)")
        // The bed down the right edge, a folio 1 px short of it at the foot.
        let foot = Self.pixels(520, 800) { p in
            p.body(60, 340); p.box(470, 772, 8, 12); p.box(480, 772, 8, 12); p.box(489, 0, 31, 800)
        }
        let f = PageAnalyzer.contentBounds(foot, xRange: 0.0..<1.0).crop
        #expect(f.maxX * 520 >= 487 && f.maxY * 800 >= 783, "folio: \(f)")
    }

    @Test("A running head past a book-block streak stays (review 7, Grok and orchestrator cases)")
    func headPastStreak() throws {
        let page = Self.pixels(520, 800) { p in
            p.box(22, 200, 1, 300); for x in [64, 74, 84] { p.box(x, 2, 8, 10) }; p.body(260, 480)
        }
        let r = PageAnalyzer.contentBounds(page, xRange: 0.0..<1.0).crop
        #expect(r.minX * 520 <= 64 && r.minY * 800 <= 2, "\(r)")
    }

    @Test("A dotted rule in the margin near the scan's top stays (review 7, Grok and orchestrator cases)")
    func dottedRuleInMargin() throws {
        let page = Self.pixels(520, 800) { p in
            p.body(280, 480); for x in stride(from: 20, to: 160, by: 9) { p.box(x, 10, 8, 3) }
        }
        let r = PageAnalyzer.contentBounds(page, xRange: 0.0..<1.0).crop
        #expect(r.minX * 520 <= 20 && r.minY * 800 <= 10, "\(r)")
    }

    @Test("A thin diagonal printed rule stays (review 7, Grok and orchestrator cases)")
    func diagonalRule() throws {
        let page = Self.pixels(520, 800) { p in
            p.body(150, 470); for y in 50..<750 { p.box(36 + (y - 50) * 28 / 700, y, 2, 1) }
        }
        let r = PageAnalyzer.contentBounds(page, xRange: 0.0..<1.0).crop
        #expect(r.minX * 520 <= 36, "\(r)")
    }

    @Test("Blocks in the inner margin beside a fold or a printed rule are not a binding (review 7, Grok and orchestrator cases)", arguments: [6, 3])
    func blocksBesideFold(foldWidth: Int) throws {
        // The right page of a spread: a fold (or a rule) by the split, solid
        // blocks every 70 px a few pixels past it.
        let page = Self.pixels(1040, 800) { p in
            p.body(700, 980); p.box(518 - foldWidth, 0, foldWidth, 800)
            for y in stride(from: 40, to: 750, by: 70) { p.box(528, y, 22, 22) }
        }
        let r = PageAnalyzer.contentBounds(page, xRange: 0.5..<1.0).crop
        #expect(r.minX * 1040 <= 528, "\(r)")
    }

    @Test("A brace beside a gutter shadow's ragged edge is not trimmed with it (review 7, Grok and orchestrator cases)")
    func braceBesideShadow() throws {
        let page = Self.pixels(1040, 800) { p in
            p.box(520, 0, 30, 800); for x in 550..<560 { p.box(x, 0, 1, 72) }
            p.box(560, 300, 3, 80); p.body(700, 980)
        }
        let r = PageAnalyzer.contentBounds(page, xRange: 0.5..<1.0).crop
        #expect(r.minX * 1040 <= 560, "\(r)")
    }

    @Test("Any page and any region: no crash, and the crop stays inside its region")
    func randomPages() throws {
        var rng = SplitMix(seed: 42)
        for _ in 0..<300 {
            let w = Int.random(in: 1...1400, using: &rng), h = Int.random(in: 1...1400, using: &rng)
            let page = Fixtures.image(w, h) { c in
                if Bool.random(using: &rng) {                                  // tinted paper
                    c.setFillColor(CGColor(gray: Double.random(in: 0.5...0.95, using: &rng), alpha: 1))
                    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
                }
                for _ in 0..<Int.random(in: 0...6, using: &rng) {             // blocks, bands, streaks, specks
                    c.setFillColor(CGColor(gray: Double.random(in: 0...0.8, using: &rng), alpha: 1))
                    let bw = Int.random(in: 1...max(1, w / 2), using: &rng), bh = Int.random(in: 1...h, using: &rng)
                    c.fill(CGRect(x: Int.random(in: -bw...w, using: &rng), y: Int.random(in: -bh...h, using: &rng), width: bw, height: bh))
                }
                for row in 0..<Int.random(in: 0...40, using: &rng) {           // lines of "text"
                    let x0 = Int.random(in: 0...w, using: &rng)
                    c.setFillColor(CGColor(gray: 0.1, alpha: 1))
                    c.fill(CGRect(x: x0, y: h - 20 - row * 14, width: Int.random(in: 1...w, using: &rng), height: 6))
                }
            }
            let g = try #require(GrayBuffer(cgImage: page))
            let a = Double.random(in: 0...0.999, using: &rng), b = Double.random(in: (a + 0.0001)...1, using: &rng)
            let r = PageAnalyzer.contentBounds(g, xRange: a..<b)
            if b - a >= 0.02 {
                #expect(r.crop.minX >= a - 1e-9 && r.crop.maxX <= b + 1e-9, "\(r.crop) in \(a)..<\(b), \(w)x\(h)")
            }
            #expect(r.crop.minY >= -1e-9 && r.crop.maxY <= 1 + 1e-9)
            _ = PageAnalyzer.analyze(cgImage: page)
            _ = AppModel.detectSkews(page, splitX: Double.random(in: 0.01...0.99, using: &rng), isSpread: w > h)
        }
    }
}

/// A small seeded random number generator, so a failing case can be rerun.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
