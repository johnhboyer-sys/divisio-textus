import Foundation
import CoreGraphics

/// Estimates page skew using the classic projection-profile method: at the
/// correct angle, text rows line up horizontally, so the horizontal darkness
/// profile has sharp peaks (lines) and deep valleys (gaps). We search angles
/// and pick the one that maximizes that contrast.
enum DeskewDetector {

    /// One ink pixel: its position (centered on the image middle) and how dark it
    /// is, 0…1, so a pixel only partly covered by a letter counts only partly.
    typealias Ink = (x: Double, y: Double, w: Double)

    /// Returns the CORRECTION angle in degrees: straighten the page by rotating
    /// it `+result` via `ImageTransform.rotate(image, degrees: result)` (or
    /// `rotateInPlace`). The profile search finds the angle the text lines run
    /// at (counter-clockwise positive), so the correction is its opposite.
    /// Range is limited to ±`maxDegrees` since scans are rarely worse.
    ///
    /// The method only works on text-like, line-structured content. When the
    /// page has no measurable line structure — a mostly-black/dense scan, a
    /// photo, a near-blank page — there is no reliable signal and forcing an
    /// angle badly skews the page, so we return 0 (leave it alone) in those cases.
    static func detect(_ cgImage: CGImage,
                       maxDegrees: Double = 6.0,
                       excludeCenterBand: Bool = true) -> Double {
        // Downsample, keeping enough detail to read the angle to a few hundredths
        // of a degree.
        guard let g = GrayBuffer(cgImage: cgImage, maxDim: 1000) else { return 0 }

        // Collect dark (content) pixels once, centered on the image middle.
        let threshold = g.paperLevel() * 0.7

        let cx = Double(g.width) / 2, cy = Double(g.height) / 2
        // For a full spread, ignore a central vertical band: the binding shadow
        // is a strong dark stripe that biases the profile. For a single half the
        // spine is at an edge (already trimmed by the caller), so don't exclude.
        let gutterHalf = excludeCenterBand ? Double(g.width) * 0.08 : 0
        var ink = [Bool](repeating: false, count: g.width * g.height)
        var consideredCount = 0
        for y in 0..<g.height {
            for x in 0..<g.width {
                if gutterHalf > 0 && abs(Double(x) - cx) < gutterHalf { continue }
                consideredCount += 1
                if Double(g.value(x, y)) < threshold { ink[y * g.width + x] = true }
            }
        }

        // Keep only ink in pieces the size of letters and words. A photograph, a
        // rule box or a scanner band is one tall piece whose square edges would
        // otherwise outvote the text, and pictures are not always set exactly
        // level with the text on the printed page. Specks are dropped too, and so
        // are the small bits of a picture's own texture inside its area.
        let tallest = max(20, Int(Double(max(g.width, g.height)) * 0.06))
        var label = [Int32](repeating: -1, count: ink.count)
        var pieces: [(count: Int, x0: Int, y0: Int, x1: Int, y1: Int)] = []
        var stack: [Int] = []
        for start in ink.indices where ink[start] && label[start] < 0 {
            let id = Int32(pieces.count)
            stack = [start]; label[start] = id
            var box = (count: 0, x0: Int.max, y0: Int.max, x1: Int.min, y1: Int.min)
            while let i = stack.popLast() {
                let px = i % g.width, py = i / g.width
                box.count += 1
                box.x0 = min(box.x0, px); box.x1 = max(box.x1, px); box.y0 = min(box.y0, py); box.y1 = max(box.y1, py)
                for dy in -1...1 {
                    let ny = py + dy
                    guard ny >= 0 && ny < g.height else { continue }
                    for dx in -1...1 {
                        let nx = px + dx
                        guard nx >= 0 && nx < g.width else { continue }
                        let n = ny * g.width + nx
                        if ink[n] && label[n] < 0 { label[n] = id; stack.append(n) }
                    }
                }
            }
            pieces.append(box)
        }
        // Pictures: tall pieces that fill much of their box (a ruled frame is
        // tall but nearly empty, and the text inside it still counts).
        let pictures = pieces.filter { p in
            let h = p.y1 - p.y0 + 1, w = p.x1 - p.x0 + 1
            return h >= tallest && Double(p.count) > 0.25 * Double(w * h)
        }
        let margin = max(g.width, g.height) / 100
        let keepPiece = pieces.map { p -> Bool in
            guard p.count >= 3, p.y1 - p.y0 < tallest else { return false }
            let mx = (p.x0 + p.x1) / 2, my = (p.y0 + p.y1) / 2
            return !pictures.contains { mx >= $0.x0 - margin && mx <= $0.x1 + margin && my >= $0.y0 - margin && my <= $0.y1 + margin }
        }
        var keep = [Bool](repeating: false, count: ink.count)
        var inkCount = 0
        for i in ink.indices where label[i] >= 0 && keepPiece[Int(label[i])] { keep[i] = true; inkCount += 1 }

        // The kept letters and the grey pixels right around them, each weighted by
        // its darkness: a letter's edge pixels carry where it sits to a fraction
        // of a pixel, which a pure black-and-white image rounds away. (On a short
        // line a small tilt rises less than a pixel end to end.)
        let paper = threshold / 0.7
        var dark: [Ink] = []
        dark.reserveCapacity(inkCount * 2)
        for y in 0..<g.height {
            for x in 0..<g.width {
                let i = y * g.width + x
                var near = keep[i]
                if !near {
                    for dy in -1...1 where !near {
                        let ny = y + dy
                        guard ny >= 0 && ny < g.height else { continue }
                        for dx in -1...1 where x + dx >= 0 && x + dx < g.width && keep[ny * g.width + x + dx] { near = true; break }
                    }
                }
                guard near else { continue }
                let w = min(1, max(0, (paper - Double(g.value(x, y))) / (paper * 0.8)))
                guard w > 0 else { continue }
                // Each pixel stands for a small square: place its point at a fixed
                // pseudo-random spot inside it. Points on the exact pixel grid all
                // fall at the same place between profile rows when the angle is
                // exactly 0°, which makes 0° score falsely sharp.
                dark.append((Double(x) + Self.spot(i) - cx, Double(y) + Self.spot(i &* 7919 &+ 1) - cy, w))
            }
        }

        // GATE 1: too little ink (near-blank) — nothing to align.
        let allInk = ink.lazy.filter { $0 }.count
        guard allInk > 50, consideredCount > 0 else { return 0 }

        let bins = g.height
        // Peakiness of the row profile of `points` at `deg`: the sum of squared
        // differences between neighbouring rows. Each pixel is shared between the
        // two rows it falls between, so the score changes smoothly with the angle.
        func peakiness(_ points: [Ink], _ deg: Double) -> Double {
            let rad = deg * .pi / 180
            let s = sin(rad), c = cos(rad)
            var profile = [Double](repeating: 0, count: bins + 1)
            for p in points {
                let ry = p.x * s + p.y * c + cy   // rotated y, shifted back into [0,height)
                let row = ry.rounded(.down), frac = ry - row
                let bin = Int(row)
                if bin >= 0 && bin < bins { profile[bin] += p.w * (1 - frac); profile[bin + 1] += p.w * frac }
            }
            var acc = 0.0
            for i in 1...bins {
                let d = profile[i] - profile[i - 1]
                acc += d * d
            }
            return acc
        }

        /// The angle `points` line up at, or nil when they show no clear line
        /// structure: real lines make one angle stand far above the rest of the
        /// sweep (text pages, even a few short centered lines, score 5–40 times
        /// the typical angle; plates and drawings under 1.5).
        func estimate(_ points: [Ink]) -> Double? {
            // 1. Coarse sweep over the whole page.
            var sweep: [(angle: Double, score: Double)] = []
            var a = -maxDegrees
            while a <= maxDegrees + 1e-9 { sweep.append((a, peakiness(points, a))); a += 0.25 }
            guard let coarse = sweep.max(by: { $0.score < $1.score }) else { return nil }
            let typical = sweep.map(\.score).sorted()[sweep.count / 2]
            guard typical > 0, coarse.score > typical * 3 else { return nil }

            // 2. Columns. Side-by-side columns rarely share baselines, and scoring
            //    them together rewards the angle that lines one column's rows up
            //    with the other's. Find the column gaps at the coarse angle and read
            //    each column's own angle; on a bowed page they differ, and the page
            //    gets their ink-weighted average, the turn that leaves no column far off.
            let columns = Self.columns(of: points, at: coarse.angle, width: g.width)

            // 3. For each column, a fine search around the coarse angle, then a
            //    least-squares parabola through five points 0.025° apart around
            //    the peak (steadier than three when the peak is broad: short lines).
            func fineAngle(_ points: [Ink]) -> Double {
                var best = (angle: coarse.angle, score: peakiness(points, coarse.angle))
                for k in -8...8 where k != 0 {
                    let x = coarse.angle + Double(k) * 0.05
                    let sc = peakiness(points, x)
                    if sc > best.score { best = (x, sc) }
                }
                let step = 0.025
                let xs = (-2...2).map { Double($0) * step }
                let ys = xs.map { peakiness(points, best.angle + $0) }
                let sxx = xs.reduce(0) { $0 + $1 * $1 }, sx4 = xs.reduce(0) { $0 + pow($1, 4) }
                let sy = ys.reduce(0, +), sxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
                let sxxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.0 * $1.1 }
                let n = Double(xs.count)
                let curve = (n * sxxy - sxx * sy) / (n * sx4 - sxx * sxx), slope = sxy / sxx
                guard curve < 0 else { return best.angle }
                return best.angle + max(-2 * step, min(2 * step, -slope / (2 * curve)))
            }
            let weights = columns.map { $0.reduce(0) { $0 + $1.w } }
            let total = weights.reduce(0, +)
            guard total > 0 else { return nil }
            return zip(columns, weights).reduce(0.0) { $0 + fineAngle($1.0) * $1.1 / total }
        }

