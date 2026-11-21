import Testing
import Foundation
import CoreGraphics
@testable import PDFCropper

/// Remove shadows: beside the text block, what is not print goes (streaks, ticks,
/// specks, a broken fold line, a remnant on the side) and print stays (a folio, a
/// footnote marker, a word reaching past the block's edge, the text itself).
@Suite("BW fold sides")
struct BWFoldTests {
    static let w = 900, h = 1200, dpi = 300.0

    /// Pixels of a w × h box at (x, y).
    static func box(_ x: Int, _ y: Int, _ bw: Int, _ bh: Int) -> [Int] {
        var px: [Int] = []
        for yy in y..<(y + bh) { for xx in x..<(x + bw) where xx >= 0 && xx < w && yy >= 0 && yy < h { px.append(yy * w + xx) } }
        return px
    }

    /// An "o" (20 × 22, 3-pixel strokes) and an "l" (3 × 30) with their top-left at (x, y).
    static func pair(_ x: Int, _ y: Int) -> [Int] {
        box(x, y + 8, 3, 22) + box(x + 17, y + 8, 3, 22) + box(x, y + 8, 20, 3) + box(x, y + 27, 20, 3) + box(x + 28, y, 3, 30)
    }

    struct Page {
        var out = [UInt8](repeating: 255, count: BWFoldTests.w * BWFoldTests.h)
        var text: [Int] = [], keep: [Int] = [], junk: [Int] = []
        mutating func ink(_ px: [Int]) { for i in px { out[i] = 0 } }
    }

    /// 20 lines of text from x 150 to 675; the fold on the right at x 900.
    static func page() -> Page {
        var p = Page()
        for line in 0..<20 {
            let y = 100 + line * 50
            for x in stride(from: 150, to: 660, by: 45) { p.text += pair(x, y) }
        }
        p.ink(p.text)
        return p
    }

    private func share(_ out: [UInt8], _ px: [Int]) -> Double {
        Double(px.filter { out[$0] == 0 }.count) / Double(max(1, px.count))
    }

    @Test("A streak, ticks, specks and a remnant on the side go; text stays")
    func junkGoes() {
        var p = Self.page()
        p.junk += Self.box(860, 80, 3, 1020)                                       // a streak
        for y in [150, 400, 650, 900] { p.junk += Self.box(820, y, 2, 14) }         // ticks
        for y in [300, 550, 800] { p.junk += Self.box(800, y, 3, 12) }
        var rng = HCRandom(5)
        for _ in 0..<40 { p.junk += Self.box(rng.int(720, 850), rng.int(60, 1100), 2, 2) }   // specks
        p.junk += Self.box(893, 500, 7, 60)                                         // a remnant on the side
        p.ink(p.junk)
        #expect(ShadowRemoval.clearSides(&p.out, Self.w, Self.h, dpi: Self.dpi))
        #expect(share(p.out, p.junk) == 0, "\(share(p.out, p.junk))")
        #expect(share(p.out, p.text) == 1)
    }

    @Test("A folio, a footnote marker and a word reaching past the block stay")
    func printStays() {
        var p = Self.page()
        p.keep += Self.box(800, 1150, 5, 30)                                        // folio "10": the 1
        p.keep += Self.box(812, 1150, 20, 4) + Self.box(812, 1176, 20, 4)           // the 0
            + Self.box(812, 1150, 4, 30) + Self.box(828, 1150, 4, 30)
        p.keep += Self.box(690, 300, 5, 13)                                         // a marker after line 5
        p.keep += Self.pair(60, 600) + Self.pair(105, 600)                          // a word left of the block
        p.junk += Self.box(860, 80, 3, 1020)
        p.ink(p.keep + p.junk)
        ShadowRemoval.clearSides(&p.out, Self.w, Self.h, dpi: Self.dpi)
        #expect(share(p.out, p.keep) == 1, "\(share(p.out, p.keep))")
        #expect(share(p.out, p.text) == 1)
        #expect(share(p.out, p.junk) == 0)
    }

    @Test("A broken fold line next to the text goes; the text stays")
    func brokenLineByText() {
        var p = Self.page()
        for y in stride(from: 100, to: 1100, by: 34) { p.junk += Self.box(700, y, 2, 24) }
        p.ink(p.junk)
        ShadowRemoval.clearSides(&p.out, Self.w, Self.h, dpi: Self.dpi)
        #expect(share(p.out, p.junk) == 0, "\(share(p.out, p.junk))")
        #expect(share(p.out, p.text) == 1)
    }

