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

    /// Pieces of a vertical mark (a fold's crease line, the speckle of a fold shadow) that the
    /// size rule lets through as glyphs. Print sits in text lines; these pieces are thin and
    /// sit in a column, one under the next. A piece is left out when all hold:
    /// * it is in no text line: chained to its neighbours in the row (they overlap it by half
    ///   the smaller height, are at most 2.5 times as tall, and are no further off than the
    ///   taller one is tall), it and they span less than 3 times their middle height;
    /// * it is at least twice as tall as it is wide;
    /// * it is in a stack of such pieces: chained to them above and below (sharing a column,
    ///   no further off than half the shorter one's height or 3 px, and every row of the gap
    ///   gray, not paper, in the columns they share), 3 or more pieces over at least 5% of
    ///   the page height;
    /// * it is no wider than its stack's middle width plus max(2 px, a quarter), and has no
    ///   row neighbour outside its stack (print fused to a mark, or set beside it, stays).
    /// So a folio, a word, a column of page or line numbers (clean paper between them), an
    /// arrow between two numbers are all still counted. On the 312 synthetic pages no piece
    /// left out touches drawn print (`HillClimbTriage`, HILLCLIMB_TRIAGE=synth).
    static func verticalMarks(_ gs: [HCGlyph], gray g: [UInt8], width w: Int, height h: Int) -> Set<Int> {
        let n = gs.count
        guard n > 2 else { return [] }
        // A mark runs on through the gap between its pieces: every row of the gap, in the columns
        // the two pieces share, holds a pixel darker than two thirds of the way from the ink
        // threshold to white. Between lines of print some row of the gap is clean paper.
        let t = otsu(g), markGray = t + (255 - t) * 2 / 3
        func bridged(_ a: HCGlyph, _ b: HCGlyph) -> Bool {
            let x0 = max(a.x0, b.x0), x1 = min(a.x1, b.x1)
            guard b.y0 > a.y1 + 1, x1 >= x0 else { return true }
            return (a.y1 + 1 ..< b.y0).allSatisfy { y in Int(g[(y * w + x0)...(y * w + x1)].min()!) <= markGray }
        }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var c = i
            while parent[c] != r { let x = parent[c]; parent[c] = r; c = x }
            return r
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
        func ht(_ g: HCGlyph) -> Int { g.y1 - g.y0 + 1 }
        // Text lines: walk glyphs left to right.
        let byX = (0..<n).sorted { gs[$0].x0 < gs[$1].x0 }
        let maxH = gs.map(ht).max() ?? 0
        var mates = [[Int]](repeating: [], count: n)
        for (k, i) in byX.enumerated() {
            let a = gs[i]
            var m = k + 1
            while m < n, gs[byX[m]].x0 <= a.x1 + 1 + maxH {
                let j = byX[m], b = gs[j]
                m += 1
                let ha = ht(a), hb = ht(b), lo = min(ha, hb), hi = max(ha, hb)
                guard Double(hi) <= 2.5 * Double(lo) else { continue }
                let overlap = min(a.y1, b.y1) - max(a.y0, b.y0) + 1
                guard 2 * overlap >= lo else { continue }
                let gap = max(0, b.x0 - a.x1 - 1, a.x0 - b.x1 - 1)
                if gap <= hi { union(i, j); mates[i].append(j); mates[j].append(i) }
            }
        }
        var lineLo = [Int: Int](), lineHi = [Int: Int](), lineHeights = [Int: [Int]]()
        for i in 0..<n {
            let r = find(i)
            lineLo[r] = min(lineLo[r] ?? Int.max, gs[i].x0)
            lineHi[r] = max(lineHi[r] ?? Int.min, gs[i].x1)
            lineHeights[r, default: []].append(ht(gs[i]))
        }
        let lineless = (0..<n).filter { i in
            let r = find(i)
            let hs = lineHeights[r]!.sorted()
            return lineHi[r]! - lineLo[r]! + 1 < 3 * hs[hs.count / 2] && 2 * (gs[i].x1 - gs[i].x0 + 1) <= ht(gs[i])
        }
        // Stacks of thin line-less pieces: walk them top to bottom.
        parent = Array(0..<n)
        let byY = lineless.sorted { gs[$0].y0 < gs[$1].y0 }
        for (k, i) in byY.enumerated() {
            let a = gs[i]
            var m = k + 1
            while m < byY.count, gs[byY[m]].y0 <= a.y1 + 1 + maxH {
                let j = byY[m], b = gs[j]
                m += 1
                guard b.x0 <= a.x1, b.x1 >= a.x0 else { continue }
                let gap = max(0, b.y0 - a.y1 - 1)
                if gap <= max(3, min(ht(a), ht(b)) / 2), bridged(a, b) { union(i, j) }
            }
        }
        var count = [Int: Int](), top = [Int: Int](), bottom = [Int: Int](), widths = [Int: [Int]]()
        for i in lineless {
            let r = find(i)
            count[r, default: 0] += 1
            top[r] = min(top[r] ?? Int.max, gs[i].y0)
            bottom[r] = max(bottom[r] ?? Int.min, gs[i].y1)
            widths[r, default: []].append(gs[i].x1 - gs[i].x0 + 1)
        }
        let isLineless = Set(lineless)
        return Set(lineless.filter { i in
            let r = find(i)
            guard count[r]! >= 3, Double(bottom[r]! - top[r]! + 1) >= 0.05 * Double(h) else { return false }
            // A piece wider than its stack, or with a row neighbour outside the stack, has print fused to it or beside it.
            let ws = widths[r]!.sorted(), med = ws[ws.count / 2]
            guard gs[i].x1 - gs[i].x0 + 1 <= med + max(2, med / 4) else { return false }
            return mates[i].allSatisfy { isLineless.contains($0) && find($0) == r }
        })
    }

    /// `gs` less the pieces of vertical marks.
    static func withoutVerticalMarks(_ gs: [HCGlyph], gray g: [UInt8], width w: Int, height h: Int) -> [HCGlyph] {
        let marks = verticalMarks(gs, gray: g, width: w, height: h)
        return gs.indices.filter { !marks.contains($0) }.map { gs[$0] }
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
