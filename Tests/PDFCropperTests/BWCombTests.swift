import Testing
import Foundation
import CoreGraphics
@testable import PDFCropper

/// Remove shadows on a comb-bound page: the teeth and the clumps their loops leave go
/// in every mode; print beside them (a folio touching a tooth, a rule, a bracket) stays.
@Suite("BW comb binding")
struct BWCombTests {
    static let w = 900, h = 1200, dpi = 300.0

    static func box(_ x: Int, _ y: Int, _ bw: Int, _ bh: Int) -> [Int] {
        var px: [Int] = []
        for yy in y..<(y + bh) { for xx in x..<(x + bw) where xx >= 0 && xx < w && yy >= 0 && yy < h { px.append(yy * w + xx) } }
        return px
    }

    /// Paper 235, 20 lines of text (x 150 to 675) at gray 30, and eleven comb teeth
    /// (40 x 60, gray 45) down the right side every 100 px, each with a speckled clump
    /// (its loop) at its inner end, unless `clumps` is false.
    static func page(clumps withClumps: Bool = true) -> (gray: [UInt8], text: [Int], teeth: [Int], clumps: [Int]) {
        var g = [UInt8](repeating: 235, count: w * h)
        var text: [Int] = []
        for line in 0..<20 {
            let y = 100 + line * 50
            for x in stride(from: 150, to: 660, by: 45) {
                text += box(x, y + 8, 3, 22) + box(x + 17, y + 8, 3, 22) + box(x, y + 8, 20, 3) + box(x, y + 27, 20, 3) + box(x + 28, y, 3, 30)
            }
        }
        for i in text { g[i] = 30 }
        var teeth: [Int] = [], clumps: [Int] = []
        var rng = HCRandom(9)
        for k in 0..<11 {
            let y = 80 + k * 100
            teeth += box(840, y, 40, 60)
            for yy in (y + 20)..<(y + 40) { for xx in 818..<838 where rng.chance(0.5) && withClumps { clumps.append(yy * w + xx) } }
        }
        for i in teeth { g[i] = 45 }
        for i in clumps { g[i] = 165 }     // pale, as the loops round Oesterle's teeth are (mean gray 146 to 189)
        return (g, text, teeth, clumps)
    }

    private func share(_ out: [UInt8], _ px: [Int]) -> Double {
        Double(px.filter { out[$0] < 128 }.count) / Double(max(1, px.count))
    }

