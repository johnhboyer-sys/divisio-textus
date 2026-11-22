import Foundation
import CoreGraphics

/// Flatten pages: straightens text lines that curve into the binding, in the style of
/// Leptonica's dewarp. For each output page:
///
/// 1. Find ink against the paper around it (so the fold's shadow is not ink), and its
///    connected pieces; the x-height is the commonest piece height.
/// 2. Chain letter-sized pieces into text lines (never across the gap between two columns)
///    and trace each line's baseline from the bottoms of its letters (descenders left out),
///    smoothed by a penalized spline.
/// 3. Model the vertical disparity: each long line's baseline less its height at the
///    outer end of the text, fitted column by column as a quadratic down the page.
/// 4. Measure how letters narrow toward the gutter and widen them back, taking the room
///    from the blank margin by the gutter.
/// 5. Remap. Where the shift would push print out at the crop's top or bottom edge it
///    fades to nothing at that edge, and the widening ends at the gutter edge, so no
///    print leaves the crop. A layered scan is measured on its text layer and both its
///    layers take the same warp (see LayeredScan.textPages).
///
/// A page is left as it is (nil) when its text is too small to trace, it has few long
/// lines, it holds a figure, its lines are already straight, the model is unsure, or
/// keeping print in the crop would stretch letters.
enum Flatten {

    enum Outcome: String {
        case flattened, tooSmall, fewLines, figure, straight, unsure, unsafe
    }

    /// What the analysis of one page found; for the score and the tests.
    struct Report {
        var outcome: Outcome
        var xHeight = 0.0
        var lines = 0
        /// Median over long lines of the RMS distance of the traced baseline from a straight line, px.
        var curl = 0.0
        /// How far the lines' gutter ends leave the straight line through the rest (the 75th
        /// percentile over long lines), px.
        var droop = 0.0
        /// RMS misfit of the model to the traced lines, px.
        var misfit = 0.0
        var maxShift = 0.0
        /// Letter width near the gutter over the middle's, before widening (1 = none).
        var squash = 1.0
        var stretchPx = 0.0
        var note = ""
        /// The model, when the page is flattened.
        var model: Model?
        /// The long lines traced, for drawing.
        var traced: [Line] = []
    }

    // Thresholds, in x-heights unless said.
    static let minXHeight = 6.0          // px: smaller text is too coarse to trace
    static let minLongLines = 6
    static let straightDroop = 0.15      // lines' gutter ends this close to straight: already straight
    static let maxMisfit = 0.10          // model misfit over this: unsure
    static let maxMisfitShare = 0.25     // ... or over this share of the droop
    static let maxSlopeY = 0.08          // vertical stretch or squash of letters
    static let minSquash = 0.96          // letters this much narrower or more get widened

