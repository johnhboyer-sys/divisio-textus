import Foundation
import CoreGraphics

/// Text-line baselines traced from ink, for the flatten score. It shares no code with
/// `Flatten` (the app's own tracer), so the score does not grade the app by its own
/// measure. Glyphs come from `HCGlyphDetector` run on the page evened out against its
/// local paper level (so a fold's shadow is not ink); glyphs chain into text lines as in
/// `HCGlyphDetector.verticalMarks` (and bottoms within 0.6 of the shorter's height, so a
/// footnote figure does not join two lines); a line's baseline is the running median of its
/// glyph bottoms, with descenders (bottoms well below their neighbours') left out.
struct HCBaseline {
    var glyphs: [HCGlyph]          // left to right
    var base: [(x: Double, y: Double)]   // smoothed baseline samples, left to right
    var xHeight: Double            // median glyph height in the line
    var minX: Int { glyphs.first?.x0 ?? 0 }
    var maxX: Int { glyphs.map(\.x1).max() ?? 0 }

    /// How far (px) the baseline's end on one side lies off the straight line fitted to the
    /// baseline's other 70%: the median of its 3 end samples against the line there.
    func droopPx(endOnRight: Bool) -> Double? {
        guard base.count >= 10 else { return nil }
        let x0 = base.first!.x, x1 = base.last!.x
        let cut = endOnRight ? x0 + 0.7 * (x1 - x0) : x1 - 0.7 * (x1 - x0)
        let rest = base.filter { endOnRight ? $0.x <= cut : $0.x >= cut }
        let ends = endOnRight ? Array(base.suffix(3)) : Array(base.prefix(3))
        guard rest.count >= 5 else { return nil }
        let n = Double(rest.count)
        let mx = rest.reduce(0) { $0 + $1.x } / n, my = rest.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, sxy = 0.0
        for p in rest { sxx += (p.x - mx) * (p.x - mx); sxy += (p.x - mx) * (p.y - my) }
        let b = sxx > 0 ? sxy / sxx : 0
        let d = ends.map { $0.y - (my + b * ($0.x - mx)) }.sorted()
        return abs(d[1])
    }

    /// RMS distance in pixels of the baseline from its least-squares straight line.
    var curlPx: Double {
        let n = Double(base.count)
        guard base.count >= 3 else { return 0 }
        let mx = base.reduce(0) { $0 + $1.x } / n, my = base.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, sxy = 0.0
        for p in base { sxx += (p.x - mx) * (p.x - mx); sxy += (p.x - mx) * (p.y - my) }
        let b = sxx > 0 ? sxy / sxx : 0
        let ss = base.reduce(0.0) { let d = $1.y - (my + b * ($1.x - mx)); return $0 + d * d }
        return (ss / n).squareRoot()
    }
}

enum HCBaselines {