    @Test("Review 2: a lone narrow folio 1 below the block, beside it, stays")
    func loneNarrowFolio() {
        var p = Self.page()
        p.keep += Self.box(800, 1150, 3, 20)
        p.ink(p.keep)
        ShadowRemoval.clearSides(&p.out, Self.w, Self.h, dpi: Self.dpi)
        #expect(share(p.out, p.keep) == 1)
        #expect(share(p.out, p.text) == 1)
    }

    /// A crease on such a page can't be told from a printed rule or bracket reliably
    /// (see `sparsePageRules`), so it stays: losing print is worse than a mark.
    @Test("Review 5: on a page of two lines nothing is cleared; the lines and a printed frame stay")
    func sparsePageCrease() {
        var p = Page()
        for line in 0..<2 { for x in stride(from: 150, to: 660, by: 45) { p.text += Self.pair(x, 500 + line * 50) } }
        p.ink(p.text)
        p.junk += Self.box(838, 0, 3, Self.h)                                       // the crease, 0.2 inch in
        // A printed frame near the other side: a box of 2-pixel rules.
        p.keep += Self.box(20, 300, 2, 400) + Self.box(110, 300, 2, 400) + Self.box(20, 300, 92, 2) + Self.box(20, 698, 92, 2)
        p.ink(p.junk + p.keep)
        let before = p.out
        ShadowRemoval.clearSides(&p.out, Self.w, Self.h, dpi: Self.dpi)
        #expect(p.out == before)
    }

    @Test("Review 2b: a lone narrow folio 1 beside the lines, within the block's height, stays")
    func loneNarrowFolioBeside() {
        var p = Self.page()
        p.keep += Self.box(800, 500, 3, 20)
        p.ink(p.keep)
        ShadowRemoval.clearSides(&p.out, Self.w, Self.h, dpi: Self.dpi)
        #expect(share(p.out, p.keep) == 1)
        #expect(share(p.out, p.text) == 1)
    }

    @Test("Review 4b: a broken outline O, 1-pixel strokes, beside a band at the fold stays")
    func brokenLetterBesideBand() {
        // Gray page: paper 235, the text, a black band at the right side, an outline O beside it.
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        var text: [Int] = []
        for line in 0..<20 { for x in stride(from: 150, to: 660, by: 45) { text += Self.pair(x, 100 + line * 50) } }
        for i in text { g[i] = 20 }
        for i in Self.box(879, 0, 21, Self.h) { g[i] = 10 }
        let o = Self.box(855, 500, 8, 1) + Self.box(855, 519, 8, 1) + Self.box(855, 500, 1, 20) + Self.box(862, 500, 1, 20)
        for i in o { g[i] = 20 }
        let out = BlackAndWhite.ink(gray: g, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                    removeShadows: true)
        #expect(share(out, o) > 0.95, "\(share(out, o))")
        #expect(share(out, text) > 0.99)
    }

    @Test("Review 5b: on a page of two lines a printed rule and a bracket near the side stay")
    func sparsePageRules() {
        var p = Page()
        for line in 0..<2 { for x in stride(from: 150, to: 660, by: 45) { p.text += Self.pair(x, 500 + line * 50) } }
        p.ink(p.text)
        p.keep += Self.box(60, 300, 2, 400)                                         // a vertical rule
        p.keep += Self.box(840, 300, 2, 300) + Self.box(828, 300, 12, 2) + Self.box(828, 598, 12, 2)   // a bracket
        p.ink(p.keep)
        ShadowRemoval.clearSides(&p.out, Self.w, Self.h, dpi: Self.dpi)
        #expect(share(p.out, p.keep) == 1, "\(share(p.out, p.keep))")
        #expect(share(p.out, p.text) == 1)
    }

    @Test("Review 6b: in color a faint period beside a removed streak piece is not painted out")
    func faintPeriodBesidePaint() throws {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        var text: [Int] = []
        for line in 0..<20 { for x in stride(from: 150, to: 660, by: 45) { text += Self.pair(x, 100 + line * 50) } }
        for i in text { g[i] = 30 }
        let streak = Self.box(800, 470, 2, 60)
        for i in streak { g[i] = 40 }
        let period = Self.box(807, 505, 2, 2)
        for i in period { g[i] = 220 }
        let image = try #require(BlackAndWhite.image(g, width: Self.w, height: Self.h))
        let out = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(streak.allSatisfy { out[$0] > 225 }, "the streak is painted out")
        #expect(period.allSatisfy { out[$0] <= 225 }, "\(period.map { out[$0] })")
    }

