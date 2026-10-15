import Foundation
import CoreGraphics

/// Heuristics that seed each page's split line, classification, and crop boxes.
/// Everything here is best-effort — the user corrects results in the editor.
enum PageAnalyzer {

    struct Result {
        var classification: PageClassification
        var splitX: Double
        var leftCrop: CropRect
        var rightCrop: CropRect
    }

    /// Analyze one rendered page. `forced` (spread or single) overrides the
    /// automatic guess, e.g. when the user changes a page's type.
    static func analyze(cgImage: CGImage, as forced: PageClassification? = nil) -> Result {
        guard let gray = GrayBuffer(cgImage: cgImage) else {
            return Result(classification: .spread,
                          splitX: 0.5,
                          leftCrop: CropRect(x: 0.02, y: 0.02, width: 0.46, height: 0.96),
                          rightCrop: CropRect(x: 0.52, y: 0.02, width: 0.46, height: 0.96))
        }

        let aspect = Double(cgImage.width) / Double(cgImage.height)
        // Landscape-ish pages are almost certainly two-page spreads; tall pages
        // are likely a single page. This is just a starting guess.
        let isSpread = forced.map { $0 == .spread } ?? (aspect >= 1.15)

        let splitX = isSpread ? detectGutter(gray) : 0.5

        if isSpread {
            let left = contentBounds(gray, xRange: 0.0..<splitX)
            let right = contentBounds(gray, xRange: splitX..<1.0)
            return Result(classification: .spread,
                          splitX: splitX,
                          leftCrop: left,
                          rightCrop: right)
        } else {
            let whole = contentBounds(gray, xRange: 0.0..<1.0)
            return Result(classification: .single,
                          splitX: 0.5,
                          leftCrop: whole,
                          rightCrop: CropRect(x: 0.52, y: 0.02, width: 0.46, height: 0.96))
        }
    }

    /// Find the gutter as the darkest column band in the central region — for
    /// most book scans the binding casts a shadow there.
    static func detectGutter(_ g: GrayBuffer) -> Double {
        let lo = Int(Double(g.width) * 0.40)
        let hi = Int(Double(g.width) * 0.60)
        guard hi > lo else { return 0.5 }

        var bestX = g.width / 2
        var bestMean = Double.greatestFiniteMagnitude
        for x in lo..<hi {
            let m = g.columnMean(x)
            if m < bestMean {
                bestMean = m
                bestX = x
            }
        }
        return Double(bestX) / Double(g.width)
    }

    /// Bounding box of "content" (dark pixels) within a horizontal sub-range of
    /// the page. Returns a normalized CropRect (full-page coordinates) padded
    /// slightly so we don't shave glyphs. Solid dark scan shadows along the edges
    /// (the binding/gutter band, black scan borders) are trimmed off first so they
    /// aren't mistaken for content.
    static func contentBounds(_ g: GrayBuffer, xRange: Range<Double>) -> CropRect {
        let x0 = max(0, Int(Double(g.width) * xRange.lowerBound))
        let x1 = min(g.width, Int(Double(g.width) * xRange.upperBound))
        guard x1 > x0 else {
            return CropRect(x: xRange.lowerBound, y: 0.02,
                            width: max(0.02, xRange.upperBound - xRange.lowerBound),
                            height: 0.96)
        }

        // Threshold relative to the brightest area (paper). Pixels darker than
        // ~75% of paper brightness count as content.
        var maxVal: UInt8 = 0
        for y in 0..<g.height {
            for x in x0..<x1 {
                maxVal = max(maxVal, g.value(x, y))
            }
        }
        let threshold = Double(maxVal) * 0.75
        let minRunFraction = 0.01 // ignore stray specks: need >1% of the span dark

        // Trim solid dark shadow bands inward from each edge. A text line/column is
        // sparsely dark (<15% here); a scan-shadow stripe is near-solid (>50%), so
        // that gap cleanly separates them. Bands are trimmed before the content scan
        // so the binding shadow and black scan borders never anchor the crop.
        let bandThreshold = Double(maxVal) * 0.5
        let bandFraction = 0.5

        func columnDarkFraction(_ x: Int, _ yLo: Int, _ yHi: Int) -> Double {
            guard yHi > yLo else { return 0 }
            var dark = 0
            for y in yLo..<yHi where Double(g.value(x, y)) < bandThreshold { dark += 1 }
            return Double(dark) / Double(yHi - yLo)
        }
        func rowDarkFraction(_ y: Int, _ xLo: Int, _ xHi: Int) -> Double {
            guard xHi > xLo else { return 0 }
            var dark = 0
            for x in xLo..<xHi where Double(g.value(x, y)) < bandThreshold { dark += 1 }
            return Double(dark) / Double(xHi - xLo)
        }

        // Vertical bands first (full height), then horizontal bands within the
        // already-narrowed width so a leftover side band can't skew the row test.
        var bx0 = x0, bx1 = x1
        while bx0 < bx1 && columnDarkFraction(bx0, 0, g.height) > bandFraction { bx0 += 1 }
        while bx1 > bx0 && columnDarkFraction(bx1 - 1, 0, g.height) > bandFraction { bx1 -= 1 }
        var by0 = 0, by1 = g.height
        while by0 < by1 && rowDarkFraction(by0, bx0, bx1) > bandFraction { by0 += 1 }
        while by1 > by0 && rowDarkFraction(by1 - 1, bx0, bx1) > bandFraction { by1 -= 1 }

        func fullSubRange() -> CropRect {
            var r = CropRect(x: xRange.lowerBound, y: 0.02,
                             width: max(0.02, xRange.upperBound - xRange.lowerBound) - 0.02,
                             height: 0.96)
            r.normalize()
            return r
        }

        // If trimming consumed the whole region (e.g. a full-bleed dark photo),
        // keep the page rather than cropping it to nothing.
        guard bx1 > bx0, by1 > by0 else { return fullSubRange() }

        var top = by1, bottom = by0 - 1, left = bx1, right = bx0 - 1

        for y in by0..<by1 {
            var darkInRow = 0
            for x in bx0..<bx1 where Double(g.value(x, y)) < threshold {
                darkInRow += 1
            }
            if darkInRow > Int(Double(bx1 - bx0) * minRunFraction) {
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        for x in bx0..<bx1 {
            var darkInCol = 0
            for y in by0..<by1 where Double(g.value(x, y)) < threshold {
                darkInCol += 1
            }
            if darkInCol > Int(Double(by1 - by0) * minRunFraction) {
                left = min(left, x); right = max(right, x)
            }
        }

        // Fallback to the full sub-range if we found nothing.
        if bottom < top || right < left { return fullSubRange() }

        let pad = 0.012 // ~1.2% normalized padding around the detected content
        var rect = CropRect(
            x: Double(left) / Double(g.width) - pad,
            y: Double(top) / Double(g.height) - pad,
            width: Double(right - left) / Double(g.width) + 2 * pad,
            height: Double(bottom - top) / Double(g.height) + 2 * pad
        )
        rect.normalize()
        return rect
    }
}
