import Foundation
import CoreGraphics

/// Remove shadows (an export option): the fold's shadow, a black band at the fold,
/// the fold's crease line and the streaks, ticks and specks beside it go, so the
/// page is clean paper up to its sides; print stays.
///
/// - Black and white: `clearSides` runs on the page's ink after `BlackAndWhite.ink`.
/// - Color and grayscale (`page`): the paper is evened out (each pixel brightened by
///   how much darker the paper under it is than the page's clean paper), and what
///   black and white would call ink but `clearSides` and the steps before it found
///   not to be print is painted the page's paper color.
enum ShadowRemoval {

    // MARK: The sides

    /// Clear what is not print between each side of the page and its text block.
    /// `out` is ink (0) on paper (255). Measured from the page's own text:
    /// - its text height `t`: the middle height of its letter-sized marks;
    /// - its text lines: letter-sized marks (0.45 to 2.2 `t` tall) chained along a
    ///   row (gaps up to 1.5 `t`, half their height shared), at least three, most of
    ///   them not thin, most sitting on one baseline;
    /// - the text block's left and right edges: where the lines start and end (the
    ///   second to fifth furthest out, so a stray line doesn't move them).
    /// Beside a side, past the text block's edge (a mark wholly outside it), a mark
    /// stays when it is print:
    /// - a mark of a text line, or a small one (punctuation, a footnote marker, an
    ///   accent) beside one;
    /// - a rule: flat, 1.5 `t` long or more, not touching the page's side;
    /// - a glyph or word on its own (a folio, a marginal number or note): 0.5 to 2.2
    ///   `t` tall, not thin, solid enough, not touching the side, with no other
    ///   marks about it but those of its own row (a fold's junk comes in crowds).
    /// Specks within 0.1 `t` of each other are judged together, so print broken
    /// into pieces by a pale scan is judged whole. Everything else goes: streaks,
    /// ticks, broken lines, the striped edges of the page stack, specks, and
    /// anything touching the side. A page with fewer than three text lines is left
    /// as it is. Returns whether it ran.
    @discardableResult
    static func clearSides(_ out: inout [UInt8], _ w: Int, _ h: Int, dpi: Double) -> Bool {
        guard w > 2, h > 2, out.count == w * h else { return false }
        let cc = Components(out, w, h)
        let blobs = cc.blobs
        guard !blobs.isEmpty else { return false }
        // The text height.
        let minGlyph = max(4, Int((0.012 * dpi * 0.012 * dpi).rounded()))
        var heights: [Int] = []
        for b in blobs where b.count >= minGlyph {
            let bh = b.height, bw = b.width
            if Double(bh) >= 0.03 * dpi, Double(bh) <= 0.3 * dpi, Double(bw) <= 0.5 * dpi, bw * 4 >= bh {
                heights.append(bh)
            }
        }
        guard heights.count >= 20 else { return false }
        heights.sort()
        let t = Double(heights[heights.count / 2])

        // Text lines.
        func letter(_ b: Blob) -> Bool {
            Double(b.height) >= 0.45 * t && Double(b.height) <= 2.2 * t && b.count >= minGlyph
        }
        func thin(_ b: Blob) -> Bool { Double(b.width) < 0.3 * t }
        let members = blobs.indices.filter { letter(blobs[$0]) }.sorted { blobs[$0].minX < blobs[$1].minX }
        var parent = [Int](repeating: 0, count: blobs.count)
        for i in parent.indices { parent[i] = i }
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var c = i
            while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
            return r
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
        let gapMax = Int((1.5 * t).rounded())
        for (k, i) in members.enumerated() {
            let a = blobs[i]
            var m = k + 1
            while m < members.count, blobs[members[m]].minX <= a.maxX + gapMax {
                let j = members[m], b = blobs[j]
                m += 1
                let lo = min(a.height, b.height), hi = max(a.height, b.height)
                guard Double(hi) <= 2.5 * Double(lo) else { continue }
                let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY) + 1
                if 2 * overlap >= lo { union(i, j) }
            }
        }
        var lineOf = [Int: [Int]]()
        for i in members { lineOf[find(i), default: []].append(i) }
        // A line runs from its first mark that isn't thin to its last: a thin mark
        // beyond those (a tick or a piece of a fold line chained to the line's end)
        // is judged with the rest beside the block.
        var lineMembers = Set<Int>(), chained = Set<Int>()
        var starts: [Int] = [], ends: [Int] = []
        for (_, ms) in lineOf where ms.count >= 3 {
            let wide = ms.filter { !thin(blobs[$0]) }
            guard wide.count >= 2, wide.count * 3 >= ms.count else { continue }
            let bottoms = ms.map { blobs[$0].maxY }.sorted()
            let base = bottoms[bottoms.count / 2]
            let onBase = bottoms.filter { Double(abs($0 - base)) <= 0.3 * t }.count
            guard onBase * 5 >= ms.count * 3 else { continue }
            let lo = wide.map { blobs[$0].minX }.min()!, hi = wide.map { blobs[$0].maxX }.max()!
            lineMembers.formUnion(ms.filter { blobs[$0].maxX >= lo && blobs[$0].minX <= hi })
            chained.formUnion(ms)
            starts.append(lo)
            ends.append(hi)
        }
        guard starts.count >= 3 else { return false }
        starts.sort(); ends.sort(by: >)
        let k = max(2, min(5, starts.count / 8))
        let left = starts[k - 1], right = ends[k - 1]
        guard left < right else { return false }

