import Foundation
import CoreGraphics

/// A small text-glyph finder for the hill-climb proxy metrics. It shares nothing with
/// PageAnalyzer: Otsu threshold, then 8-connected components of ink. A component
/// counts as a glyph when it is 0.4%–4% of the page tall and at most 10% of the page
/// wide (so rules, plates, shadows, and glyphs fused to them, are left out).
struct HCGlyph: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int   // inclusive pixel bounds
}

enum HCGlyphDetector {

    static let minHeightShare = 0.004, maxHeightShare = 0.04, maxWidthShare = 0.10

    /// Otsu's threshold over the pixels above `floor`: scanner bed black is left
    /// out of the histogram so it can't pull the cut between ink and paper.
    static func otsu(_ g: [UInt8], floor: Int = 25) -> Int {
        var hist = [Int](repeating: 0, count: 256)
        for v in g where Int(v) >= floor { hist[Int(v)] += 1 }
        let total = hist.reduce(0, +)
        guard total > 0 else { return 128 }
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i * hist[i]) }
        var wB = 0, sumB = 0.0, best = 128, bestVar = -1.0
        for t in 0..<256 {
            wB += hist[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB), mF = (sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > bestVar { bestVar = between; best = t }
        }
        return best
    }

    static func glyphs(_ g: [UInt8], width w: Int, height h: Int) -> [HCGlyph] {
        guard w > 0, h > 0, g.count == w * h else { return [] }
        let t = otsu(g)
        // Runs of ink per row, joined to touching runs of the row above (8-connected).
        var runStart: [Int32] = [], runEnd: [Int32] = [], runRow: [Int32] = []
        var parent: [Int32] = []
        func find(_ i: Int32) -> Int32 {
            var r = i
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = i
            while parent[Int(c)] != r { let n = parent[Int(c)]; parent[Int(c)] = r; c = n }
            return r
        }
        var prevLo = 0, prevHi = 0   // run index range of the previous row
        for y in 0..<h {
            let lo = runStart.count
            var x = 0
            let base = y * w
            while x < w {
                if Int(g[base + x]) <= t {
                    let s = x
                    while x < w, Int(g[base + x]) <= t { x += 1 }
                    runStart.append(Int32(s)); runEnd.append(Int32(x - 1)); runRow.append(Int32(y))
                    parent.append(Int32(runStart.count - 1))
                } else { x += 1 }
            }
            let hi = runStart.count
            // Join with the previous row by walking both lists.
            var a = prevLo
            for b in lo..<hi {
                while a < prevHi, runEnd[a] < runStart[b] - 1 { a += 1 }
                var k = a
                while k < prevHi, runStart[k] <= runEnd[b] + 1 {
                    let ra = find(Int32(k)), rb = find(Int32(b))
                    if ra != rb { parent[Int(max(ra, rb))] = min(ra, rb) }
                    k += 1
                }
            }
            prevLo = lo; prevHi = hi
        }
        var minX = [Int32](repeating: Int32.max, count: runStart.count)
        var maxX = [Int32](repeating: -1, count: runStart.count)
        var minY = [Int32](repeating: Int32.max, count: runStart.count)
        var maxY = [Int32](repeating: -1, count: runStart.count)
        for i in 0..<runStart.count {
            let r = Int(find(Int32(i)))
            minX[r] = min(minX[r], runStart[i]); maxX[r] = max(maxX[r], runEnd[i])
            minY[r] = min(minY[r], runRow[i]); maxY[r] = max(maxY[r], runRow[i])
        }
        var out: [HCGlyph] = []
        let hMin = minHeightShare * Double(h), hMax = maxHeightShare * Double(h), wMax = maxWidthShare * Double(w)
        for i in 0..<runStart.count where parent[i] == Int32(i) {
            let gh = Double(maxY[i] - minY[i] + 1), gw = Double(maxX[i] - minX[i] + 1)
            if gh >= hMin, gh <= hMax, gw <= wMax {
                out.append(HCGlyph(x0: Int(minX[i]), y0: Int(minY[i]), x1: Int(maxX[i]), y1: Int(maxY[i])))
            }
        }
        return out
    }

    /// Glyphs the vertical line between pixel columns `x - 1` and `x` runs through.
    static func cutBySplit(_ glyphs: [HCGlyph], atPixel x: Int) -> Int {
        glyphs.filter { $0.x0 <= x - 1 && $0.x1 >= x }.count
    }

    /// Glyphs that a crop edge runs through: they meet the crop but are not wholly in it.
    /// `rects` are pixel rectangles as the exporter cuts them (integral, in the image).
    static func cutByCrops(_ glyphs: [HCGlyph], _ rects: [CGRect]) -> Int {
        glyphs.filter { g in
            rects.contains { r in
                let x0 = Int(r.minX), x1 = Int(r.maxX) - 1, y0 = Int(r.minY), y1 = Int(r.maxY) - 1
                let meets = g.x0 <= x1 && g.x1 >= x0 && g.y0 <= y1 && g.y1 >= y0
                let inside = g.x0 >= x0 && g.x1 <= x1 && g.y0 >= y0 && g.y1 <= y1
                return meets && !inside
            }
        }.count
    }
}
