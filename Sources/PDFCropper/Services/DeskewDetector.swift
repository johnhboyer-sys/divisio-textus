import Foundation
import CoreGraphics

/// Estimates page skew using the classic projection-profile method: at the
/// correct angle, text rows line up horizontally, so the horizontal darkness
/// profile has sharp peaks (lines) and deep valleys (gaps). We search angles
/// and pick the one that maximizes that contrast.
enum DeskewDetector {

    /// Returns the CORRECTION angle in degrees: straighten the page by rotating
    /// it `+result` via `ImageTransform.rotate(image, degrees: result)`.
    /// Range is limited to ±`maxDegrees` since scans are rarely worse.
    ///
    /// The method only works on text-like, line-structured content. When the
    /// page has no measurable line structure — a mostly-black/dense scan, a
    /// photo, a near-blank page — there is no reliable signal and forcing an
    /// angle badly skews the page, so we return 0 (leave it alone) in those cases.
    static func detect(_ cgImage: CGImage,
                       maxDegrees: Double = 6.0,
                       excludeCenterBand: Bool = true) -> Double {
        // Downsample hard — skew is a global property, fine detail isn't needed.
        guard let g = GrayBuffer(cgImage: cgImage, maxDim: 500) else { return 0 }

        // Collect dark (content) pixels once, centered on the image middle.
        var maxVal: UInt8 = 0
        for v in g.pixels { maxVal = max(maxVal, v) }
        let threshold = Double(maxVal) * 0.7

        let cx = Double(g.width) / 2, cy = Double(g.height) / 2
        // For a full spread, ignore a central vertical band: the binding shadow
        // is a strong dark stripe that biases the profile. For a single half the
        // spine is at an edge (already trimmed by the caller), so don't exclude.
        let gutterHalf = excludeCenterBand ? Double(g.width) * 0.08 : 0
        var consideredCount = 0
        var dark: [(x: Double, y: Double)] = []
        dark.reserveCapacity(g.width * g.height / 8)
        for y in 0..<g.height {
            for x in 0..<g.width {
                if gutterHalf > 0 && abs(Double(x) - cx) < gutterHalf { continue }
                consideredCount += 1
                if Double(g.value(x, y)) < threshold {
                    dark.append((Double(x) - cx, Double(y) - cy))
                }
            }
        }

        // GATE 1: too little ink (near-blank) — nothing to align.
        guard dark.count > 50, consideredCount > 0 else { return 0 }

        // GATE 2: too much ink. Text pages are mostly paper (typ. <20% dark);
        // a mostly-black page, photo, or dense plate has no text-row structure,
        // and the projection profile would lock onto a meaningless extreme angle.
        let darkFraction = Double(dark.count) / Double(consideredCount)
        guard darkFraction < 0.40 else { return 0 }

        let bins = g.height
        func score(_ deg: Double) -> Double {
            let rad = deg * .pi / 180
            let s = sin(rad), c = cos(rad)
            var profile = [Double](repeating: 0, count: bins)
            for p in dark {
                let ry = p.x * s + p.y * c + cy   // rotated y, shifted back into [0,height)
                let bin = Int(ry)
                if bin >= 0 && bin < bins { profile[bin] += 1 }
            }
            // Peakiness = sum of squared differences between adjacent bins.
            var acc = 0.0
            for i in 1..<bins {
                let d = profile[i] - profile[i - 1]
                acc += d * d
            }
            return acc
        }

        // Search, biasing toward smaller angles so a marginally-better extreme
        // angle never beats a near-flat one (regularization toward 0°).
        func bestAngle(in range: ClosedRange<Double>, step: Double) -> Double {
            var best = 0.0, bestSelScore = -1.0
            var a = range.lowerBound
            while a <= range.upperBound + 1e-9 {
                let sel = score(a) * (1 - 0.015 * abs(a))
                if sel > bestSelScore { bestSelScore = sel; best = a }
                a += step
            }
            return best
        }

        let coarse = bestAngle(in: -maxDegrees...maxDegrees, step: 0.5)
        let fine = bestAngle(in: (coarse - 0.5)...(coarse + 0.5), step: 0.1)

        // GATE 3: the chosen angle must be a clear peak — meaningfully sharper
        // than flat. If it isn't, the page lacks real line structure: stay flat.
        let flatScore = score(0)
        if flatScore <= 0 || score(fine) < flatScore * 1.08 { return 0 }

        // GATE 4: implausibly large result ⇒ almost certainly spurious.
        if abs(fine) > maxDegrees - 0.5 { return 0 }

        // Snap near-zero noise to flat.
        return abs(fine) < 0.1 ? 0 : fine
    }
}