        // Marks wholly beside the text block, past a letter's width (a line's last
        // letter can be thin), and line marks near them.
        let margin = Int((0.6 * t).rounded())
        let zone = blobs.indices.filter {
            (blobs[$0].maxX < left - margin || blobs[$0].minX > right + margin) && !lineMembers.contains($0)
        }
        guard !zone.isEmpty else { return true }
        let reach = Int((2 * t).rounded())
        let zoned = Set(zone)
        let nearMembers = chained.filter { !zoned.contains($0) && (blobs[$0].minX < left + reach || blobs[$0].maxX > right - reach) }
            .map { blobs[$0] }
        // Small marks beside a line's mark: punctuation, footnote markers, accents;
        // not a tall thin one (a tick, a piece of a fold line).
        var attached = Set<Int>()
        let small = 1.2 * t
        for i in zone {
            let b = blobs[i]
            guard Double(b.width) <= small, Double(b.height) <= small,
                  Double(b.height) < 0.5 * t || b.width * 4 >= b.height else { continue }
            for m in nearMembers {
                let gap = max(0, b.minX - m.maxX - 1, m.minX - b.maxX - 1)
                if Double(gap) <= t, Double(b.minY) >= Double(m.minY) - 0.8 * t, Double(b.maxY) <= Double(m.maxY) + 0.5 * t {
                    attached.insert(i); break
                }
            }
        }
        let rest = zone.filter { !attached.contains($0) }.sorted { blobs[$0].minX < blobs[$1].minX }
        // Specks within 0.1 t of each other judged together, as marks.
        let r = max(1, Int((0.1 * t).rounded()))
        for (k, i) in rest.enumerated() {
            let a = blobs[i]
            var m = k + 1
            while m < rest.count, blobs[rest[m]].minX <= a.maxX + r + 1 {
                let j = rest[m], b = blobs[j]
                m += 1
                let vgap = max(0, b.minY - a.maxY - 1, a.minY - b.maxY - 1)
                if vgap <= r { union(i, j) }
            }
        }
        struct Mark { var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, count = 0, blobs: [Int] = [] }
        var marks = [Int: Mark]()
        for i in rest {
            let b = blobs[i]
            var mk = marks[find(i)] ?? Mark()
            mk.minX = min(mk.minX, b.minX); mk.maxX = max(mk.maxX, b.maxX)
            mk.minY = min(mk.minY, b.minY); mk.maxY = max(mk.maxY, b.maxY)
            mk.count += b.count; mk.blobs.append(i)
            marks[find(i)] = mk
        }
        let sideGap = max(2, Int((0.02 * dpi).rounded()))
        func touchesSide(_ m: Mark) -> Bool { m.minX <= sideGap || m.maxX >= w - 1 - sideGap }
        func glyphShaped(_ m: Mark) -> Bool {
            let mw = Double(m.maxX - m.minX + 1), mh = Double(m.maxY - m.minY + 1)
            return mh >= 0.5 * t && mh <= 2.2 * t && mw >= 0.3 * t && mw * 5 >= mh
                && Double(m.count) >= 0.12 * mw * mh && !touchesSide(m)
        }
        func flatRule(_ m: Mark) -> Bool {
            let mw = Double(m.maxX - m.minX + 1), mh = Double(m.maxY - m.minY + 1)
            return mh <= 0.35 * t && mw >= 1.5 * t && mw >= 5 * mh && !touchesSide(m)
        }
        let list = Array(marks.values)
        let shaped = list.map(glyphShaped)
        // Marks by place, for the crowd test.
        let cell = max(1, Int((2 * t).rounded()))
        var grid = [Int: [Int]]()
        func key(_ cx: Int, _ cy: Int) -> Int { cy * 100_003 + cx }
        for (n, m) in list.enumerated() {
            for cy in (m.minY / cell)...(m.maxY / cell) {
                for cx in (m.minX / cell)...(m.maxX / cell) { grid[key(cx, cy), default: []].append(n) }
            }
        }
        func near(_ m: Mark, _ pad: Int) -> [Int] {
            let x0 = m.minX - pad, x1 = m.maxX + pad, y0 = m.minY - pad, y1 = m.maxY + pad
            var found = Set<Int>()
            for cy in (max(0, y0) / cell)...(max(0, y1) / cell) {
                for cx in (max(0, x0) / cell)...(max(0, x1) / cell) { found.formUnion(grid[key(cx, cy)] ?? []) }
            }
            return found.filter { let q = list[$0]; return q.maxX >= x0 && q.minX <= x1 && q.maxY >= y0 && q.minY <= y1 }
        }
        func sameRow(_ a: Mark, _ b: Mark) -> Bool {
            let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY) + 1
            return 2 * overlap >= min(a.maxY - a.minY + 1, b.maxY - b.minY + 1)
        }
        func letterTall(_ m: Mark) -> Bool {
            let mh = Double(m.maxY - m.minY + 1)
            return mh >= 0.45 * t && mh <= 2.2 * t && !touchesSide(m)
        }
        // A glyph on its own: other marks about it, but for its own row's, hold under
        // a tenth of its ink.
        let around = Int(t.rounded())
        var keep = [Bool](repeating: false, count: list.count)
        for (n, m) in list.enumerated() {
            if flatRule(m) { keep[n] = true; continue }
            guard shaped[n] else { continue }
            var crowd = 0
            for o in near(m, around) where o != n {
                let q = list[o]
                if (shaped[o] || letterTall(q)) && sameRow(m, q) { continue }
                // A stripe or tick beside it is the fold's, not a crowd of glyph-like specks.
                let qw = Double(q.maxX - q.minX + 1), qh = Double(q.maxY - q.minY + 1)
                if qw < 0.3 * t && qh >= 0.5 * t { continue }
                crowd += q.count
            }
            keep[n] = crowd * 10 <= m.count
        }
        // And a letter beside a glyph kept so (the 1 of a folio 10).
        let beside = Int((0.6 * t).rounded())
        for (n, m) in list.enumerated() where !keep[n] && letterTall(m) {
            keep[n] = near(m, beside).contains { o in o != n && keep[o] && shaped[o] && sameRow(m, list[o]) }
        }
        for (n, m) in list.enumerated() where !keep[n] { for i in m.blobs { cc.clear(i, in: &out) } }
        return true
    }

    // MARK: Color and grayscale

    /// A color or gray output page with its shadows removed (see the type's notes),
    /// at `dpi`. Pictures (see `BlackAndWhite.pictureCells`) are left as they are.
    /// The same kind of image back (gray for gray), or nil if it can't be read.
    static func page(_ image: CGImage, dpi: Double) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 2, h > 2 else { return image }
        let monochrome = image.colorSpace?.model == .monochrome
        let space = monochrome ? CGColorSpaceCreateDeviceGray()
            : (image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!)
        let channels = monochrome ? 1 : 4
        var px = [UInt8](repeating: 255, count: w * h * channels)
        let drawn = px.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * channels, space: space,
                                      bitmapInfo: monochrome ? CGImageAlphaInfo.none.rawValue
                                                             : CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var gray = [UInt8](repeating: 255, count: w * h)
        for i in 0..<(w * h) {
            if monochrome { gray[i] = px[i] } else {
                let r = Int(px[4 * i]), g = Int(px[4 * i + 1]), b = Int(px[4 * i + 2])
                gray[i] = UInt8((r * 299 + g * 587 + b * 114 + 500) / 1000)
            }
        }
        let paper = BlackAndWhite.background(gray, w, h, dpi: dpi)
        let ink = BlackAndWhite.ink(gray: gray, sharp: nil, tone: BlackAndWhite.holdsTones(gray), width: w, height: h,
                                    dpi: dpi, removeShadows: true)
        let reachPx = max(1, Int((0.004 * dpi).rounded()))
        let printNear = LayeredScan.minFilter(ink, w, h, radius: reachPx)        // 0 within reach of print
        // What black and white would take for ink, but isn't print.
        var junk = [UInt8](repeating: 255, count: w * h)
        for i in 0..<(w * h) {
            let b = Int(paper[i])
            if ink[i] != 0, gray[i] < 128 || Int(gray[i]) < b - max(20, b * 12 / 100) { junk[i] = 0 }
        }
        // Its soft rim and colored fringe go with it.
        let junkNear = LayeredScan.minFilter(junk, w, h, radius: max(reachPx, Int((0.01 * dpi).rounded())))
        let clean = BlackAndWhite.cleanLevel(paper)
        // The page's paper color: the mean of clean paper away from any ink.
        var sum = [Double](repeating: 0, count: channels), n = 0.0
        for i in stride(from: 0, to: w * h, by: 7) where Int(paper[i]) >= clean && printNear[i] != 0 && junkNear[i] != 0
            && Int(gray[i]) >= Int(paper[i]) - 20 {
            for c in 0..<channels { sum[c] += Double(px[i * channels + c]) }
            n += 1
        }
        let paperColor: [UInt8] = (0..<channels).map { c in
            n > 0 ? UInt8(min(255, (sum[c] / n).rounded())) : UInt8(min(255, clean + 20))
        }
        // Shadowed paper is brought up to that color's own gray, so what is painted and
        // what is evened out meet without a step.
        let paperRef = channels == 1 ? Double(paperColor[0])
            : (Double(paperColor[0]) * 299 + Double(paperColor[1]) * 587 + Double(paperColor[2]) * 114) / 1000
        let floor = paperRef * 0.35
        let picture = BlackAndWhite.pictureMap(paper, w, h, dpi: dpi)
        for i in 0..<(w * h) where !picture[i] {
            let isPrint = printNear[i] == 0
            let p = Double(paper[i])
            if !isPrint && (junkNear[i] == 0 || p < floor) {
                for c in 0..<channels { px[i * channels + c] = paperColor[c] }
            } else if p < paperRef {
                // Paper is never brought up past the paper's color: beside a dark mark the
                // paper map runs dark, and evening out by it would leave a white rim.
                let f = paperRef / max(1, p)
                for c in 0..<channels {
                    let v = Double(px[i * channels + c]) * f
                    px[i * channels + c] = UInt8(min(isPrint ? 255 : Double(paperColor[c]), v).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * channels, bytesPerRow: w * channels,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: monochrome ? CGImageAlphaInfo.none.rawValue
                                                                     : CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Components

    struct Blob {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, count = 0
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    /// The 8-connected groups of ink (0) of a page, from its runs.
    struct Components {
        var blobs: [Blob] = []
        private var runStart: [Int32] = [], runEnd: [Int32] = [], runRow: [Int32] = []
        private var runsOf: [[Int]] = []

        init(_ p: [UInt8], _ w: Int, _ h: Int) {
            var parent: [Int32] = []
            func find(_ i: Int32) -> Int32 {
                var r = i
                while parent[Int(r)] != r { r = parent[Int(r)] }
                var c = i
                while parent[Int(c)] != r { let n = parent[Int(c)]; parent[Int(c)] = r; c = n }
                return r
            }
            var prevLo = 0, prevHi = 0
            p.withUnsafeBufferPointer { g in
                for y in 0..<h {
                    let lo = runStart.count
                    var x = 0
                    let base = y * w
                    while x < w {
                        if g[base + x] == 0 {
                            let s = x
                            while x < w, g[base + x] == 0 { x += 1 }
                            runStart.append(Int32(s)); runEnd.append(Int32(x - 1)); runRow.append(Int32(y))
                            parent.append(Int32(runStart.count - 1))
                        } else { x += 1 }
                    }
                    let hi = runStart.count
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
            }
            var index = [Int32](repeating: -1, count: runStart.count)
            for i in 0..<runStart.count {
                let r = Int(find(Int32(i)))
                if index[r] < 0 { index[r] = Int32(blobs.count); blobs.append(Blob()); runsOf.append([]) }
                let k = Int(index[r])
                let x0 = Int(runStart[i]), x1 = Int(runEnd[i]), y = Int(runRow[i])
                blobs[k].minX = min(blobs[k].minX, x0); blobs[k].maxX = max(blobs[k].maxX, x1)
                blobs[k].minY = min(blobs[k].minY, y); blobs[k].maxY = max(blobs[k].maxY, y)
                blobs[k].count += x1 - x0 + 1
                runsOf[k].append(i)
            }
            self.width = w
        }
        private var width = 0

        /// Paint blob `k` paper.
        func clear(_ k: Int, in p: inout [UInt8]) {
            for i in runsOf[k] {
                let row = Int(runRow[i]) * width
                for x in Int(runStart[i])...Int(runEnd[i]) { p[row + x] = 255 }
            }
        }
    }
}