    /// The page divided by its paper level (the brightest in a window about 1/20 of the
    /// page's longer side), 255 = paper. Scanner black (paper level under 60) stays white.
    static func evened(_ g: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        let block = max(8, max(w, h) / 60)
        let bw = (w + block - 1) / block, bh = (h + block - 1) / block
        var bmax = [Int](repeating: 0, count: bw * bh)
        for y in 0..<h {
            for x in 0..<w {
                let k = (y / block) * bw + x / block
                bmax[k] = max(bmax[k], Int(g[y * w + x]))
            }
        }
        // Max over the 3x3 blocks around, so a block filled by a heading is not paper.
        var bg = [Int](repeating: 0, count: bw * bh)
        for by in 0..<bh {
            for bx in 0..<bw {
                var m = 0
                for dy in -1...1 { for dx in -1...1 {
                    let yy = by + dy, xx = bx + dx
                    if yy >= 0, yy < bh, xx >= 0, xx < bw { m = max(m, bmax[yy * bw + xx]) }
                } }
                bg[by * bw + bx] = m
            }
        }
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = bg[(y / block) * bw + x / block]
                guard p >= 60 else { continue }
                out[y * w + x] = UInt8(min(255, Int(g[y * w + x]) * 255 / p))
            }
        }
        return out
    }

    /// Glyphs of a page image's gray pixels, found on the evened page.
    static func glyphs(_ g: [UInt8], width w: Int, height h: Int) -> [HCGlyph] {
        let e = evened(g, width: w, height: h)
        let gs = HCGlyphDetector.glyphs(e, width: w, height: h)
        return HCGlyphDetector.withoutVerticalMarks(gs, gray: e, width: w, height: h)
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Text lines of at least `minGlyphs` glyphs.
    static func lines(_ gs: [HCGlyph], minGlyphs: Int = 12) -> [HCBaseline] {
        let n = gs.count
        guard n > 1 else { return [] }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var c = i
            while parent[c] != r { let x = parent[c]; parent[c] = r; c = x }
            return r
        }
        func ht(_ g: HCGlyph) -> Int { g.y1 - g.y0 + 1 }
        let byX = (0..<n).sorted { gs[$0].x0 < gs[$1].x0 }
        let maxH = gs.map(ht).max() ?? 0
        for (k, i) in byX.enumerated() {
            let a = gs[i]
            var m = k + 1
            while m < n, gs[byX[m]].x0 <= a.x1 + 1 + maxH {
                let j = byX[m], b = gs[j]
                m += 1
                let ha = ht(a), hb = ht(b), lo = min(ha, hb), hi = max(ha, hb)
                guard Double(hi) <= 2.5 * Double(lo) else { continue }
                let overlap = min(a.y1, b.y1) - max(a.y0, b.y0) + 1
                guard 2 * overlap >= lo, 5 * abs(a.y1 - b.y1) <= 3 * lo else { continue }
                let gap = max(0, b.x0 - a.x1 - 1, a.x0 - b.x1 - 1)
                if gap <= hi {
                    let ra = find(i), rb = find(j)
                    if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
                }
            }
        }
        var groups = [Int: [HCGlyph]]()
        for i in 0..<n { groups[find(i), default: []].append(gs[i]) }
        var out: [HCBaseline] = []
        for (_, g0) in groups where g0.count >= minGlyphs {
            let g = g0.sorted { $0.x0 < $1.x0 }
            let xh = median(g.map { Double(ht($0)) })
            let bottoms = g.map { Double($0.y1) + 1 }
            // Running median of 7 bottoms; keep glyphs on it (descenders and raised marks go).
            var kept: [(x: Double, y: Double)] = []
            for i in g.indices {
                let lo = max(0, i - 3), hi = min(g.count - 1, i + 3)
                let med = median(Array(bottoms[lo...hi]))
                if abs(bottoms[i] - med) <= max(1.5, 0.12 * xh) {
                    kept.append((Double(g[i].x0 + g[i].x1) / 2, bottoms[i]))
                }
            }
            guard kept.count >= minGlyphs / 2 else { continue }
            // Smoothed: running median of 5 kept bottoms.
            var base: [(x: Double, y: Double)] = []
            for i in kept.indices {
                let lo = max(0, i - 2), hi = min(kept.count - 1, i + 2)
                base.append((kept[i].x, median(kept[lo...hi].map(\.y))))
            }
            out.append(HCBaseline(glyphs: g, base: base, xHeight: xh))
        }
        return out.sorted { ($0.base.first?.y ?? 0) < ($1.base.first?.y ?? 0) }
    }

    /// Long lines only: spanning at least `share` of the widest line.
    static func longLines(_ ls: [HCBaseline], share: Double = 0.5) -> [HCBaseline] {
        let widest = ls.map { $0.maxX - $0.minX }.max() ?? 0
        return ls.filter { Double($0.maxX - $0.minX) >= share * Double(widest) }
    }

    /// Median glyph width in the band of the text nearest the gutter (`gutterShare` of the
    /// text's width) over the median in the middle half, from long lines' glyphs no taller
    /// than 1.3 times their line's x-height (lowercase without ascenders, mostly).
    static func gutterWidthRatio(_ ls: [HCBaseline], gutterOnRight: Bool, gutterShare: Double = 0.15) -> Double? {
        guard let lo = ls.map(\.minX).min(), let hi = ls.map(\.maxX).max(), hi > lo else { return nil }
        let span = Double(hi - lo)
        var gut: [Double] = [], mid: [Double] = []
        for l in ls {
            for g in l.glyphs where Double(g.y1 - g.y0 + 1) <= 1.3 * l.xHeight {
                let t = (Double(g.x0 + g.x1) / 2 - Double(lo)) / span
                let fromGutter = gutterOnRight ? 1 - t : t
                let w = Double(g.x1 - g.x0 + 1)
                if fromGutter < gutterShare { gut.append(w) } else if fromGutter > 0.25 && fromGutter < 0.75 { mid.append(w) }
            }
        }
        guard gut.count >= 20, mid.count >= 40 else { return nil }
        return median(gut) / median(mid)
    }
}
