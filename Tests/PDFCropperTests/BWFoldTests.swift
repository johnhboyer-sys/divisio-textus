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
