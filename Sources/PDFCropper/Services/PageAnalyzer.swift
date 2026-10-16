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
        /// No content was found on that side (a blank page).
        var leftBlank = false
        var rightBlank = false
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
                          leftCrop: left.crop,
                          rightCrop: right.crop,
                          leftBlank: left.blank,
                          rightBlank: right.blank)
        } else {
            let whole = contentBounds(gray, xRange: 0.0..<1.0)
            return Result(classification: .single,
                          splitX: 0.5,
                          leftCrop: whole.crop,
                          rightCrop: CropRect(x: 0.52, y: 0.02, width: 0.46, height: 0.96),
                          leftBlank: whole.blank)
        }
    }

    /// Find the gutter. Many scans have a binding shadow, a dark band down the
    /// middle: that is the gutter. Others show a clean white gap between the
    /// pages, often off center: then the gutter is the middle of the widest
    /// ink-free run of columns in the central 30–70% of the spread.
    static func detectGutter(_ g: GrayBuffer) -> Double {
        let lo = Int(Double(g.width) * 0.30)
        let hi = Int(Double(g.width) * 0.70)
        guard hi > lo else { return 0.5 }

        var paper: UInt8 = 0
        for v in g.pixels where v > paper { paper = v }

        // 1. A binding shadow: a central column far darker than the page.
        let shadowLo = Int(Double(g.width) * 0.40), shadowHi = Int(Double(g.width) * 0.60)
        var darkestX = g.width / 2, darkestMean = Double.greatestFiniteMagnitude
        for x in shadowLo..<shadowHi {
            let m = g.columnMean(x)
            if m < darkestMean { darkestMean = m; darkestX = x }
        }
        if darkestMean < Double(paper) * 0.55 { return Double(darkestX) / Double(g.width) }

        // 2. A white gap: columns with (almost) no ink, ignoring the top and
        //    bottom 5% where scan edges and running heads can stray across.
        let inkLevel = Double(paper) * 0.75
        let y0 = g.height / 20, y1 = g.height - g.height / 20
        let maxInk = max(1, (y1 - y0) / 200)          // up to 0.5% specks
        func isEmpty(_ x: Int) -> Bool {
            var ink = 0
            for y in y0..<y1 where Double(g.value(x, y)) < inkLevel {
                ink += 1
                if ink > maxInk { return false }
            }
            return true
        }
        let mid = Double(g.width) / 2
        var best: (start: Int, length: Int)?
        var runStart: Int?
        for x in lo...hi {
            if x < hi && isEmpty(x) {
                if runStart == nil { runStart = x }
            } else if let start = runStart {
                let length = x - start
                // Widest run wins; on a tie, the one nearer the middle.
                if let b = best {
                    let center = Double(start) + Double(length) / 2
                    let bestCenter = Double(b.start) + Double(b.length) / 2
                    if length > b.length || (length == b.length && abs(center - mid) < abs(bestCenter - mid)) {
                        best = (start, length)
                    }
                } else {
                    best = (start, length)
                }
                runStart = nil
            }
        }
        // A real gutter (two page margins) is wide; a narrow gap is more likely a
        // gap in a table or between columns of one page.
        if let best, best.length >= max(2, g.width * 3 / 100) {
            return (Double(best.start) + Double(best.length) / 2) / Double(g.width)
        }

        // 3. Neither: fall back to the darkest central column.
        return Double(darkestX) / Double(g.width)
    }

    /// Bounding box of "content" (dark pixels) within a horizontal sub-range of
    /// the page. Returns a normalized CropRect (full-page coordinates) padded
    /// slightly so we don't shave glyphs. Solid dark scan shadows along the edges
    /// (the binding/gutter band, black scan borders) are trimmed off first so they
    /// aren't mistaken for content.
    static func contentBounds(_ g: GrayBuffer, xRange: Range<Double>) -> (crop: CropRect, blank: Bool) {
        let x0 = max(0, Int(Double(g.width) * xRange.lowerBound))
        let x1 = min(g.width, Int(Double(g.width) * xRange.upperBound))
        guard x1 > x0 else {
            return (CropRect(x: xRange.lowerBound, y: 0.02,
                             width: max(0.02, xRange.upperBound - xRange.lowerBound),
                             height: 0.96), false)
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
        // Ignore stray specks: a line needs >1% of its span dark.
        let minRunFraction = 0.01

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

        // Walk inward from an edge and return where a dark band ends. The band may
        // sit behind a thin light strip (the edge of the scanner glass) and end in
        // ragged streaks where it meets the page block, so allow a short light run
        // before the first solid line and short gaps between solid lines.
        // A band that starts right at the edge only needs to be mostly dark; one
        // behind a light strip must run nearly the full length, as a scanner band
        // does, so a dark picture just inside the margin isn't mistaken for one.
        func bandEnd(from start: Int, toward end: Int, span: Int,
                     darkness: (Int) -> Double, isStreak: (Int) -> Bool) -> Int {
            let step = end >= start ? 1 : -1
            let leadIn = max(1, span * 3 / 100)       // light strip allowed before the band
            let maxGap = max(1, span * 15 / 1000)     // gap allowed between streaks
            var lastSolid: Int?
            var x = start
            while x != end {
                // Past the solid band, fainter lines (the page block's edge) still
                // belong to it; text is never that continuous down one line.
                let needed = (lastSolid == nil && x != start) ? 0.85 : bandFraction
                if darkness(x) > needed || (lastSolid != nil && isStreak(x)) {
                    lastSolid = x
                } else if let solid = lastSolid {
                    if abs(x - solid) > maxGap { break }
                } else if abs(x - start) > leadIn {
                    break
                }
                x += step
            }
            guard let solid = lastSolid else { return start }
            return solid + step
        }

        // Vertical bands first (full height), then horizontal bands within the
        // already-narrowed width so a leftover side band can't skew the row test.
        let spanW = x1 - x0
        func columnInk(_ x: Int) -> Double {
            var dark = 0
            for y in 0..<g.height where Double(g.value(x, y)) < threshold { dark += 1 }
            return Double(dark) / Double(g.height)
        }
        func rowInk(_ y: Int, _ xLo: Int, _ xHi: Int) -> Double {
            guard xHi > xLo else { return 0 }
            var dark = 0
            for x in xLo..<xHi where Double(g.value(x, y)) < threshold { dark += 1 }
            return Double(dark) / Double(xHi - xLo)
        }
        let streak = 0.35
        let bx0 = bandEnd(from: x0, toward: x1, span: spanW,
                          darkness: { columnDarkFraction($0, 0, g.height) },
                          isStreak: { columnInk($0) > streak })
        let bx1 = max(bx0, bandEnd(from: x1 - 1, toward: bx0 - 1, span: spanW,
                                   darkness: { columnDarkFraction($0, 0, g.height) },
                                   isStreak: { columnInk($0) > streak }) + 1)
        let by0 = bandEnd(from: 0, toward: g.height, span: g.height,
                          darkness: { rowDarkFraction($0, bx0, bx1) },
                          isStreak: { rowInk($0, bx0, bx1) > streak })
        let by1 = max(by0, bandEnd(from: g.height - 1, toward: by0 - 1, span: g.height,
                                   darkness: { rowDarkFraction($0, bx0, bx1) },
                                   isStreak: { rowInk($0, bx0, bx1) > streak }) + 1)

        func fullSubRange() -> CropRect {
            var r = CropRect(x: xRange.lowerBound, y: 0.02,
                             width: max(0.02, xRange.upperBound - xRange.lowerBound) - 0.02,
                             height: 0.96)
            r.normalize()
            return r
        }

        // If trimming consumed the whole region (e.g. a full-bleed dark photo),
        // keep the page rather than cropping it to nothing.
        guard bx1 > bx0, by1 > by0 else { return (fullSubRange(), false) }

        var top = by1, bottom = by0 - 1, left = bx1, right = bx0 - 1

        // Rows skip a thin strip along each side: a straightened page can leave a
        // few pixels of a scanner band there in every row.
        let sideStrip = max(1, (bx1 - bx0) * 15 / 1000)
        let rowX0 = min(bx1, bx0 + sideStrip), rowX1 = max(rowX0, bx1 - sideStrip)
        for y in by0..<by1 {
            var darkInRow = 0
            for x in rowX0..<rowX1 where Double(g.value(x, y)) < threshold {
                darkInRow += 1
            }
            if darkInRow > Int(Double(bx1 - bx0) * minRunFraction) {
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        // Columns are judged against the height of the content the rows found, not
        // the whole page: a page holding a single line (a chapter's last line, a
        // footnote) would otherwise have no column dark enough and read as blank.
        let contentHeight = bottom >= top ? bottom - top + 1 : by1 - by0
        for x in bx0..<bx1 {
            var darkInCol = 0
            for y in by0..<by1 where Double(g.value(x, y)) < threshold {
                darkInCol += 1
            }
            if darkInCol > Int(Double(contentHeight) * minRunFraction) {
                left = min(left, x); right = max(right, x)
            }
        }

        // Fallback to the full sub-range if we found nothing.
        // Nothing found (a blank page): the page area left once bands are trimmed.
        // A box under 3% of the page in both directions is a speck of dust, not
        // content (a one-line title is far wider): treat the page as blank.
        let speck = right >= left && bottom >= top
            && Double(right - left + 1) < 0.03 * Double(bx1 - bx0)
            && Double(bottom - top + 1) < 0.03 * Double(by1 - by0)
        if bottom < top || right < left || speck {
            var r = CropRect(x: Double(bx0) / Double(g.width), y: Double(by0) / Double(g.height),
                             width: Double(bx1 - bx0) / Double(g.width), height: Double(by1 - by0) / Double(g.height))
            r.normalize()
            return (r, true)
        }

        let pad = 0.012 // ~1.2% normalized padding around the detected content
        var rect = CropRect(
            x: Double(left) / Double(g.width) - pad,
            y: Double(top) / Double(g.height) - pad,
            width: Double(right - left) / Double(g.width) + 2 * pad,
            height: Double(bottom - top) / Double(g.height) + 2 * pad
        )
        rect.normalize()
        return (rect, false)
    }
}
