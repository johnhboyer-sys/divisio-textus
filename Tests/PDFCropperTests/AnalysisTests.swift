import Testing
import Foundation
import PDFKit
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