        // Text first. A page with no clear lines of text (a plate with a caption
        // or two) is read from all its ink instead: the edges of its pictures,
        // rules and boxes, which are printed square to the page. A page with too
        // much ink for either (a full-page photograph) stays as it is.
        var found = inkCount > 50 ? estimate(dark) : nil
        if found == nil, Double(allInk) < 0.4 * Double(consideredCount) {
            var all: [Ink] = []
            for (i, isInk) in ink.enumerated() where isInk {
                let w = min(1, max(0, (paper - Double(g.pixels[i])) / (paper * 0.8)))
                all.append((Double(i % g.width) + Self.spot(i) - cx, Double(i / g.width) + Self.spot(i &* 7919 &+ 1) - cy, w))
            }
            found = estimate(all)
        }
        guard let angle = found else { return 0 }

        // GATE 4: implausibly large result ⇒ almost certainly spurious.
        if abs(angle) > maxDegrees - 0.5 { return 0 }

        // Snap near-zero noise to flat.
        return abs(angle) < 0.05 ? 0 : -angle
    }

    /// Split ink points into side-by-side columns: runs along the lines (at
    /// `deg`) with almost no ink, at least 1% of the width wide, between the
    /// first and last ink. One column when there is no such gap.
    private static func columns(of points: [Ink], at deg: Double,
                                width: Int) -> [[Ink]] {
        let rad = deg * .pi / 180
        let c = cos(rad), s = sin(rad)
        let half = Double(width) / 2
        let along = points.map { $0.x * c - $0.y * s + half }   // position along the line
        var hist = [Int](repeating: 0, count: width + 1)
        for x in along { hist[max(0, min(width, Int(x)))] += 1 }
        guard let first = hist.firstIndex(where: { $0 > 0 }), let last = hist.lastIndex(where: { $0 > 0 }),
              last > first else { return [points] }
        let typical = Double(points.count) / Double(last - first + 1)
        let quiet = max(1.0, typical * 0.02)
        let minGap = max(3, width / 100)
        var cuts: [Double] = []
        var runStart: Int?
        for x in first...last {
            if Double(hist[x]) <= quiet {
                if runStart == nil { runStart = x }
            } else if let start = runStart {
                if x - start >= minGap { cuts.append(Double(start + x) / 2) }
                runStart = nil
            }
        }
        guard !cuts.isEmpty else { return [points] }
        var groups = [[Ink]](repeating: [], count: cuts.count + 1)
        for (p, x) in zip(points, along) { groups[cuts.filter { $0 < x }.count].append(p) }
        // A sliver of ink (a page number, a mark) is not a column of text.
        let kept = groups.filter { Double($0.count) >= 0.02 * Double(points.count) }
        return kept.isEmpty ? [points] : kept
    }

    /// A fixed pseudo-random offset in [0, 1) for pixel `i`.
    private static func spot(_ i: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: i) &* 0x9E37_79B9_7F4A_7C15
        h ^= h >> 31; h = h &* 0xBF58_476D_1CE4_E5B9; h ^= h >> 29
        return Double(h >> 11) / Double(1 << 53)
    }

}