    /// `image` with the print in each region (pixels, top-left origin) flattened, and which
    /// regions changed; nil when none did. `gutterOnRight` is nil when not known. The image
    /// keeps its color space, so a region left as it is keeps its pixels exactly.
    static func pages(_ image: CGImage, regions: [(rect: CGRect, gutterOnRight: Bool?)]) -> (image: CGImage, changed: [Bool])? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let px = Pixels(image) else { return nil }
        var out = px.data
        var changed = [Bool](repeating: false, count: regions.count)
        for (k, r) in regions.enumerated() {
            guard let (rect, model) = regionModel(px, r) else { continue }
            remap(&out, from: px, x0: rect.x, y0: rect.y, rw: rect.w, rh: rect.h, model: model)
            changed[k] = true
        }
        guard changed.contains(true), let made = px.image(out) else { return nil }
        return (made, changed)
    }

    /// The model `pages` would use for each region; nil where it leaves the region as it is.
    static func models(_ image: CGImage, regions: [(rect: CGRect, gutterOnRight: Bool?)]) -> [Model?] {
        guard let px = Pixels(image) else { return regions.map { _ in nil } }
        return regions.map { regionModel(px, $0)?.model }
    }

    private static func regionModel(_ px: Pixels, _ r: (rect: CGRect, gutterOnRight: Bool?))
        -> (rect: (x: Int, y: Int, w: Int, h: Int), model: Model)? {
        let w = px.width, h = px.height
        let rect = r.rect.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isNull, rect.width >= 32, rect.height >= 32 else { return nil }
        let x0 = Int(rect.minX), y0 = Int(rect.minY), rw = Int(rect.width), rh = Int(rect.height)
        let outside = Outside(above: y0 > 0 ? px.gray(x0, y0 - 1, rw, 1) : nil,
                              below: y0 + rh < h ? px.gray(x0, y0 + rh, rw, 1) : nil)
        let (model, _) = analyze(px.gray(x0, y0, rw, rh), width: rw, height: rh, gutterOnRight: r.gutterOnRight, outside: outside)
        return model.map { ((x0, y0, rw, rh), $0) }
    }

    /// One page's analysis alone, read from the image as `pages` reads it; for the score.
    static func report(_ image: CGImage, gutterOnRight: Bool?) -> Report {
        guard let px = Pixels(image) else { return Report(outcome: .tooSmall) }
        return report(px.gray(0, 0, image.width, image.height), width: image.width, height: image.height,
                      gutterOnRight: gutterOnRight)
    }

    /// One page's analysis alone, on its gray pixels; for the score.
    static func report(_ g: [UInt8], width: Int, height: Int, gutterOnRight: Bool?) -> Report {
        analyze(g, width: width, height: height, gutterOnRight: gutterOnRight).1
    }

    /// The rows just outside a region, above and below, where the image has them. A piece
    /// of print on the region's edge row is cut by the crop only if ink goes on there.
    struct Outside {
        var above: [UInt8]? = nil
        var below: [UInt8]? = nil
    }

    /// Which side of a crop the gutter is on: nil for a single page.
    static func gutterOnRight(_ crop: CropRect, of page: BookPage) -> Bool? {
        let c = crop.normalized()
        return page.isSpread ? c.x + c.width / 2 < page.splitX : nil
    }

    // MARK: Gray canvases (the layers of a layered scan)

    /// The pixels of a region of an 8-bit gray canvas (top-left rows).
    static func cut(_ g: [UInt8], width w: Int, _ x0: Int, _ y0: Int, _ rw: Int, _ rh: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: rw * rh)
        for y in 0..<rh { for x in 0..<rw { out[y * rw + x] = g[(y0 + y) * w + x0 + x] } }
        return out
    }

    /// The model for a region of an 8-bit gray canvas, nil when it is left as it is.
    /// `guardGray`, a canvas of the same size, holds print that must stay in the region too
    /// (another layer's); the lines are traced on `g` alone.
    static func model(gray g: [UInt8], width w: Int, height h: Int, region r: (x: Int, y: Int, w: Int, h: Int),
                      gutterOnRight: Bool?, guardGray: [UInt8]? = nil) -> Model? {
        guard r.w >= 32, r.h >= 32 else { return nil }
        let edge = guardGray ?? g
        let outside = Outside(above: r.y > 0 ? cut(edge, width: w, r.x, r.y - 1, r.w, 1) : nil,
                              below: r.y + r.h < h ? cut(edge, width: w, r.x, r.y + r.h, r.w, 1) : nil)
        return analyze(cut(g, width: w, r.x, r.y, r.w, r.h), width: r.w, height: r.h, gutterOnRight: gutterOnRight,
                       outside: outside, guardGray: guardGray.map { cut($0, width: w, r.x, r.y, r.w, r.h) }).0
    }

    /// A region of an 8-bit gray canvas warped by `model`: its own r.w × r.h pixels.
    static func warped(gray g: [UInt8], width w: Int, region r: (x: Int, y: Int, w: Int, h: Int), model: Model) -> [UInt8] {
        let px = Pixels(gray: cut(g, width: w, r.x, r.y, r.w, r.h), width: r.w, height: r.h)
        var out = px.data
        remap(&out, from: px, x0: 0, y0: 0, rw: r.w, rh: r.h, model: model)
        return out
    }

    /// `image` (one output page) warped by `model`, made for it or scaled to it (`Model.scaled`).
    static func apply(_ model: Model, to image: CGImage) -> CGImage? {
        guard let px = Pixels(image), model.ux.count == image.width else { return nil }
        var out = px.data
        remap(&out, from: px, x0: 0, y0: 0, rw: image.width, rh: image.height, model: model)
        return px.image(out)
    }

    // MARK: Model

    struct Model {
        var gx: [Double]          // grid columns (region px)
        var gy: [Double]          // grid rows
        var v: [Double]           // gy.count × gx.count: input row = output row + v
        var ux: [Double]          // per output column: input column

        /// The shift at input column `x`, output row `y`.
        func shift(_ x: Double, _ y: Double) -> Double {
            let step = gx.count > 1 ? gx[1] - gx[0] : 1
            let fx = max(0, min(Double(gx.count - 1), x / step)), fy = max(0, min(Double(gy.count - 1), y / step))
            let k = min(gx.count - 2, Int(fx)), j = min(gy.count - 2, Int(fy))
            let tx = fx - Double(k), ty = fy - Double(j), n = gx.count
            let top = v[j * n + k] * (1 - tx) + v[j * n + k + 1] * tx
            let bottom = v[(j + 1) * n + k] * (1 - tx) + v[(j + 1) * n + k + 1] * tx
            return top * (1 - ty) + bottom * ty
        }

        /// Where the input point (x, y) lands in the output, roughly (for the score).
        func forward(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            var lo = 0, hi = ux.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if ux[mid] < x { lo = mid + 1 } else { hi = mid } }
            var yo = y
            for _ in 0..<3 { yo = y - shift(x, yo) }
            return (Double(lo), yo)
        }

        /// The same model for the page drawn `s` times as large, `width` columns wide.
        func scaled(_ s: Double, width: Int) -> Model {
            let n = ux.count
            let u = (0..<max(1, width)).map { x -> Double in
                let f = min(Double(n - 1), max(0, Double(x) / s))
                let i = min(max(0, n - 2), Int(f)), t = f - Double(i)
                let v = n > 1 ? ux[i] * (1 - t) + ux[i + 1] * t : ux.first ?? 0
                return min(Double(width - 1), max(0, v * s))
            }
            return Model(gx: gx.map { $0 * s }, gy: gy.map { $0 * s }, v: v.map { $0 * s }, ux: u)
        }
    }

    /// `outside`: the rows beyond the region's top and bottom (of `guardGray` when given).
    /// `guardGray`: the region in another layer, whose print must stay in it too.
    static func analyze(_ g: [UInt8], width w: Int, height h: Int, gutterOnRight: Bool?,
                        outside: Outside = Outside(), guardGray: [UInt8]? = nil) -> (Model?, Report) {
        var rep = Report(outcome: .tooSmall)
        func inkOf(_ g: [UInt8]) -> (ink: [Bool], bg: [UInt8]) {
            let bg = background(g, w, h)
            var ink = [Bool](repeating: false, count: w * h)
            for i in 0..<(w * h) where bg[i] >= 60 && Int(g[i]) * 255 < 150 * Int(bg[i]) { ink[i] = true }
            return (ink, bg)
        }
        let (ink, bg) = inkOf(g)
        let comps = components(ink, w, h)

        // x-height: the commonest height of letter-like pieces.
        var hist = [Int](repeating: 0, count: max(8, h / 15 + 2))
        for c in comps where c.h >= 4 && c.h < hist.count && c.w >= 2 && c.w <= 3 * c.h { hist[c.h] += 1 }
        var best = 0, bestCount = 0
        for k in 1..<(hist.count - 1) {
            let n = hist[k - 1] + 2 * hist[k] + hist[k + 1]
            if n > bestCount { bestCount = n; best = k }
        }
        let xh = Double(best)
        rep.xHeight = xh
        guard xh >= minXHeight, bestCount >= 60 else { return (nil, rep) }

        // A figure: a big piece, or much ink in pieces far taller than letters.
        var bigInk = 0
        for c in comps {
            if Double(c.w) > 10 * xh && Double(c.h) > 10 * xh {
                rep.outcome = .figure; rep.note = "piece \(c.x0),\(c.y0) \(c.w)x\(c.h)"; return (nil, rep)
            }
            if Double(c.h) > 4 * xh && Double(c.w) > 2 * xh { bigInk += c.n }
        }
        if bigInk * 50 > w * h { rep.outcome = .figure; rep.note = "big ink \(bigInk)"; return (nil, rep) }

        // Text lines.
        let letters = comps.filter {
            Double($0.h) >= 0.7 * xh && Double($0.h) <= 2.3 * xh && Double($0.w) >= 0.2 * xh && Double($0.w) <= 4 * xh
        }
        let gaps = columnGaps(letters, xh: xh, width: w)
        var traced = textLines(letters, xh: xh, gaps: gaps)
        rep.note = "letters \(letters.count) lines \(traced.count)" + (gaps.isEmpty ? "" : " columns \(gaps.count + 1)")
        traced = traced.filter { $0.misfit <= 0.12 * xh }
        rep.note += " fit \(traced.count)"
        rep.outcome = .fewLines
        guard let lo = traced.map(\.a).min(), let hi = traced.map(\.b).max(), hi - lo > 20 * xh else { return (nil, rep) }
        let span = hi - lo
        let long = traced.filter { $0.b - $0.a >= 0.6 * span }
        rep.lines = long.count
        rep.traced = long
        guard long.count >= minLongLines else { return (nil, rep) }

        // Which end is the gutter: where the lines bend most.
        let onRight = gutterOnRight ?? {
            var l = 0.0, r = 0.0
            for line in long {
                let s = line.b - line.a
                let mid = (line.at(line.a + 0.65 * s) - line.at(line.a + 0.35 * s)) / (0.3 * s)
                l += abs((line.at(line.a + 0.15 * s) - line.at(line.a)) / (0.15 * s) - mid)
                r += abs((line.at(line.b) - line.at(line.b - 0.15 * s)) / (0.15 * s) - mid)
            }
            return r >= l
        }()

        // Curl of the long lines: is there anything to do?
        let curls = long.map { $0.curl() }.sorted()
        rep.curl = curls[curls.count / 2]
        let droops = long.map { $0.droop(gutterOnRight: onRight) }.sorted()
        rep.droop = droops[(3 * droops.count) / 4]
        guard rep.droop >= straightDroop * xh else { rep.outcome = .straight; return (nil, rep) }

        // Vertical disparity: each line less its height at the outer end of the text.
        let xRef = onRight ? lo + 0.05 * span : hi - 0.05 * span
        let ref = long.filter { $0.a <= xRef + 2 * xh && $0.b >= xRef - 2 * xh }
        rep.outcome = .fewLines
        rep.note += " ref \(ref.count)"
        guard ref.count >= minLongLines else { return (nil, rep) }
        let ys = ref.map { $0.at(xRef) }
        guard let yTop = ys.min(), let yBot = ys.max(), yBot - yTop > 8 * xh else { return (nil, rep) }
        let pitch = (yBot - yTop) / Double(max(1, ref.count - 1))

        let step = max(4.0, xh.rounded())
        let gx = stride(from: 0.0, through: Double(w - 1) + step, by: step).map { min($0, Double(w - 1)) }
        let gy = stride(from: 0.0, through: Double(h - 1) + step, by: step).map { min($0, Double(h - 1)) }
        // Per grid column: the fitted quadratic, or nil where too few lines cover it.
        var fits = [[Double]?](repeating: nil, count: gx.count)
        var misfitSum = 0.0, misfitN = 0
        let yMid = (yTop + yBot) / 2, yHalf = (yBot - yTop) / 2
        for (k, x) in gx.enumerated() {
            var pts: [(t: Double, d: Double)] = []
            for (i, line) in ref.enumerated() where x >= line.a - xh && x <= line.b + xh {
                pts.append(((ys[i] - yMid) / yHalf, line.at(x) - ys[i]))
            }
            guard pts.count >= 5 else { continue }
            let degree = pts.count >= 8 ? 2 : 1
            guard var c = polyfit(pts, degree: degree) else { continue }
            // One robust pass: lines far off the fit (a misread line) are left out.
            let res = pts.map { abs($0.d - poly(c, $0.t)) }
            let mad = res.sorted()[res.count / 2]
            let keep = pts.indices.filter { res[$0] <= max(0.08 * xh, 3 * 1.4826 * mad) }
            if keep.count < pts.count, keep.count >= 5, let c2 = polyfit(keep.map { pts[$0] }, degree: degree) { c = c2 }
            for p in keep.map({ pts[$0] }) { let e = p.d - poly(c, p.t); misfitSum += e * e; misfitN += 1 }
            fits[k] = c
        }
        // Columns beyond the text take the nearest fitted column's values.
        guard let firstFit = fits.firstIndex(where: { $0 != nil }), let lastFit = fits.lastIndex(where: { $0 != nil }) else {
            return (nil, rep)
        }
        for k in fits.indices where fits[k] == nil {
            if k < firstFit { fits[k] = fits[firstFit] } else if k > lastFit { fits[k] = fits[lastFit] } else {
                var a = k - 1
                while fits[a] == nil { a -= 1 }
                fits[k] = fits[a]
            }
        }
        rep.misfit = misfitN > 0 ? (misfitSum / Double(misfitN)).squareRoot() : 0

        // The grid: the fit between the outermost lines, held level a line pitch beyond them.
        let nc = gx.count
        var v = [Double](repeating: 0, count: gy.count * nc)
        let yA = max(0, yTop - pitch), yB = min(Double(h - 1), yBot + pitch)
        for (j, y) in gy.enumerated() {
            let t = (min(max(y, yA), yB) - yMid) / yHalf
            for k in gx.indices { v[j * nc + k] = poly(fits[k]!, t) }
        }
        // Smoothed across columns.
        var smooth = v
        for j in gy.indices {
            for k in gx.indices {
                var s = 0.0, n = 0.0
                for dk in -1...1 {
                    let kk = min(max(k + dk, 0), nc - 1)
                    let wt = Double(2 - abs(dk))
                    s += wt * v[j * nc + kk]; n += wt
                }
                smooth[j * nc + k] = s / n
            }
        }
        v = smooth
        rep.maxShift = v.map(abs).max() ?? 0
        guard rep.maxShift.isFinite else { rep.outcome = .unsure; rep.note = "not finite"; return (nil, rep) }

        // Unsure: the model misses the lines it was made from, or would stretch letters.
        if rep.misfit > maxMisfit * xh || rep.misfit > maxMisfitShare * rep.droop {
            rep.outcome = .unsure; rep.note = "misfit"; return (nil, rep)
        }
        // Print: every piece from a full stop up, a drop capital or a rule too, in this layer
        // and the guarded one; not specks, nor what the crop already cuts: a piece on the
        // region's edge row with ink beyond it, such as the bed or a shadow. On the image's
        // own edge nothing is beyond, so a piece there is print.
        // A lone speck, no bigger than half an x-height with no other print within two, is
        // dirt: a full stop or a dot always sits by a letter (not by the bed or a shadow).
        let (guardComps, guardBg): ([Comp], [UInt8]) = guardGray.map { gg in
            let (gi, gb) = inkOf(gg)
            return (components(gi, w, h), gb)
        } ?? (comps, bg)
        func cutByCrop(_ c: Comp) -> Bool {
            func inkBeyond(_ row: [UInt8]?, _ y: Int) -> Bool {
                guard let row else { return false }
                for x in max(0, c.x0 - 1)...min(w - 1, c.x0 + c.w) where Int(row[x]) * 255 < 150 * Int(guardBg[y * w + x]) {
                    return true
                }
                return false
            }
            return (c.y0 == 0 && inkBeyond(outside.above, 0)) || (c.y0 + c.h == h && inkBeyond(outside.below, h - 1))
        }
        let cut = guardComps.map(cutByCrop)
        func lone(_ c: Comp) -> Bool {
            guard Double(c.w) <= 0.5 * xh, Double(c.h) <= 0.5 * xh else { return false }
            let r = 2 * xh
            return !guardComps.indices.contains { i in
                let o = guardComps[i]
                return !cut[i] && (o.x0 != c.x0 || o.y0 != c.y0) && Double(o.x0) <= Double(c.x0 + c.w) + r
                    && Double(o.x0 + o.w) >= Double(c.x0) - r && Double(o.y0) <= Double(c.y0 + c.h) + r
                    && Double(o.y0 + o.h) >= Double(c.y0) - r
            }
        }
        let edgeInk = guardComps.indices.filter {
            let c = guardComps[$0]
            return Double(c.h) >= 0.2 * xh && c.n >= 4 && !cut[$0] && !lone(c)
        }.map { guardComps[$0] }
        // Grid cells holding ink: only there does a stretch show (blank paper may stretch).
        // The guarded layer's print counts too (a stamp or a big letter only in color).
        var inked = [Bool](repeating: false, count: gy.count * nc)
        for c in comps.filter({ $0.n >= 4 }) + (guardGray == nil ? [] : edgeInk) {
            let k0 = max(0, Int(Double(c.x0) / step)), k1 = min(nc - 1, Int(Double(c.x0 + c.w) / step) + 1)
            let j0 = max(0, Int(Double(c.y0) / step)), j1 = min(gy.count - 1, Int(Double(c.y0 + c.h) / step) + 1)
            guard k0 <= k1, j0 <= j1 else { continue }
            for j in j0...j1 { for k in k0...k1 { inked[j * nc + k] = true } }
        }
        func steepest(_ v: [Double]) -> (slope: Double, x: Double, y: Double) {
            var worst = (0.0, 0.0, 0.0)
            for j in 1..<gy.count {
                let dy = gy[j] - gy[j - 1]
                guard dy > 0 else { continue }
                for k in gx.indices where inked[j * nc + k] || inked[(j - 1) * nc + k] {
                    let s = abs(v[j * nc + k] - v[(j - 1) * nc + k]) / dy
                    if s > worst.0 { worst = (s, gx[k], gy[j]) }
                }
            }
            return worst
        }
        let st = steepest(v)
        if st.slope > maxSlopeY {
            rep.outcome = .unsure; rep.note = "slope \(st.slope) at \(Int(st.x)),\(Int(st.y))"; return (nil, rep)
        }

        // Print must not leave the region at its top or bottom edge: where the shift there
        // would push ink out, the shift fades to nothing at the edge instead, if it can do
        // so without stretching letters.
        func pushesInkOut() -> (top: Bool, bottom: Bool) {
            var out = (top: false, bottom: false)
            for c in edgeInk {
                for (k, x) in gx.enumerated() where Double(c.x0) <= x + step && Double(c.x0 + c.w) >= x - step {
                    let top = v[k], bottom = v[(gy.count - 1) * nc + k]
                    if top > 0 && Double(c.y0) < top + 1 { if !out.top { rep.note += "ink \(c.x0),\(c.y0) \(c.w)x\(c.h); " }; out.top = true }
                    if bottom < 0 && Double(c.y0 + c.h - 1) > Double(h - 1) + bottom - 1 {
                        if !out.bottom { rep.note += "ink \(c.x0),\(c.y0) \(c.w)x\(c.h); " }; out.bottom = true
                    }
                }
            }
            return out
        }
        let pushed = pushesInkOut()
        if pushed.top || pushed.bottom {
            for (j, y) in gy.enumerated() {
                let fade = pushed.top && y < yA ? y / max(1, yA)
                    : pushed.bottom && y > yB ? (Double(h - 1) - y) / max(1, Double(h - 1) - yB) : 1
                for k in gx.indices { v[j * nc + k] *= fade }
            }
            let sf = steepest(v)
            if sf.slope > maxSlopeY {
                rep.outcome = .unsafe; rep.note += "fade slope \(sf.slope) at \(Int(sf.x)),\(Int(sf.y))"; return (nil, rep)
            }
        }

        // Horizontal: letters narrowed toward the gutter are widened back.
        let ux = widening(long, print: guardComps.indices.filter { !cut[$0] }.map { guardComps[$0] }, xh: xh,
                          lo: lo, hi: hi, width: w, gutterOnRight: onRight, report: &rep)
        rep.outcome = .flattened
        let model = Model(gx: gx, gy: gy, v: v, ux: ux)
        rep.model = model
        return (model, rep)
    }

    /// Per output column, the input column: identity, or a widening of the band by the
    /// gutter where letters are narrower than in the middle of the lines. `print`: the
    /// pieces of ink in both layers that the crop does not cut.
    static func widening(_ lines: [Line], print: [Comp], xh: Double, lo: Double, hi: Double,
                         width w: Int, gutterOnRight: Bool, report rep: inout Report) -> [Double] {
        let identity = (0..<w).map(Double.init)
        let span = hi - lo
        let bins = 10
        var widths = [[Double]](repeating: [], count: bins)
        for line in lines {
            for c in line.letters where Double(c.h) <= 1.25 * xh {
                let t = ((Double(c.x0) + Double(c.w) / 2) - lo) / span
                let fromGutter = gutterOnRight ? 1 - t : t
                let b = min(bins - 1, max(0, Int(fromGutter * Double(bins))))
                widths[b].append(Double(c.w))
            }
        }
        func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[v.count / 2] }
        guard let mid = median(widths[3] + widths[4] + widths[5] + widths[6]), mid > 0 else { return identity }
        // Ratio per bin from the gutter in, never rising toward the gutter.
        var ratio = [Double](repeating: 1, count: bins)
        for b in 0..<3 {
            guard widths[b].count >= 30, let m = median(widths[b]) else { return identity }
            ratio[b] = min(1, m / mid)
        }
        ratio[1] = max(ratio[1], ratio[0]); ratio[2] = max(ratio[2], ratio[1])
        rep.squash = ratio[0]
        guard ratio[0] < minSquash else { return identity }

        // Stretch factor along the text, by input column, from the bins' ratios.
        let binW = span / Double(bins)
        func factor(_ x: Double) -> Double {
            let fromGutter = gutterOnRight ? hi - x : x - lo
            guard fromGutter < 3 * binW else { return 1 }
            let p = max(0, fromGutter / binW - 0.5)            // bin centres
            let b = Int(p), f = p - Double(b)
            let r = b >= 2 ? ratio[2] + (1 - ratio[2]) * min(1, 2 * (p - 2)) : ratio[b] + (ratio[b + 1] - ratio[b]) * f
            return 1 / max(0.6, r)
        }
        // Room: the margin between the text's gutter end and the region's gutter edge.
        let margin = gutterOnRight ? Double(w - 1) - hi : lo
        var extra = 0.0
        for k in 0..<Int(3 * binW) { extra += factor(gutterOnRight ? hi - Double(k) : lo + Double(k)) - 1 }
        // Print in the margin (a folio, a note) is squeezed at most 5%, blank paper 30%. A
        // piece running to the region's side edge is the bed or the fold's shadow, not print.
        var marginInk = false
        for c in print where c.n >= 4 && c.x0 > 0 && c.x0 + c.w < w {
            let cx0 = Double(c.x0), cx1 = Double(c.x0 + c.w - 1)
            if gutterOnRight ? cx1 > hi + xh : cx0 < lo - xh { marginInk = true; rep.note += " margin ink \(c.x0),\(c.y0)"; break }
        }
        let room = (marginInk ? 0.05 : 0.3) * margin
        guard room >= 1 else { return identity }
        let scale = min(1, room / max(extra, 1e-9))
        rep.stretchPx = extra * scale

        // Output position of each input column, then its inverse.
        // Walk from the outer side: up to the gutter band x is unchanged; across it each
        // input column takes 1 + scale * (factor - 1) output columns; the margin shrinks.
        var outPos = [Double](repeating: 0, count: w)
        if gutterOnRight {
            var pos = 0.0
            let bandStart = hi - 3 * binW
            for x in 0..<w {
                let xd = Double(x)
                if xd <= bandStart { pos = xd }
                else if xd <= hi { pos += 1 + scale * (factor(xd) - 1) }
                else { pos += (margin - rep.stretchPx) / max(1, margin) }
                outPos[x] = pos
            }
        } else {
            var pos = Double(w - 1)
            let bandStart = lo + 3 * binW
            for x in stride(from: w - 1, through: 0, by: -1) {
                let xd = Double(x)
                if xd >= bandStart { pos = xd }
                else if xd >= lo { pos -= 1 + scale * (factor(xd) - 1) }
                else { pos -= (margin - rep.stretchPx) / max(1, margin) }
                outPos[x] = pos
            }
        }
        // Invert: for each output column, the input column that lands there.
        var ux = identity
        var i = 0
        for x in 0..<w {
            let xd = Double(x)
            while i < w - 2 && outPos[i + 1] < xd { i += 1 }
            let a = outPos[i], b = outPos[min(w - 1, i + 1)]
            let f = b > a ? min(1, max(0, (xd - a) / (b - a))) : 0
            ux[x] = min(Double(w - 1), max(0, Double(i) + f))
        }
        return ux
    }

    // MARK: Lines

    struct Comp {
        var x0: Int, y0: Int, w: Int, h: Int, n: Int
        var bottom: Double { Double(y0 + h) }
        var cx: Double { Double(x0) + Double(w) / 2 }
    }

    struct Line {
        var letters: [Comp]
        var knots: [Double]
        var coef: [Double]
        var a: Double, b: Double         // traced extent
        var misfit: Double
        /// Baseline height at `x`, held level beyond the ends.
        func at(_ x: Double) -> Double {
            let xc = min(max(x, knots.first!), knots.last!)
            var k = 0
            while k < knots.count - 2 && knots[k + 1] < xc { k += 1 }
            let span = knots[k + 1] - knots[k]
            let f = span > 0 ? (xc - knots[k]) / span : 0
            return coef[k] * (1 - f) + coef[k + 1] * f
        }
        /// How far the baseline's gutter end lies off the straight line fitted to the other 70%.
        func droop(gutterOnRight: Bool) -> Double {
            let n = 28
            let xs = (0...n).map { gutterOnRight ? a + 0.7 * (b - a) * Double($0) / Double(n)
                                                 : b - 0.7 * (b - a) * Double($0) / Double(n) }
            let ys = xs.map(at)
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxx = 0.0, sxy = 0.0
            for (x, y) in zip(xs, ys) { sxx += (x - mx) * (x - mx); sxy += (x - mx) * (y - my) }
            let s = sxx > 0 ? sxy / sxx : 0
            let end = gutterOnRight ? b : a
            return abs(at(end) - (my + s * (end - mx)))
        }

        /// RMS distance of the baseline from its own straight line, sampled across its extent.
        func curl() -> Double {
            let n = 40
            let xs = (0...n).map { a + (b - a) * Double($0) / Double(n) }
            let ys = xs.map(at)
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxx = 0.0, sxy = 0.0
            for (x, y) in zip(xs, ys) { sxx += (x - mx) * (x - mx); sxy += (x - mx) * (y - my) }
            let s = sxx > 0 ? sxy / sxx : 0
            var ss = 0.0
            for (x, y) in zip(xs, ys) { let d = y - (my + s * (x - mx)); ss += d * d }
            return (ss / Double(xs.count)).squareRoot()
        }
    }

    /// The gaps between columns of text, as column ranges: runs at least an x-height wide that
    /// under a tenth as many letters cross as cross a usual column of the text, with text on
    /// both sides that at least half as many cross. A word space is never so for long.
    static func columnGaps(_ cs: [Comp], xh: Double, width w: Int) -> [ClosedRange<Int>] {
        guard w > 2 else { return [] }
        var cover = [Int](repeating: 0, count: w + 1)
        for c in cs { cover[max(0, c.x0)] += 1; cover[min(w, c.x0 + c.w)] -= 1 }
        for x in 1...w { cover[x] += cover[x - 1] }
        cover.removeLast()
        let used = cover.filter { $0 > 0 }.sorted()
        guard !used.isEmpty else { return [] }
        let usual = used[used.count / 2]
        let low = max(1, usual / 10), high = max(2, usual / 2)
        // Text on both sides: the first and last columns that many letters cross.
        guard let first = cover.firstIndex(where: { $0 >= high }), let last = cover.lastIndex(where: { $0 >= high }) else { return [] }
        var gaps: [ClosedRange<Int>] = []
        var x = first
        while x <= last {
            guard cover[x] <= low else { x += 1; continue }
            let start = x
            while x <= last, cover[x] <= low { x += 1 }
            if Double(x - start) >= xh, x <= last { gaps.append(start...(x - 1)) }
        }
        return gaps
    }

    /// Letters chained into lines, each with its traced baseline. Letters on either side of a
    /// gap between columns (`columnGaps`) are not chained.
    static func textLines(_ cs: [Comp], xh: Double, gaps: [ClosedRange<Int>] = []) -> [Line] {
        let n = cs.count
        guard n > 1 else { return [] }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var c = i
            while parent[c] != r { let x = parent[c]; parent[c] = r; c = x }
            return r
        }
        let byX = (0..<n).sorted { cs[$0].x0 < cs[$1].x0 }
        let reach = 2.5 * xh             // a wide word space in a justified line
        for (k, i) in byX.enumerated() {
            let a = cs[i]
            var m = k + 1
            while m < n, Double(cs[byX[m]].x0) <= Double(a.x0 + a.w) + reach {
                let j = byX[m], b = cs[j]
                m += 1
                let overlap = min(a.y0 + a.h, b.y0 + b.h) - max(a.y0, b.y0)
                guard 2 * overlap >= min(a.h, b.h), abs(a.bottom - b.bottom) <= 0.6 * xh else { continue }
                let between = gaps.contains { gap in
                    let mid = (gap.lowerBound + gap.upperBound) / 2
                    return min(a.x0 + a.w, b.x0 + b.w) <= mid && max(a.x0, b.x0) >= mid
                }
                guard !between else { continue }
                let ra = find(i), rb = find(j)
                if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
            }
        }
        var groups = [Int: [Comp]]()
        for i in 0..<n { groups[find(i), default: []].append(cs[i]) }
        var out: [Line] = []
        for (_, g0) in groups where g0.count >= 10 {
            let g = g0.sorted { $0.cx < $1.cx }
            // Letters on the baseline: within a little of the running median of bottoms.
            let bottoms = g.map(\.bottom)
            var px: [Double] = [], py: [Double] = []
            for i in g.indices {
                let lo = max(0, i - 4), hi = min(g.count - 1, i + 4)
                let s = bottoms[lo...hi].sorted()
                let med = s[s.count / 2]
                if bottoms[i] <= med + 0.15 * xh && bottoms[i] >= med - 0.25 * xh { px.append(g[i].cx); py.append(bottoms[i]) }
            }
            guard px.count >= 8, let a = px.first, let b = px.last, b - a >= 8 * xh else { continue }
            let segments = min(40, max(2, Int(((b - a) / (4 * xh)).rounded())))
            let knots = (0...segments).map { a + (b - a) * Double($0) / Double(segments) }
            guard var coef = penalizedFit(px, py, knots: knots, lambda: 8) else { continue }
            var line = Line(letters: g, knots: knots, coef: coef, a: a, b: b, misfit: 0)
            // One robust pass.
            let res = zip(px, py).map { abs($1 - line.at($0)) }
            let keep = res.indices.filter { res[$0] <= max(1.5, 0.1 * xh) }
            if keep.count < px.count, keep.count >= 8,
               let c2 = penalizedFit(keep.map { px[$0] }, keep.map { py[$0] }, knots: knots, lambda: 8) {
                coef = c2
                line.coef = c2
            }
            let r2 = keep.map { let d = py[$0] - line.at(px[$0]); return d * d }
            line.misfit = r2.isEmpty ? .infinity : (r2.reduce(0, +) / Double(r2.count)).squareRoot()
            out.append(line)
        }
        return out
    }

    /// Least squares on piecewise-linear hat functions at `knots`, with a penalty `lambda`
    /// on second differences of the coefficients.
    static func penalizedFit(_ xs: [Double], _ ys: [Double], knots: [Double], lambda: Double) -> [Double]? {
        let m = knots.count
        var A = [Double](repeating: 0, count: m * m), rhs = [Double](repeating: 0, count: m)
        for (x, y) in zip(xs, ys) {
            var k = 0
            while k < m - 2 && knots[k + 1] < x { k += 1 }
            let span = knots[k + 1] - knots[k]
            let f = span > 0 ? min(1, max(0, (x - knots[k]) / span)) : 0
            let w0 = 1 - f, w1 = f
            A[k * m + k] += w0 * w0; A[k * m + k + 1] += w0 * w1
            A[(k + 1) * m + k] += w0 * w1; A[(k + 1) * m + k + 1] += w1 * w1
            rhs[k] += w0 * y; rhs[k + 1] += w1 * y
        }
        if m >= 3 {
            for k in 1..<(m - 1) {
                let idx = [k - 1, k, k + 1], wts = [1.0, -2.0, 1.0]
                for p in 0..<3 { for q in 0..<3 { A[idx[p] * m + idx[q]] += lambda * wts[p] * wts[q] } }
            }
        }
        return solve(A, rhs, m)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ A0: [Double], _ b0: [Double], _ n: Int) -> [Double]? {
        var A = A0, b = b0
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<max(c + 1, n) where abs(A[r * n + c]) > abs(A[p * n + c]) { p = r }
            guard abs(A[p * n + c]) > 1e-12 else { return nil }
            if p != c {
                for k in 0..<n { A.swapAt(c * n + k, p * n + k) }
                b.swapAt(c, p)
            }
            for r in (c + 1)..<max(c + 1, n) {
                let f = A[r * n + c] / A[c * n + c]
                guard f != 0 else { continue }
                for k in c..<n { A[r * n + k] -= f * A[c * n + k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<max(r + 1, n) { s -= A[r * n + k] * x[k] }
            x[r] = s / A[r * n + r]
        }
        return x
    }

    static func polyfit(_ pts: [(t: Double, d: Double)], degree: Int) -> [Double]? {
        let m = degree + 1
        var A = [Double](repeating: 0, count: m * m), b = [Double](repeating: 0, count: m)
        for p in pts {
            var pw = [Double](repeating: 1, count: m)
            for i in 1..<m { pw[i] = pw[i - 1] * p.t }
            for i in 0..<m {
                b[i] += pw[i] * p.d
                for j in 0..<m { A[i * m + j] += pw[i] * pw[j] }
            }
        }
        guard var c = solve(A, b, m) else { return nil }
        while c.count < 3 { c.append(0) }
        return c
    }

    static func poly(_ c: [Double], _ t: Double) -> Double { c[0] + t * (c[1] + t * c[2]) }

    // MARK: Pixels

    /// Paper level around each pixel: the brightest in blocks about 1/50 of the longer
    /// side, the most of the 3×3 blocks around, spread back bilinearly.
    static func background(_ g: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        let block = max(8, max(w, h) / 50)
        let bw = (w + block - 1) / block, bh = (h + block - 1) / block
        var bmax = [UInt8](repeating: 0, count: bw * bh)
        for y in 0..<h {
            let row = (y / block) * bw
            for x in 0..<w { let k = row + x / block; if g[y * w + x] > bmax[k] { bmax[k] = g[y * w + x] } }
        }
        var bg = [Double](repeating: 0, count: bw * bh)
        for by in 0..<bh {
            for bx in 0..<bw {
                var m: UInt8 = 0
                for yy in max(0, by - 1)...min(bh - 1, by + 1) {
                    for xx in max(0, bx - 1)...min(bw - 1, bx + 1) { m = max(m, bmax[yy * bw + xx]) }
                }
                bg[by * bw + bx] = Double(m)
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let fy = max(0, min(Double(bh - 1), (Double(y) + 0.5) / Double(block) - 0.5))
            let y0 = Int(fy), y1 = min(bh - 1, y0 + 1), ty = fy - Double(y0)
            for x in 0..<w {
                let fx = max(0, min(Double(bw - 1), (Double(x) + 0.5) / Double(block) - 0.5))
                let x0 = Int(fx), x1 = min(bw - 1, x0 + 1), tx = fx - Double(x0)
                let top = bg[y0 * bw + x0] * (1 - tx) + bg[y0 * bw + x1] * tx
                let bot = bg[y1 * bw + x0] * (1 - tx) + bg[y1 * bw + x1] * tx
                out[y * w + x] = UInt8(min(255, top * (1 - ty) + bot * ty))
            }
        }
        return out
    }

    /// 8-connected pieces of ink, by runs.
    static func components(_ ink: [Bool], _ w: Int, _ h: Int) -> [Comp] {
        var rs: [Int32] = [], re: [Int32] = [], ry: [Int32] = [], parent: [Int32] = []
        func find(_ i: Int32) -> Int32 {
            var r = i
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = i
            while parent[Int(c)] != r { let n = parent[Int(c)]; parent[Int(c)] = r; c = n }
            return r
        }
        var prevLo = 0, prevHi = 0
        for y in 0..<h {
            let lo = rs.count
            var x = 0
            while x < w {
                if ink[y * w + x] {
                    let s = x
                    while x < w, ink[y * w + x] { x += 1 }
                    rs.append(Int32(s)); re.append(Int32(x - 1)); ry.append(Int32(y)); parent.append(Int32(rs.count - 1))
                } else { x += 1 }
            }
            let hi = rs.count
            var a = prevLo
            for b in lo..<hi {
                while a < prevHi, re[a] < rs[b] - 1 { a += 1 }
                var k = a
                while k < prevHi, rs[k] <= re[b] + 1 {
                    let ra = find(Int32(k)), rb = find(Int32(b))
                    if ra != rb { parent[Int(max(ra, rb))] = min(ra, rb) }
                    k += 1
                }
            }
            prevLo = lo; prevHi = hi
        }
        let n = rs.count
        var minX = [Int32](repeating: .max, count: n), maxX = [Int32](repeating: -1, count: n)
        var minY = [Int32](repeating: .max, count: n), maxY = [Int32](repeating: -1, count: n)
        var count = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let r = Int(find(Int32(i)))
            minX[r] = min(minX[r], rs[i]); maxX[r] = max(maxX[r], re[i])
            minY[r] = min(minY[r], ry[i]); maxY[r] = max(maxY[r], ry[i])
            count[r] += Int(re[i] - rs[i] + 1)
        }
        var out: [Comp] = []
        for i in 0..<n where parent[i] == Int32(i) {
            out.append(Comp(x0: Int(minX[i]), y0: Int(minY[i]), w: Int(maxX[i] - minX[i] + 1),
                            h: Int(maxY[i] - minY[i] + 1), n: count[i]))
        }
        return out
    }

    /// An image's 8-bit pixels in its own color space: one byte a pixel for gray, four for color.
    struct Pixels {
        let width: Int, height: Int, bpp: Int
        let space: CGColorSpace
        var data: [UInt8]

        init?(_ image: CGImage) {
            width = image.width; height = image.height
            let own = image.colorSpace
            if own?.model == .monochrome {
                bpp = 1; space = own ?? CGColorSpaceCreateDeviceGray()
            } else {
                bpp = 4; space = own?.model == .rgb ? own! : CGColorSpaceCreateDeviceRGB()
            }
            var buf = [UInt8](repeating: 255, count: width * height * bpp)
            let (w, h, b, sp) = (width, height, bpp, space)
            let ok = buf.withUnsafeMutableBytes { p -> Bool in
                guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * b,
                                          space: sp, bitmapInfo: b == 1 ? CGImageAlphaInfo.none.rawValue
                                                                        : CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            data = buf
        }

        /// 8-bit gray pixels as they are.
        init(gray: [UInt8], width: Int, height: Int) {
            self.width = width; self.height = height; bpp = 1
            space = CGColorSpaceCreateDeviceGray()
            data = gray
        }

        /// Luma of a region, top-left origin.
        func gray(_ x0: Int, _ y0: Int, _ rw: Int, _ rh: Int) -> [UInt8] {
            var g = [UInt8](repeating: 255, count: rw * rh)
            for y in 0..<rh {
                for x in 0..<rw {
                    let i = ((y0 + y) * width + x0 + x) * bpp
                    g[y * rw + x] = bpp == 1 ? data[i]
                        : UInt8((299 * Int(data[i]) + 587 * Int(data[i + 1]) + 114 * Int(data[i + 2])) / 1000)
                }
            }
            return g
        }

        func image(_ p: [UInt8]) -> CGImage? {
            guard let provider = CGDataProvider(data: Data(p) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * bpp, bytesPerRow: width * bpp,
                           space: space, bitmapInfo: CGBitmapInfo(rawValue: bpp == 1 ? CGImageAlphaInfo.none.rawValue
                                                                                   : CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// Output pixel (x, y) of the region takes the input at (ux[x], y + v(ux[x], y)), bilinearly.
    static func remap(_ out: inout [UInt8], from px: Pixels,
                      x0: Int, y0: Int, rw: Int, rh: Int, model m: Model) {
        let w = px.width, bpp = px.bpp, channels = min(3, px.bpp)
        let ncol = m.gx.count, nrow = m.gy.count
        let step = m.gx.count > 1 ? m.gx[1] - m.gx[0] : 1
        func gridIndex(_ p: Double, _ count: Int) -> (Int, Double) {
            let f = max(0, min(Double(count - 1), p / step))
            let i = min(count - 2, Int(f))
            return (max(0, i), f - Double(max(0, i)))
        }
        px.data.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for x in 0..<rw {
                    let xi = m.ux[x]
                    let (kc, fc) = gridIndex(xi, ncol)
                    let xa = Int(xi.rounded(.down)), fx = xi - Double(xa)
                    let xb = min(rw - 1, xa + 1)
                    for y in 0..<rh {
                        let (jr, fr) = gridIndex(Double(y), nrow)
                        let v00 = m.v[jr * ncol + kc], v01 = m.v[jr * ncol + min(ncol - 1, kc + 1)]
                        let v10 = m.v[min(nrow - 1, jr + 1) * ncol + kc], v11 = m.v[min(nrow - 1, jr + 1) * ncol + min(ncol - 1, kc + 1)]
                        let dv = (v00 * (1 - fc) + v01 * fc) * (1 - fr) + (v10 * (1 - fc) + v11 * fc) * fr
                        if abs(dv) < 0.02 && fx == 0 && xa == x { continue }   // unchanged
                        let yi = min(Double(rh - 1), max(0, Double(y) + dv))
                        let ya = Int(yi.rounded(.down)), fy = yi - Double(ya)
                        let yb = min(rh - 1, ya + 1)
                        let i00 = ((y0 + ya) * w + x0 + xa) * bpp, i01 = ((y0 + ya) * w + x0 + xb) * bpp
                        let i10 = ((y0 + yb) * w + x0 + xa) * bpp, i11 = ((y0 + yb) * w + x0 + xb) * bpp
                        let oi = ((y0 + y) * w + x0 + x) * bpp
                        for c in 0..<channels {
                            let top = Double(s[i00 + c]) * (1 - fx) + Double(s[i01 + c]) * fx
                            let bot = Double(s[i10 + c]) * (1 - fx) + Double(s[i11 + c]) * fx
                            o[oi + c] = UInt8(min(255, max(0, (top * (1 - fy) + bot * fy).rounded())))
                        }
                    }
                }
            }
        }
    }
}