    @Test("The teeth and their loops' clumps go; the text stays, in black and white and in color")
    func teethGo() throws {
        let p = Self.page()
        let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, p.teeth) == 0, "teeth \(share(bw, p.teeth))")
        #expect(share(bw, p.clumps) == 0, "clumps \(share(bw, p.clumps))")
        #expect(share(bw, p.text) > 0.99)
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        let left = (p.teeth + p.clumps).filter { abs(Int(color[$0]) - 235) > 15 }.count
        #expect(left == 0, "\(left) tooth or clump pixels not paper in color")
        #expect(p.text.allSatisfy { color[$0] < 100 })
    }

    /// Oesterle's teeth: joined to the spine's dark band, with a paler end toward the
    /// page, and the comb's back showing in the gaps between them by the side.
    @Test("Teeth joined to the spine's band go, with their paler ends and the comb's back between them")
    func bandEndsAndBack() throws {
        var p = Self.page()
        let band = Self.box(885, 0, 15, Self.h)
        var ends: [Int] = [], back: [Int] = []
        var rng = HCRandom(4)
        for k in 0..<11 {
            let y = 80 + k * 100
            ends += Self.box(822, y - 4, 18, 66)                 // a paler, curled end
            for yy in (y + 66)..<(y + 90) { for xx in 850..<884 where rng.chance(0.5) { back.append(yy * Self.w + xx) } }
        }
        for i in band { p.gray[i] = 20 }
        for i in ends { p.gray[i] = 150 }
        for i in back { p.gray[i] = 120 }
        let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, p.teeth) == 0, "teeth \(share(bw, p.teeth))")
        #expect(share(bw, ends) == 0, "ends \(share(bw, ends))")
        #expect(share(bw, back) == 0, "back \(share(bw, back))")
        #expect(share(bw, p.text) > 0.99)
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        let left = (p.teeth + ends + back).filter { abs(Int(color[$0]) - 235) > 15 }.count
        #expect(left == 0, "\(left) tooth, end or back pixels not paper in color")
        #expect(p.text.allSatisfy { color[$0] < 100 })
    }

    @Test("A folio touching a tooth stays, off the tooth")
    func folioTouchingTooth() throws {
        var p = Self.page()
        // A folio 12 whose 2 touches the tooth at y 480 (x 840).
        let folio = Self.box(800, 500, 4, 30)
            + Self.box(812, 500, 27, 4) + Self.box(835, 500, 4, 16) + Self.box(812, 513, 27, 4)
            + Self.box(812, 513, 4, 17) + Self.box(812, 526, 28, 4)
        for i in folio { p.gray[i] = 30 }
        let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        let offTooth = folio.filter { $0 % Self.w < 838 }
        #expect(share(bw, offTooth) > 0.95, "\(share(bw, offTooth))")
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(offTooth.filter { color[$0] < 100 }.count) > 0.95 * Double(offTooth.count))
    }

    /// Cherniss, cropped tight: the bold first letters of the lines stand in a column at
    /// a steady pitch, as teeth do, but are no thicker than the page's strokes allow.
    @Test("Bold letters starting the lines of a tight crop are no teeth")
    func lineStartsStay() throws {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        var starts: [Int] = [], text: [Int] = []
        for line in 0..<20 {
            let y = 100 + line * 50
            starts += Self.box(6, y, 12, 32) + Self.box(6, y, 26, 8)       // a bold T's stem and bar
            for x in stride(from: 50, to: 660, by: 45) {
                text += Self.box(x, y + 8, 10, 24) + Self.box(x + 18, y + 8, 10, 24) + Self.box(x, y + 8, 28, 8)
            }
        }
        for i in starts + text { g[i] = 30 }
        let bw = BlackAndWhite.ink(gray: g, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, starts) > 0.99, "\(share(bw, starts))")
        #expect(!ShadowRemoval.teeth(g, Self.w, Self.h, dpi: Self.dpi, paper: 255).found)
    }

    /// A lone upright rule beside the block is not tried: by the fold it can't be told
    /// from a fold's line or a page stack's stripe, and goes, with or without teeth.
    @Test("A printed rule across, a bracket and a dash near the teeth stay")
    func ruleAndBracketStay() throws {
        var p = Self.page()
        let rule = Self.box(760, 760, 60, 2)
        let bracket = Self.box(810, 150, 2, 300) + Self.box(798, 150, 12, 2) + Self.box(798, 448, 12, 2)
        let dash = Self.box(812, 530, 20, 2)      // in the zone of the tooth at y 480, below its clump
        for i in rule + bracket + dash { p.gray[i] = 30 }
        let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, rule) > 0.99, "rule \(share(bw, rule))")
        #expect(share(bw, bracket) > 0.99, "bracket \(share(bw, bracket))")
        #expect(share(bw, dash) > 0.99, "dash \(share(bw, dash))")
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        for (name, px) in [("rule", rule), ("bracket", bracket), ("dash", dash)] {
            #expect(Double(px.filter { color[$0] < 100 }.count) > 0.99 * Double(px.count), "\(name) in color")
        }
    }

    /// No comb: a list's square bullets stand in a column at a steady pitch, as teeth
    /// do, but start text lines.
    @Test("Square bullets starting a list's lines are no teeth")
    func bulletsStay() throws {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        var bullets: [Int] = [], text: [Int] = []
        for k in 0..<8 {
            let y = 100 + k * 75
            bullets += Self.box(20, y, 20, 20)
            for x in stride(from: 60, to: 660, by: 45) {
                text += Self.box(x, y - 1, 3, 22) + Self.box(x + 17, y - 1, 3, 22) + Self.box(x, y - 1, 20, 3)
                    + Self.box(x, y + 18, 20, 3)
            }
        }
        for i in bullets + text { g[i] = 30 }
        let bw = BlackAndWhite.ink(gray: g, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, bullets) > 0.99, "bullets \(share(bw, bullets))")
        #expect(share(bw, text) > 0.99, "text \(share(bw, text))")
        let image = try #require(BlackAndWhite.image(g, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(bullets.filter { color[$0] < 100 }.count) > 0.99 * Double(bullets.count), "bullets in color")
    }

    @Test("A folio 1 beside a tooth, as tall as its end, stays")
    func folioOneStays() throws {
        var p = Self.page(clumps: false)
        let one = Self.box(815, 490, 4, 46)
        for i in one { p.gray[i] = 30 }
        let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, one) > 0.95, "\(share(bw, one))")
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(one.filter { color[$0] < 100 }.count) > 0.95 * Double(one.count), "1 in color")
    }

    @Test("A gray rule running up to a tooth stays")
    func grayRuleStays() throws {
        var p = Self.page(clumps: false)
        let rule = Self.box(700, 510, 136, 2)
        for i in rule { p.gray[i] = 100 }
        let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, rule) > 0.95, "\(share(bw, rule))")
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(rule.filter { color[$0] < 160 }.count) > 0.95 * Double(rule.count), "rule in color")
    }

    // MARK: Lists hanging at the side, no comb

    /// No comb: eight list markers at x 20, one per line every 75 px from y 100, the
    /// text hanging from x 100 (`letters` to an entry; with `linesAbove`, three full
    /// lines above the list). The markers stay, in black and white and in color.
    private func listStays(count: Int = 8, letters: Int = 14, linesAbove: Bool = false,
                           _ marker: (Int) -> [Int]) throws {
        var g = [UInt8](repeating: 235, count: Self.w * Self.h)
        var markers: [Int] = [], text: [Int] = []
        let rows = (0..<count).map { (100 + $0 * 75, letters) } + (linesAbove ? [(10, 14), (40, 14), (70, 14)] : [])
        for (k, (y, n)) in rows.enumerated() {
            if k < count { markers += marker(y) }
            for x in stride(from: 100, to: 100 + 45 * n, by: 45) {
                text += Self.box(x, y - 1, 3, 22) + Self.box(x + 17, y - 1, 3, 22) + Self.box(x, y - 1, 20, 3)
                    + Self.box(x, y + 18, 20, 3)
            }
        }
        for i in markers + text { g[i] = 30 }
        let bw = BlackAndWhite.ink(gray: g, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, markers) > 0.99, "markers \(share(bw, markers))")
        #expect(share(bw, text) > 0.99, "text \(share(bw, text))")
        let image = try #require(BlackAndWhite.image(g, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(markers.filter { color[$0] < 100 }.count) > 0.99 * Double(markers.count), "markers in color")
    }

    @Test("Square bullets hanging at x 20, text from x 100, are no teeth")
    func hangingBulletsStay() throws {
        try listStays { y in Self.box(20, y, 20, 20) }
    }

    @Test("Fourteen square bullets hanging down the whole page are no teeth")
    func longHangingListStays() throws {
        try listStays(count: 14) { y in Self.box(20, y, 20, 20) }
    }

    @Test("Round bullets hanging at x 20, text from x 100, are no teeth")
    func hangingRoundBulletsStay() throws {
        try listStays { y in
            Self.box(20, y, 20, 20).filter { i in
                let dx = Double(i % Self.w) - 29.5, dy = Double(i / Self.w - y) - 9.5
                return dx * dx + dy * dy <= 100
            }
        }
    }

    // MARK: Print beside a tooth

    @Test("A folio 1 with a short rule below it stays")
    func folioOneWithRuleStays() throws {
        var p = Self.page(clumps: false)
        let one = Self.box(815, 490, 4, 46), rule = Self.box(810, 570, 20, 2)
        for i in one + rule { p.gray[i] = 30 }
        let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, one) > 0.95, "1 \(share(bw, one))")
        #expect(share(bw, rule) > 0.95, "rule \(share(bw, rule))")
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(one.filter { color[$0] < 100 }.count) > 0.95 * Double(one.count), "1 in color")
    }

    @Test("A folio 1 with a serif foot beside a tooth stays")
    func serifOneStays() throws {
        var p = Self.page(clumps: false)
        let one = Self.box(815, 490, 4, 46) + Self.box(808, 532, 18, 4)
        for i in one { p.gray[i] = 30 }
        let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, one) > 0.95, "\(share(bw, one))")
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(one.filter { color[$0] < 100 }.count) > 0.95 * Double(one.count), "1 in color")
    }

    @Test("A short gray rule running up to a tooth, nearly all in its zone, stays")
    func shortGrayRuleStays() throws {
        var p = Self.page(clumps: false)
        let rule = Self.box(802, 510, 34, 2)
        for i in rule { p.gray[i] = 100 }
        let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, rule) > 0.95, "\(share(bw, rule))")
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(rule.filter { color[$0] < 160 }.count) > 0.95 * Double(rule.count), "rule in color")
    }

    @Test("A faded serif 1 beside a tooth, reaching above it, stays")
    func fadedSerifOneStays() throws {
        var p = Self.page(clumps: false)
        let one = Self.box(828, 464, 12, 46) + Self.box(822, 498, 24, 12)
        for i in one { p.gray[i] = 150 }
        let off = one.filter { $0 % Self.w < 838 }
        let bw = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: true, width: Self.w, height: Self.h, dpi: Self.dpi,
                                   removeShadows: true)
        #expect(share(bw, off) > 0.95, "\(share(bw, off))")
        let image = try #require(BlackAndWhite.image(p.gray, width: Self.w, height: Self.h))
        let color = BlackAndWhite.grayPixels(try #require(ShadowRemoval.page(image, dpi: Self.dpi)))
        #expect(Double(off.filter { color[$0] < 200 }.count) > 0.95 * Double(off.count), "1 in color")
    }

}