    @Test("A big capital starting a line beside the block (a title's P, a drop cap) stays")
    func bigCapitalStartingLine() {
        var p = Self.page()
        // A P 35 wide, 60 tall, 5-px strokes, its foot on line 1's baseline, 20 px before it.
        p.keep += Self.box(95, 70, 5, 60) + Self.box(95, 70, 30, 5) + Self.box(95, 100, 30, 5) + Self.box(125, 70, 5, 35)
        p.ink(p.keep)
        ShadowRemoval.clearSides(&p.out, Self.w, Self.h, dpi: Self.dpi)
        #expect(share(p.out, p.keep) == 1, "\(share(p.out, p.keep))")
        #expect(share(p.out, p.text) == 1)
    }

    @Test("A title's first capital beside the block stays when the title is too big to be a text line")
    func titleCapital() {
        var p = Page()
        for line in 0..<16 { for x in stride(from: 150, to: 660, by: 45) { p.text += Self.pair(x, 300 + line * 50) } }
        // Title letters 70 tall (over 3 text heights), boxes of 5-px strokes, from x 160.
        for x in stride(from: 160, to: 400, by: 45) {
            p.text += Self.box(x, 100, 5, 70) + Self.box(x + 30, 100, 5, 70) + Self.box(x, 100, 35, 5) + Self.box(x, 165, 35, 5)
        }
        p.ink(p.text)
        // Its P, 20 px before it and past the block's edge.
        p.keep += Self.box(95, 100, 5, 70) + Self.box(95, 100, 40, 5) + Self.box(95, 135, 40, 5) + Self.box(130, 100, 5, 40)
        p.ink(p.keep)
        ShadowRemoval.clearSides(&p.out, Self.w, Self.h, dpi: Self.dpi)
        #expect(share(p.out, p.keep) == 1, "\(share(p.out, p.keep))")
        #expect(share(p.out, p.text) == 1)
    }

    @Test("A page with no text is left as it is")
    func noText() {
        var out = [UInt8](repeating: 255, count: Self.w * Self.h)
        for i in Self.box(860, 80, 3, 1020) { out[i] = 0 }
        let before = out
        #expect(!ShadowRemoval.clearSides(&out, Self.w, Self.h, dpi: Self.dpi))
        #expect(out == before)
    }

    /// A gray page: paper 230, text 30, a soft shadow and a dark crease at the right side.
    static func shadowedGray() -> (gray: [UInt8], text: [Int], fold: [Int]) {
        var g = [UInt8](repeating: 230, count: w * h)
        for y in 0..<h {
            for x in 600..<w {
                let t = Double(x - 600) / 300
                g[y * w + x] = UInt8(230 - 150 * t * t)
            }
        }
        var text: [Int] = []
        for line in 0..<20 { for x in stride(from: 150, to: 660, by: 45) { text += pair(x, 100 + line * 50) } }
        for i in text { g[i] = UInt8(Int(g[i]) * 30 / 230) }
        let fold = box(880, 0, 4, h)
        for i in fold { g[i] = 20 }
        return (g, text, fold)
    }

    @Test("Color: the shadow and crease become paper, the text stays dark")
    func colorPage() throws {
        let s = Self.shadowedGray()
        let image = try #require(BlackAndWhite.image(s.gray, width: Self.w, height: Self.h))
        let out = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        // Away from text: paper within 12 of 230 everywhere, crease included.
        let textSet = Set(Self.text(s.text))
        let worst = out.indices.filter { !textSet.contains($0) }.map { abs(Int(out[$0]) - 230) }.max() ?? 0
        #expect(worst <= 12, "\(worst)")
        #expect(s.text.allSatisfy { out[$0] < 80 })
    }

    /// Text pixels and those within 2 px of them (their soft edges).
    static func text(_ px: [Int]) -> [Int] {
        var near = Set<Int>()
        for i in px {
            let x = i % w, y = i / w
            for dy in -2...2 { for dx in -2...2 where x + dx >= 0 && x + dx < w && y + dy >= 0 && y + dy < h {
                near.insert((y + dy) * w + x + dx) } }
        }
        return Array(near)
    }

    @Test("Black and white with Remove shadows: the crease and shadow go, the text stays")
    func bwPage() {
        let s = Self.shadowedGray()
        let out = BlackAndWhite.ink(gray: s.gray, sharp: nil, tone: true, width: Self.w, height: Self.h,
                                    dpi: Self.dpi, removeShadows: true)
        #expect(share(out, s.fold) == 0)
        #expect(share(out, s.text) > 0.99)
        #expect(out.filter { $0 == 0 }.count <= s.text.count)
    }
}
