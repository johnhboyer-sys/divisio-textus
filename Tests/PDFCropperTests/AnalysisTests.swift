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
    static func wallaceSpread(gutter: Double = 0.57, titleOnly: Bool = false, blankLeft: Bool = false) -> CGImage {
        Fixtures.image(width, height) { c in
            c.setFillColor(CGColor(gray: 0.02, alpha: 1))
            c.fill(CGRect(x: 20, y: 0, width: 220, height: height))                    // black band
            for x in stride(from: 240, to: 275, by: 4) {                               // ragged streaks
                c.fill(CGRect(x: x, y: 0, width: 2, height: height))
            }
            let g = Int(gutter * Double(width))
            if !blankLeft {
                text(c, 380, g - 80)                                                   // left page
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

    @Test("A blank page keeps the book's split, and its crop stays on its own side")
    @MainActor
    func blankPage() async throws {
        let images = (0..<5).map { i in Self.wallaceSpread(blankLeft: i == 2) }
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
}
