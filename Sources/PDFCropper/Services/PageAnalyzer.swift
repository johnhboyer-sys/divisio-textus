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
    /// automatic guess, e.g. when the user changes a page's type; `split` keeps a
    /// gutter already found instead of looking for it again. `target` says what
    /// the crops take in; for whole pages, `turns` are the angles each side of
    /// `cgImage` was straightened by, so the crops keep clear of the corners
    /// the turn left empty.
    static func analyze(cgImage: CGImage, as forced: PageClassification? = nil, split: Double? = nil,
                        target: CropTarget = .text, turns: (left: Double, right: Double) = (0, 0)) -> Result {
        var r = analyzeText(cgImage: cgImage, as: forced, split: split)
        guard target == .page, let g = GrayBuffer(cgImage: cgImage) else { return r }
        // Never less than the text block: on a tight scan turned a long way, the
        // corners left empty can reach into the printed text, and text beats a
        // clean corner.
        func page(_ side: Range<Double>, _ turned: Double, _ text: CropRect, _ blank: Bool) -> CropRect {
            let paper = paperBounds(g, xRange: side, turned: turned)
            return blank ? paper : paper.union(text)
        }
        if r.classification == .spread {
            r.leftCrop = page(0..<r.splitX, turns.left, r.leftCrop, r.leftBlank)
            r.rightCrop = page(r.splitX..<1, turns.right, r.rightCrop, r.rightBlank)
        } else {
            r.leftCrop = page(0..<1, turns.left, r.leftCrop, r.leftBlank)
        }
        return r
    }

    private static func analyzeText(cgImage: CGImage, as forced: PageClassification?, split: Double?) -> Result {
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

        let splitX = isSpread ? (split ?? detectGutter(gray)) : 0.5

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
    /// ink-free run of columns in the central 30–70% of the spread, even a narrow
    /// one when nothing wider is there.
    static func detectGutter(_ g: GrayBuffer) -> Double {
        let lo = Int(Double(g.width) * 0.30)
        let hi = Int(Double(g.width) * 0.70)
        guard hi > lo else { return 0.5 }

        let paper = g.paperLevel()

        // 1. A binding shadow, deep or soft grey, or just the fold's thin line:
        //    the darkest central column that is inked nearly top to bottom. A
        //    dark picture reaching the middle has paper above and below it, and
        //    text never fills a column more than about 40%.
        let shadowLo = Int(Double(g.width) * 0.40), shadowHi = Int(Double(g.width) * 0.60)
        let rows0 = g.height / 20, rows1 = g.height - g.height / 20
        var darkestX = g.width / 2, darkestMean = Double.greatestFiniteMagnitude
        var shadowX: Int?, shadowMean = Double.greatestFiniteMagnitude
        for x in shadowLo..<shadowHi {
            let m = g.columnMean(x)
            if m < darkestMean { darkestMean = m; darkestX = x }
            guard m < shadowMean else { continue }
            let inked = (rows0..<rows1).filter { Double(g.value(x, $0)) < paper * 0.75 }.count
            if Double(inked) >= 0.85 * Double(rows1 - rows0) { shadowMean = m; shadowX = x }
        }
        if let shadowX { return Double(shadowX) / Double(g.width) }

        // 2. A white gap: columns with (almost) no ink, ignoring the top and
        //    bottom 5% where scan edges and running heads can stray across.
        let inkLevel = paper * 0.75
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
        // A gap's middle can land on a running head or folio that the test above
        // ignored up in the top or bottom strip; within the gap, prefer the
        // widest part that is clear over the full height.
        func middle(of run: (start: Int, length: Int)) -> Double {
            func clear(_ x: Int) -> Bool {
                var ink = 0
                for y in 0..<g.height where Double(g.value(x, y)) < inkLevel {
                    ink += 1
                    if ink > maxInk { return false }
                }
                return true
            }
            var bestClear: (start: Int, length: Int)?, start: Int?
            for x in run.start...(run.start + run.length) {
                if x < run.start + run.length && clear(x) {
                    if start == nil { start = x }
                } else if let s = start {
                    if x - s > (bestClear?.length ?? 1) { bestClear = (s, x - s) }
                    start = nil
                }
            }
            let chosen = bestClear ?? run
            return (Double(chosen.start) + Double(chosen.length) / 2) / Double(g.width)
        }
        if let best, best.length >= max(2, g.width * 3 / 100) { return middle(of: best) }

        // 3. Pages trimmed close at the binding leave only a narrow gap; it still
        //    beats any column of text.
        if let best, best.length >= 2 { return middle(of: best) }

        // 4. Nothing clear: the darkest central column.
        return Double(darkestX) / Double(g.width)
    }

    /// Bounding box of "content" (dark pixels) within a horizontal sub-range of
    /// the page. Returns a normalized CropRect (full-page coordinates) padded
    /// slightly so we don't shave glyphs. Solid dark scan shadows along the edges
    /// (the binding/gutter band, black scan borders) are trimmed off first so they
    /// aren't mistaken for content.
    static func contentBounds(_ g: GrayBuffer, xRange: Range<Double>) -> (crop: CropRect, blank: Bool) {
        // Every result stays inside its region, to the last fraction of a pixel
        // (some paths work in whole pixels and round).
        var found = findContent(g, xRange: xRange)
        let x0 = max(found.crop.x, xRange.lowerBound)
        found.crop.width = max(0, min(found.crop.maxX, xRange.upperBound) - x0)
        found.crop.x = x0
        return found
    }

    /// The sheet of paper within a horizontal sub-range of the page, margins
    /// included: everything but the scanner background around it (a black band,
    /// a dark lid, the book block's streaks beside it) and a black fold at the
    /// gutter. A scan cut at the paper's edge is all page. `turned` is the angle
    /// the region was straightened by, about its own center; the crop keeps clear
    /// of the corners that turn left empty.
    static func paperBounds(_ g: GrayBuffer, xRange: Range<Double>, turned degrees: Double = 0) -> CropRect {
        let x0 = max(0, Int(Double(g.width) * xRange.lowerBound))
        let x1 = min(g.width, Int(Double(g.width) * xRange.upperBound))
        guard x1 > x0, g.height > 0 else {
            return CropRect(x: xRange.lowerBound, y: 0, width: max(0, xRange.upperBound - xRange.lowerBound), height: 1)
        }

        // Which pixels the turn filled in: those outside the turned rectangle.
        let cx = Double(x0 + x1) / 2, cy = Double(g.height) / 2
        let hw = Double(x1 - x0) / 2, hh = Double(g.height) / 2
        let turned = abs(degrees) > 0.01
        let rad = degrees * .pi / 180, cosT = cos(rad), sinT = sin(rad)
        func scanned(_ x: Int, _ y: Int) -> Bool {
            guard turned else { return true }
            let dx = Double(x) + 0.5 - cx, dy = cy - (Double(y) + 0.5)      // y up, as the turn was made
            return abs(dx * cosT + dy * sinT) <= hw - 1.5 && abs(-dx * sinT + dy * cosT) <= hh - 1.5
        }

        // Background is far darker than the paper; ink is too, but no line of
        // print is dark nearly end to end.
        let dark = g.paperLevel(columns: x0..<x1) * 0.5
        func share(_ pixels: [(Int, Int)]) -> Double? {
            var n = 0, d = 0
            for (x, y) in pixels where scanned(x, y) { n += 1; if Double(g.value(x, y)) < dark { d += 1 } }
            return n * 2 >= pixels.count ? Double(d) / Double(n) : nil      // nil: mostly filled in
        }
        // Walk in from an edge past background lines, allowing short gaps between
        // them (the book block's streaks) and a light strip before the first (the
        // scanner glass's border). Returns the first line of paper.
        func paperStart(from start: Int, toward end: Int, line: (Int) -> Double?) -> Int {
            let step = end >= start ? 1 : -1, span = abs(end - start)
            let leadIn = max(1, span * 3 / 100), maxGap = max(1, span * 15 / 1000)
            var last: Int?, i = start
            while i != end {
                if let s = line(i) {
                    if s >= 0.9 { last = i }
                    else if let l = last { if abs(i - l) > maxGap { break } }
                    else if abs(i - start) > leadIn { break }
                }
                i += step
            }
            return last.map { $0 + step } ?? start
        }

        // Columns, then rows within them, twice over: a sheet short of the scan's
        // height leaves background above and below every column at first.
        var left = x0, right = x1, top = 0, bottom = g.height
        for _ in 0..<2 {
            let ys = top..<bottom
            left = paperStart(from: x0, toward: x1) { x in share(ys.map { (x, $0) }) }
            right = max(left, paperStart(from: x1 - 1, toward: left - 1) { x in share(ys.map { (x, $0) }) } + 1)
            let xs = left..<right
            top = paperStart(from: 0, toward: g.height) { y in share(xs.map { ($0, y) }) }
            bottom = max(top, paperStart(from: g.height - 1, toward: top - 1) { y in share(xs.map { ($0, y) }) } + 1)
        }

        // Keep inside the largest upright box the turned scan still covers: half
        // sizes (a, b) with both of its corners' constraints just met,
        // a·cos + b·sin = w/2 and a·sin + b·cos = h/2 (less a pixel and a half).
        // Straightening turns a few degrees; past 45° no upright box is meant.
        if turned {
            let c = abs(cosT), s = abs(sinT), W = hw - 1.5, H = hh - 1.5
            let a = c > s ? (W * c - H * s) / (c * c - s * s) : 0, b = c > s ? (H * c - W * s) / (c * c - s * s) : 0
            left = max(left, Int((cx - a).rounded(.up))); right = min(right, Int((cx + a).rounded(.down)))
            top = max(top, Int((cy - b).rounded(.up))); bottom = min(bottom, Int((cy + b).rounded(.down)))
        }
        guard right > left, bottom > top else {
            return CropRect(x: xRange.lowerBound, y: 0, width: max(0, xRange.upperBound - xRange.lowerBound), height: 1)
        }
        // An edge that stayed at the region's own edge is exactly that edge.
        let minX = left == x0 ? xRange.lowerBound : Double(left) / Double(g.width)
        let maxX = right == x1 ? xRange.upperBound : Double(right) / Double(g.width)
        let minY = top == 0 ? 0 : Double(top) / Double(g.height)
        let maxY = bottom == g.height ? 1 : Double(bottom) / Double(g.height)
        return CropRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func findContent(_ g: GrayBuffer, xRange: Range<Double>) -> (crop: CropRect, blank: Bool) {
        let x0 = max(0, Int(Double(g.width) * xRange.lowerBound))
        let x1 = min(g.width, Int(Double(g.width) * xRange.upperBound))
        guard x1 > x0 else {
            return (CropRect(x: xRange.lowerBound, y: 0.02,
                             width: max(0.02, xRange.upperBound - xRange.lowerBound),
                             height: 0.96), false)
        }

        // Threshold relative to the paper's brightness. Pixels darker than ~75% of
        // it count as content.
        let paper = g.paperLevel(columns: x0..<x1)
        let threshold = paper * 0.75
        // Ignore stray specks: a line needs >1% of its span dark.
        let minRunFraction = 0.01

        // Trim solid dark shadow bands inward from each edge. A text line/column is
        // sparsely dark (<15% here); a scan-shadow stripe is near-solid (>50%), so
        // that gap cleanly separates them. Bands are trimmed before the content scan
        // so the binding shadow and black scan borders never anchor the crop.
        let bandThreshold = paper * 0.5
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
        // A column inked over most of its height is a shadow, not text, even when
        // it is only grey: a soft binding shadow (tilted, once its half has been
        // straightened), the darkening where the page curls. Text never fills a
        // column more than about 40%. A row is held to "nearly end to end": a
        // line of bold type can ink half a row.
        var bx0 = bandEnd(from: x0, toward: x1, span: spanW,
                          darkness: { max(columnDarkFraction($0, 0, g.height), columnInk($0)) },
                          isStreak: { columnInk($0) > streak })
        var bx1 = max(bx0, bandEnd(from: x1 - 1, toward: bx0 - 1, span: spanW,
                                   darkness: { max(columnDarkFraction($0, 0, g.height), columnInk($0)) },
                                   isStreak: { columnInk($0) > streak }) + 1)
        // Past a band, its edge can break up into specks that thin out toward the
        // paper (a mottled binding shadow): columns whose ink falls, give or take
        // a little, to clean paper within a few pixels. They are the band's too.
        // Text beside a band doesn't thin out into a clean column that soon.
        // The band ends at the last clean column before the next ink.
        // Its ink hangs from the band: in each row, dark all the way back to it.
        // (A brace or a letter beside the band has paper between.)
        func fadeEnd(from start: Int, step: Int) -> Int {
            var x = start, low = 1.0, clean: Int?
            var reach = [Bool](repeating: true, count: g.height)          // row still dark back to the band
            while abs(x - start) <= max(1, spanW * 3 / 100) && x >= x0 && x < x1 {
                var dark = 0, hanging = 0
                for y in 0..<g.height {
                    let d = Double(g.value(x, y)) < threshold
                    if d { dark += 1; if reach[y] { hanging += 1 } }
                    reach[y] = reach[y] && d
                }
                let ink = Double(dark) / Double(g.height)
                if ink <= minRunFraction { clean = x }                  // paper, a speck or two at most
                else if clean != nil || ink > low + 0.03 || hanging * 10 < dark * 9 { break }   // print, or no fade
                low = min(low, ink); x += step
            }
            return clean ?? start
        }
        // (Where the solid band ends is kept: the side strips and the scan's own
        // border below are measured from there.)
        let solid = (lo: bx0, hi: bx1)
        if bx0 > x0 && bx0 < x1 { bx0 = fadeEnd(from: bx0, step: 1) }
        if bx1 < x1 && bx1 > x0 { bx1 = max(bx0, fadeEnd(from: bx1 - 1, step: -1) + 1) }
        // A shadow that runs at a slant (the binding shadow, once its half has
        // been straightened) fills no single column. Row by row, though, it is
        // ink starting at the region's edge in nearly every row, where text near
        // an edge leaves the gaps between its lines empty. Trim to where that edge
        // ink ends in nearly every row, if it is shadow-narrow (a full-height
        // plate at the gutter is far wider, and stays). A wider band whose edge
        // slants is the scan's, turned with the page (print stands upright once
        // the page is straight): up to a fifth of the width.
        func slantedShadowEnd(from start: Int, step: Int) -> Int? {
            let depth = max(4, spanW * 8 / 100), far = max(depth, spanW * 20 / 100), wedge = depth / 2
            func inside(_ x: Int) -> Bool { x >= x0 && x < x1 }
            var ends: [(y: Double, end: Double)] = [], sampled = 0, deepest = 0, first = g.height, last = -1
            for y in stride(from: 0, to: g.height, by: 2) {
                sampled += 1
                var x = start, k = 0
                while k < wedge && inside(x) && Double(g.value(x, y)) >= threshold { x += step; k += 1 }
                guard k < wedge && inside(x) else { continue }
                var gap = 0
                while k < far && gap <= 1 && inside(x) {
                    if Double(g.value(x, y)) < threshold { gap = 0 } else { gap += 1 }
                    x += step; k += 1
                }
                guard k < far && inside(x) else { return nil }       // ink running deep: not a shadow
                deepest = max(deepest, k); first = min(first, y); last = max(last, y)
                ends.append((Double(y), Double(abs(x - start))))
            }
            guard !ends.isEmpty, ends.count * 10 >= sampled * 8 else { return nil }   // 80% of rows; text reaches about half
            // The shadow's inner edge is a straight line, slanted or not; rows where
            // letters touch the shadow run deeper. Fit the line without them and
            // cut just past its deepest point, so those letters stay.
            var kept = ends, fit = (a: 0.0, b: 0.0)
            for _ in 0..<3 {
                let n = Double(kept.count), sy = kept.reduce(0) { $0 + $1.y }, se = kept.reduce(0) { $0 + $1.end }
                let syy = kept.reduce(0) { $0 + $1.y * $1.y }, sye = kept.reduce(0) { $0 + $1.y * $1.end }
                let b = n * syy - sy * sy > 0 ? (n * sye - sy * se) / (n * syy - sy * sy) : 0
                fit = ((se - b * sy) / n, b)
                let next = kept.filter { $0.end <= fit.a + fit.b * $0.y + 2 }
                guard next.count >= ends.count / 2, next.count < kept.count else { break }
                kept = next
            }
            // A band wider than a shadow must be the bed: slanted, and running off
            // the scan at its top or bottom (the turn's empty corner can hide the
            // other end). A picture, even one at a slant, has paper above and
            // below it.
            let slanted = abs(fit.b) * Double(g.height - 1) >= Double(max(3, spanW * 2 / 100))
            let tall = first * 20 <= g.height || (g.height - 1 - last) * 20 <= g.height
            guard (slanted && tall) || deepest < depth else { return nil }
            let inner = max(fit.a, fit.a + fit.b * Double(g.height - 1)) + 2
            return start + step * Int(min(Double(slanted ? far : depth), inner).rounded(.up))
        }
        if bx1 - bx0 > spanW / 2 {
            // From the region's own edge: the column test may have taken part of it.
            if let e = slantedShadowEnd(from: x0, step: 1) { bx0 = max(bx0, e) }
            if let e = slantedShadowEnd(from: x1 - 1, step: -1) { bx1 = min(bx1, e + 1) }
        }
        // A spiral or comb binding: loops down the gutter, one below the next from
        // the top of the page to the bottom. Row by row each loop is a solid run
        // of ink in from the region's edge, all about as deep, and the rows
        // between them are short or empty, at a steady pitch. Each loop is solid
        // and at least 2% of the page tall: taller than a line of print or a
        // mark in the margin (line numbers are strokes with gaps, besides). The
        // loops count for nothing below, nor does the shading on them, which
        // looks like marks printed over a shadow. Returns how deep they reach.
        func bindingDepth(from start: Int, step: Int) -> Int? {
            let lead = max(1, spanW * 3 / 100), cap = max(4, spanW * 15 / 100)
            func inside(_ x: Int) -> Bool { x >= x0 && x < x1 }
            var runs = [Int](repeating: 0, count: g.height), solid = [Bool](repeating: false, count: g.height)
            var deep = 0
            for y in 0..<g.height {
                var x = start, k = 0
                while k < lead && inside(x) && Double(g.value(x, y)) >= threshold { x += step; k += 1 }
                guard inside(x), Double(g.value(x, y)) < threshold else { continue }
                let first = k
                var last = k, gap = 0, inked = 0
                while inside(x) && gap <= 2 && k <= cap {
                    if Double(g.value(x, y)) < threshold { last = k; gap = 0; inked += 1 } else { gap += 1 }
                    x += step; k += 1
                }
                if k > cap { deep += 1; continue }                     // ink running deep: text or a picture
                runs[y] = last + 1
                solid[y] = inked * 10 >= (last - first + 1) * 9
            }
            guard deep * 20 <= g.height else { return nil }
            let depth = runs.sorted()[g.height * 9 / 10]
            guard depth >= max(4, spanW * 3 / 100) else { return nil }
            // The loops: stretches of rows reaching past half that depth.
            var loops: [(start: Int, end: Int)] = []
            var y = 0
            while y < g.height {
                guard runs[y] * 2 > depth else { y += 1; continue }
                var end = y
                while end + 1 < g.height && runs[end + 1] * 2 > depth { end += 1 }
                loops.append((y, end)); y = end + 1
            }
            guard loops.count >= 6, let top = loops.first, let bottom = loops.last,
                  (bottom.end - top.start) * 10 >= g.height * 6 else { return nil }
            let heights = loops.map { $0.end - $0.start + 1 }, pitches = zip(loops, loops.dropFirst()).map { $1.start - $0.start }
            let height = heights.sorted()[heights.count / 2], pitch = pitches.sorted()[pitches.count / 2]
            // Each loop as deep as the next (lines of print start with words of
            // any length).
            let depths = loops.map { l in (l.start...l.end).map { runs[$0] }.sorted()[(l.end - l.start + 1) / 2] }
            let reach = depths.sorted()[depths.count / 2]
            let steady = heights.filter { $0 * 2 >= height && $0 <= height * 2 }.count * 10 >= heights.count * 8
                && pitches.filter { abs($0 - pitch) * 4 <= pitch }.count * 10 >= pitches.count * 8
                && depths.filter { abs($0 - reach) <= max(2, reach / 6) }.count * 10 >= depths.count * 8
            let rows = loops.flatMap { $0.start...$0.end }
            // The loops run through the gutter: just across the split, on the
            // facing page, there is more ink in the loops' rows than between them
            // (a fold, a printed rule or the facing text is the same in both).
            let facing = (1...16).map { start - step * $0 }.filter { $0 >= 0 && $0 < g.width }
            guard facing.count == 16 else { return nil }
            func across(_ y: Int) -> Double { Double(facing.filter { Double(g.value($0, y)) < threshold }.count) }
            let between0 = (0..<g.height).filter { y in !loops.contains { y >= $0.start - 3 && y <= $0.end + 3 } }
            guard !between0.isEmpty else { return nil }
            let inLoops = rows.map(across).reduce(0, +) / Double(rows.count)
            let outside = between0.map(across).reduce(0, +) / Double(between0.count)
            guard inLoops >= outside + 4 else { return nil }
            guard steady, height * 100 <= g.height * 6, height * 50 >= g.height, pitch >= height + 2,
                  rows.filter({ solid[$0] }).count * 10 >= rows.count * 9 else { return nil }
            // Between the loops (away from their curling ends) nothing printed
            // reaches across the zone's inner edge (the wire through the holes, or
            // the fold, stays inside it), so trimming it cuts no text.
            let zone = depth + 2
            var nearLoop = [Bool](repeating: false, count: g.height)
            for l in loops { for y in max(0, l.start - 3)...min(g.height - 1, l.end + 3) { nearLoop[y] = true } }
            var stray = 0, room = 0
            for y in 0..<g.height where !nearLoop[y] {
                for k in max(0, zone - 3)..<(zone + 3) {
                    let x = start + step * k
                    guard inside(x) else { break }
                    room += 1
                    if Double(g.value(x, y)) < threshold { stray += 1 }
                }
            }
            guard room > 0, stray * 50 <= room else { return nil }
            // And something holds the loops together: the fold, or the wire through
            // the holes, shows between them in the zone (or just across the split:
            // the loops straddle it), 3 px wide or more. Marks printed down a
            // margin have bare paper between them, or at most a printed rule a
            // pixel or two wide.
            let between = (0..<g.height).filter { !nearLoop[$0] }
            let widths = between.map { y -> Int in
                var widest = 0, run = 0
                for k in -8..<zone {
                    let x = start + step * k
                    if x >= 0 && x < g.width && Double(g.value(x, y)) < threshold { run += 1; widest = max(widest, run) } else { run = 0 }
                }
                return widest
            }
            guard widths.filter({ $0 >= 3 }).count * 10 >= between.count else { return nil }
            return zone
        }
        // Only at the gutter: a region's side that is the scan's own edge is
        // the outer margin (where numbers in the margin are set at a steady pitch).
        var markX0 = x0, markX1 = x1
        if xRange.lowerBound > 0, let d = bindingDepth(from: x0, step: 1) { markX0 = min(x1, x0 + d); bx0 = max(bx0, markX0) }
        if xRange.upperBound < 1, let d = bindingDepth(from: x1 - 1, step: -1) { markX1 = max(x0, x1 - d); bx1 = min(bx1, markX1) }
        let by0 = bandEnd(from: 0, toward: g.height, span: g.height,
                          darkness: { max(rowDarkFraction($0, bx0, bx1), rowInk($0, bx0, bx1) > 0.85 ? 1 : 0) },
                          isStreak: { rowInk($0, bx0, bx1) > streak })
        let by1 = max(by0, bandEnd(from: g.height - 1, toward: by0 - 1, span: g.height,
                                   darkness: { max(rowDarkFraction($0, bx0, bx1), rowInk($0, bx0, bx1) > 0.85 ? 1 : 0) },
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

        // A wedge of scanner bed beside a page that lay turned on the glass (or
        // one that straightening it left) narrows down the page, so no column is
        // dark enough to trim. Row by row it is ink running in from the region's
        // edge, in nearly every row of a long stretch, its end moving smoothly;
        // text near an edge leaves the gaps between its lines empty, and its
        // words end anywhere. Those runs, and the grey fringe along them, count
        // for nothing below. A run reaching far past the trimmed band is a
        // picture, and stays. So is a block with paper above and below it: a
        // wedge of bed runs on from the scan's top or bottom, or narrows away
        // to nothing at the region's edge.
        let leadIn = max(1, spanW * 3 / 100), reach = max(4, spanW * 8 / 100)
        func edgeRun(_ y: Int, from start: Int, step: Int, limit: Int) -> Int {
            func inside(_ x: Int) -> Bool { x >= x0 && x < x1 }
            var x = start, k = 0
            while k < leadIn && inside(x) && Double(g.value(x, y)) >= threshold { x += step; k += 1 }
            guard inside(x), Double(g.value(x, y)) < threshold else { return 0 }
            var last = k, gap = 0
            while inside(x) && gap <= 2 && k <= limit {
                if Double(g.value(x, y)) < threshold { last = k; gap = 0 } else { gap += 1 }
                x += step; k += 1
            }
            return k > limit ? 0 : last + 3        // the run, and 2 px of fringe past it
        }
        var lo = [Int](repeating: x0, count: g.height), hi = [Int](repeating: x1, count: g.height)
        func wedge(from start: Int, step: Int, limit: Int, apply: (Int, Int) -> Void) {
            var runs = [Int](repeating: 0, count: g.height)
            for y in by0..<by1 { runs[y] = edgeRun(y, from: start, step: step, limit: limit) }
            // The wedge's edge is where most rows nearby end: a mark printed
            // over it lengthens only its own few rows.
            let half = max(2, (by1 - by0) / 40)
            let edge = (0..<g.height).map { y -> Int in
                guard y >= by0 && y < by1 else { return 0 }
                let near = runs[max(by0, y - half)..<min(by1, y + half + 1)].sorted()
                return near[near.count / 2]
            }
            let corner = max(2, (by1 - by0) / 50)
            var y = by0
            while y < by1 {
                guard runs[y] > 0 else { y += 1; continue }
                var end = y, gap = 0, k = y + 1
                while k < by1 && gap <= 2 { if runs[k] > 0 { end = k; gap = 0 } else { gap += 1 }; k += 1 }
                let rows = (y...end).filter { runs[$0] > 0 }
                let steps = zip(rows, rows.dropFirst()).map { abs(runs[$1] - runs[$0]) }.sorted()
                if end - y + 1 >= (by1 - by0) / 10, rows.count * 10 >= (end - y + 1) * 9,
                   steps.isEmpty || steps[steps.count / 2] <= 2,
                   y - by0 <= corner || by1 - 1 - end <= corner || runs[y] <= 5 || runs[end] <= 5 {
                    for r in rows { apply(r, edge[r]) }
                }
                y = end + 1
            }
        }
        wedge(from: x0, step: 1, limit: bx0 - x0 + reach) { y, run in lo[y] = max(lo[y], x0 + run) }
        wedge(from: x1 - 1, step: -1, limit: x1 - bx1 + reach) { y, run in hi[y] = min(hi[y], x1 - run) }
        /// Ink, outside any wedge of scanner bed. (Past a trimmed band, ink is told
        /// from shadow another way, below.)
        func ink(_ x: Int, _ y: Int) -> Bool { x >= lo[y] && x < hi[y] && Double(g.value(x, y)) < threshold }

        var top = by1, bottom = by0 - 1, left = bx1, right = bx0 - 1

        // Rows skip a thin strip along each side: a straightened page can leave a
        // few pixels of a scanner band there in every row.
        let sideStrip = max(1, (bx1 - bx0) * 15 / 1000)
        func scanRows(_ xs: Range<Int>) {
            top = by1; bottom = by0 - 1
            for y in by0..<by1 {
                var darkInRow = 0
                for x in xs where ink(x, y) {
                    darkInRow += 1
                }
                if darkInRow > Int(Double(bx1 - bx0) * minRunFraction) {
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        let rowX0 = min(bx1, max(bx0, solid.lo + sideStrip)), rowX1 = max(rowX0, min(bx1, solid.hi - sideStrip))
        scanRows(rowX0..<rowX1)
        // Columns are judged against the height of the content the rows found, not
        // the whole page: a page holding a single line (a chapter's last line, a
        // footnote) would otherwise have no column dark enough and read as blank.
        let contentHeight = bottom >= top ? bottom - top + 1 : by1 - by0
        // Columns are judged away from the scan's top and bottom 4%, where the
        // scanner bed's corners and the fold's head and tail spread a smudge
        // (unless all there is lies there: a page's last line, low down).
        let edgeRows = (by1 - by0) / 25
        func midRow(_ y: Int) -> Bool { y >= by0 + edgeRows && y < by1 - edgeRows }
        var columnDark = [Int](repeating: 0, count: max(0, bx1 - bx0)), columnMid = columnDark
        for x in bx0..<bx1 {
            var darkInCol = 0, mid = 0
            for y in by0..<by1 where ink(x, y) {
                darkInCol += 1
                if midRow(y) { mid += 1 }
            }
            columnDark[x - bx0] = darkInCol; columnMid[x - bx0] = mid
            if mid > Int(Double(contentHeight) * minRunFraction) {
                left = min(left, x); right = max(right, x)
            }
        }
        if right < left {
            columnMid = columnDark
            for x in bx0..<bx1 where columnDark[x - bx0] > Int(Double(contentHeight) * minRunFraction) {
                left = min(left, x); right = max(right, x)
            }
        }

        // The book block's edge (the other pages' edges, seen as thin streaks
        // beside a scanner band or at the fold) is a narrow cluster of tall ink
        // at the very edge of what was found, then a clear gap before the text.
        // A folio is short and a column of line numbers is wide; they stay.
        var leftLimit = markX0, rightLimit = markX1 - 1
        var countedRows: Range<Int>?        // the columns rows were last counted in, if only those
        var streakEnd = (lo: x0 - 1, hi: x1)  // the inner side of a streak cut off at either edge
        if right > left {
            let isContent = { (x: Int) in columnMid[x - bx0] > Int(Double(contentHeight) * minRunFraction) }
            let narrow = max(2, (bx1 - bx0) / 50), clear = max(3, (bx1 - bx0) / 50)
            // The longest unbroken run of ink down column x: a streak runs on, a
            // column of line numbers breaks at every number.
            func longestRunDown(_ x: Int) -> Int {
                var best = 0, run = 0
                for y in by0..<by1 { if Double(g.value(x, y)) < threshold { run += 1; best = max(best, run) } else { run = 0 } }
                return best
            }
            func strip(from start: Int, step: Int) -> Int? {
                var x = start, last = start, tallest = 0, longest = 0
                var rowsInked = Set<Int>()
                while (x - start) * step <= narrow + 2 && x >= left && x <= right {
                    if isContent(x) {
                        last = x; tallest = max(tallest, columnDark[x - bx0]); longest = max(longest, longestRunDown(x))
                        for y in by0..<by1 where Double(g.value(x, y)) < threshold { rowsInked.insert(y) }
                    }
                    x += step
                }
                // Or a dashed streak: ink in at least half the rows over a long span
                // (line numbers fill a few percent of theirs).
                let span = (rowsInked.max() ?? 0) - (rowsInked.min() ?? 0) + 1
                let dashed = Double(span) >= 0.3 * Double(by1 - by0) && rowsInked.count * 2 >= span
                // Tall, or right at the scan's own border (nothing printed sits
                // there with a clear gap inside it), however short; but narrow over
                // its full height too (a letter cut by the scan's top or bottom 4%
                // isn't, there).
                let border = max(2, (bx1 - bx0) * 15 / 1000)
                var lastFull = start, xf = start
                while (xf - start) * step <= narrow + 2 && xf >= left && xf <= right {
                    if columnDark[xf - bx0] > Int(Double(contentHeight) * minRunFraction) { lastFull = xf }
                    xf += step
                }
                let atBorder = step > 0 ? lastFull - min(bx0, solid.lo) <= border : max(bx1, solid.hi) - 1 - lastFull <= border
                let streak = Double(tallest) >= 0.12 * Double(by1 - by0) && (Double(longest) >= 0.04 * Double(by1 - by0) || dashed)
                guard (last - start) * step <= narrow, streak || atBorder else { return nil }
                var next = last + step
                while next >= left && next <= right && !isContent(next) { next += step }
                guard next >= left && next <= right, (next - last) * step >= clear else { return nil }
                if step > 0 { streakEnd.lo = last } else { streakEnd.hi = last }
                return next
            }
            let before = (left, right)
            if let n = strip(from: left, step: 1) { leftLimit = max(bx0, n - clear + 1); left = n }
            if let n = strip(from: right, step: -1) { rightLimit = min(bx1 - 1, n + clear - 1); right = n }
            // Print in the scan's top and bottom 4%, outside the text's columns (a
            // running head, a folio set off to the side), still widens them, even
            // touching the scan's edge. Only junk shaped like it is left out: ink
            // joined to bed or a band already left out, a line or streak running
            // on far into the page (the fold's line below its head), a thin line
            // much wider than any word, or anything past a streak or binding cut
            // off.
            var pieceKept = (lo: false, hi: false)
            if edgeRows > 0 && rowX1 > rowX0 {
                let reachIn = max(2, (by1 - by0) * 6 / 100)
                for (band, beyond) in [(by0..<(by0 + edgeRows), (by0 + edgeRows)..<(by0 + edgeRows + reachIn)),
                                       ((by1 - edgeRows)..<by1, (by1 - edgeRows - reachIn)..<(by1 - edgeRows))] {
                    let p0 = max(x0, min(bx0, solid.lo)), p1 = min(x1, max(bx1, solid.hi))
                    let inked = (p0..<p1).map { x in band.contains { y in Double(g.value(x, y)) < threshold && x >= lo[y] && x < hi[y] } }
                    var i = 0
                    while i < inked.count {
                        guard inked[i] else { i += 1; continue }
                        var j = i, gap = 0
                        while j + 1 + gap < inked.count && gap <= 2 { if inked[j + 1 + gap] { j += 1 + gap; gap = 0 } else { gap += 1 } }
                        let pieceLo = p0 + i, pieceHi = p0 + j
                        // (Judged on the piece's columns outside the text's, and a few
                        // pixels round them, but never on the text's own.)
                        let near = (max(p0, pieceLo - 4)...min(p1 - 1, pieceHi + 4)).filter { $0 < left || $0 > right }
                        let runsOn = beyond.filter { y in near.contains { ink($0, y) } }.count * 10 >= beyond.count * 9
                        // Joined, in some row, by unbroken dark to a band left out (or, with
                        // none, to the scan's edge): print beside the bed has paper
                        // between, however little.
                        func dark(_ x: Int, _ y: Int) -> Bool { Double(g.value(x, y)) < threshold }
                        let attached = band.contains { y in
                            (pieceLo > x0 && (max(x0, min(pieceLo, solid.lo) - 1)..<pieceLo).allSatisfy { dark($0, y) }
                                && (solid.lo > x0 || (x0..<pieceLo).allSatisfy { dark($0, y) }))
                            || (pieceHi + 1 < x1 && ((pieceHi + 1)...min(x1 - 1, max(pieceHi + 1, solid.hi))).allSatisfy { dark($0, y) }
                                && (solid.hi < x1 || ((pieceHi + 1)..<x1).allSatisfy { dark($0, y) })) }
                        // A line: one unbroken run a fifth of the width, under 3 rows thick
                        // (a dotted rule is dashes).
                        let rows = band.filter { y in (pieceLo...pieceHi).contains { dark($0, y) } }
                        let longest = band.map { y -> Int in
                            var best = 0, run = 0
                            for x in pieceLo...pieceHi { if dark(x, y) { run += 1; best = max(best, run) } else { run = 0 } }
                            return best }.max() ?? 0
                        let line = (rows.max() ?? 0) - (rows.min() ?? 0) < 3 && longest * 5 >= bx1 - bx0
                        // Out past a streak or binding cut off (between it and the edge).
                        let beyondCut = pieceHi <= streakEnd.lo || pieceLo >= streakEnd.hi || pieceHi < markX0 || pieceLo >= markX1
                        let junk = beyondCut || runsOn || attached || line
                        if !junk {
                            if pieceLo < left { left = pieceLo; pieceKept.lo = true }
                            if pieceHi > right { right = pieceHi; pieceKept.hi = true }
                        }
                        i = j + 1
                    }
                }
            }
            // Rows again, now the columns are known. In the scan's top and bottom
            // 4% a row counts only by its ink in those columns: the bed's corners,
            // the fold's head and a binding's last loops leave ink outside them.
            // A strip's ink was in every row: then no row counts ink outside the
            // columns (marks found past the text later bring their rows back).
            let stripped = before != (left, right)
            let from = pieceKept.lo ? max(bx0, left) : max(rowX0, left)
            let to = max(from, pieceKept.hi ? min(bx1, right + 1) : min(rowX1, right + 1))
            if stripped { countedRows = from..<to }
            top = by1; bottom = by0 - 1
            for y in by0..<by1 {
                let xs = stripped || !midRow(y) ? from..<to : rowX0..<rowX1
                if xs.filter({ ink($0, y) }).count > Int(Double(bx1 - bx0) * minRunFraction) {
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }

        // A small folio or a mark just above or below the text has too few dark
        // pixels a row to count as a line; rows of ink in the text's columns
        // that carry straight on from the first or last line (gaps of a pixel
        // or two) are taken in, up to a line's height or so (3% of the page).
        if bottom >= top && right >= left {
            let reach = max(3, (by1 - by0) * 3 / 100)
            func inked(_ y: Int) -> Bool { (left...right).filter { ink($0, y) }.count >= 2 }
            for step in [1, -1] {
                var y = (step > 0 ? bottom : top) + step, last = step > 0 ? bottom : top
                while y >= by0 && y < by1 && abs(y - last) <= 3 && abs(y - (step > 0 ? bottom : top)) <= reach {
                    if inked(y) { last = y }
                    y += step
                }
                if step > 0 { bottom = last } else { top = last }
            }
        }

        // A scanner's edge or the glass's border can leave a thin straight line
        // across the page beyond the text, near the scan's top or bottom. It is
        // one solid run of ink, rows thin, set off by a clear gap. (A footer line
        // or folio is broken into letters, and stays.)
        if bottom > top && right >= left {
            let thin = max(2, (by1 - by0) / 200), clearRows = max(3, (by1 - by0) / 50)
            let rowLimit = Int(Double(bx1 - bx0) * minRunFraction)
            func darkCount(_ y: Int) -> Int { (left...right).filter { Double(g.value($0, y)) < threshold }.count }
            func longestRun(_ y: Int) -> Int {
                var best = 0, run = 0
                for x in left...right { if Double(g.value(x, y)) < threshold { run += 1; best = max(best, run) } else { run = 0 } }
                return best
            }
            func ruleStrip(from start: Int, step: Int) -> Int? {
                var y = start, last = start, solid = 0
                while (y - start) * step <= thin + 2 && y >= top && y <= bottom {
                    if darkCount(y) > rowLimit { last = y; solid = max(solid, longestRun(y)) }
                    y += step
                }
                // ...and only near the scan's top or bottom: a printed rule under a
                // heading or above a footer is set well inside the page.
                let nearBorder = step < 0 ? by1 - 1 - start <= (by1 - by0) / 25 : start - by0 <= (by1 - by0) / 25
                guard nearBorder, (last - start) * step <= thin, Double(solid) >= 0.2 * Double(bx1 - bx0) else { return nil }
                // A scan's edge stands alone; a printed rule can be joined to strokes
                // running on from it (a frame's sides).
                let joined = (left...right).contains { x in
                    Double(g.value(x, last)) < threshold && last + step >= by0 && last + step < by1 && Double(g.value(x, last + step)) < threshold }
                guard !joined else { return nil }
                var next = last + step
                while next >= top && next <= bottom && darkCount(next) <= rowLimit { next += step }
                guard next >= top && next <= bottom, (next - last) * step >= clearRows else { return nil }
                return next
            }
            if let n = ruleStrip(from: bottom, step: -1) { bottom = n }
            if let n = ruleStrip(from: top, step: 1) { top = n }
        }

        // A line that runs past the rest of the block (a long line, a heading set
        // out into the margin) has too little ink for the column test. Follow its
        // ink outward from each side while the gaps stay word-sized (2% of the
        // width: small type on half a spread has wide gaps for its size), so the crop
        // never cuts it; a speck out in the margin is too far away to reach.
        if bottom >= top && right >= left {
            let maxGap = max(2, (bx1 - bx0) / 50)
            // Paler ink counts here (tiny type's thin strokes): this only ever
            // extends from text already found, so paper grain can't start it.
            let pale = paper * 0.85
            // Past a trimmed band or shadow, letters can still be printed over the
            // shadow's paler part: there a pixel is ink when it is clearly darker
            // than the brightest pixel near it in its row (a smooth shadow never is).
            // A shadow is no valley: inside one, only a pixel clearly darker than
            // the brightest pixel on each side of it within a few pixels is ink.
            // Those must be lit: in the scanner's black bed, or a black stripe by
            // the fold, noise makes valleys too. Print can be on paper in deep
            // shade, though, and there the shade itself is the light. Near a column
            // whose middle level is under a tenth of the paper's (the bed), the
            // light must be a fifth of the paper's; elsewhere a tenth will do.
            var shade = [Double](repeating: 0, count: x1 - x0)
            for x in x0..<x1 {
                var hist = [Int](repeating: 0, count: 256), seen = 0
                for y in by0..<by1 { hist[Int(g.value(x, y))] += 1 }
                for (v, n) in hist.enumerated() {
                    seen += n
                    if seen * 2 > by1 - by0 { shade[x - x0] = Double(v); break }
                }
            }
            func valley(_ x: Int, _ y: Int) -> Bool {
                var leftMax: UInt8 = 0, rightMax: UInt8 = 0
                for xx in max(x0, x - 6)..<x { leftMax = max(leftMax, g.value(xx, y)) }
                for xx in min(x1, x + 1)..<min(x1, x + 7) { rightMax = max(rightMax, g.value(xx, y)) }
                let lit = Double(min(leftMax, rightMax))
                let bed = shade[max(0, x - x0 - 6)..<min(x1 - x0, x - x0 + 7)].contains { $0 < 0.1 * paper }
                return lit >= (bed ? 0.2 : 0.1) * paper && Double(g.value(x, y)) < 0.7 * lit   // print, not mottling or noise
            }
            func isInk(_ x: Int, _ y: Int) -> Bool {
                guard x < bx0 || x >= bx1 else { return x >= lo[y] && x < hi[y] && Double(g.value(x, y)) < pale }
                return valley(x, y)
            }
            // A column inked over half its height is shading, not a line's tail.
            // Inside a shadow, a stroke runs at least 3 pixels down; the shadow's
            // own mottling leaves flecks of a pixel or two.
            // Nor does a stroke run on past a line's height (3% of the page): a
            // narrow black shadow between paper and the fold looks like print
            // across, but runs unbroken down the page, and its ragged edge leaves
            // long runs and flecks of a pixel or two among them. A heading's stroke
            // may run on to 12% of the page if no flecks share its column.
            func hasInk(_ x: Int) -> Bool {
                let inShadow = x < bx0 || x >= bx1
                var count = 0, run = 0, longest = 0, flecks = 0
                for y in top...(bottom + 1) {
                    if y <= bottom && isInk(x, y) { count += 1; run += 1; longest = max(longest, run) }
                    else { if run > 0 && run < 3 { flecks += 1 }; run = 0 }
                }
                let stroke = longest >= 3 && (longest <= max(3, (by1 - by0) * 3 / 100)
                                              || (longest <= (by1 - by0) * 12 / 100 && flecks == 0))
                return count > 0 && count * 2 <= bottom - top + 1 && (stroke || !inShadow)
            }
            var gap = 0, x = right + 1
            while x <= rightLimit && gap <= maxGap {
                if hasInk(x) { right = x; gap = 0 } else { gap += 1 }
                x += 1
            }
            gap = 0; x = left - 1
            while x >= leftLimit && gap <= maxGap {
                if hasInk(x) { left = x; gap = 0 } else { gap += 1 }
                x -= 1
            }

            // Marks printed on a trimmed shadow (line numbers in the margin, over
            // the page's darkened edge) are found however far from the text they
            // sit: columns of valley ink in short runs, more than one run down the
            // page. A band's streaks run on; a speck is a single run.
            func marks(_ x: Int) -> Bool {
                // Runs at least 3 pixels tall (a digit's stroke; a shadow's mottling
                // leaves flecks of a pixel or two), at most 3% of the page.
                var count = 0, runs = 0, run = 0, longest = 0, all = 0
                func close() { if run >= 3 { runs += 1; count += run; longest = max(longest, run) }; run = 0 }
                for y in top...bottom {
                    if valley(x, y) { run += 1; all += 1 } else { close() }
                }
                close()
                return count >= max(3, Int(Double(bottom - top + 1) * minRunFraction)) && runs >= 2
                    && all * 2 <= bottom - top + 1 && longest <= max(3, (by1 - by0) * 3 / 100)
            }
            // The trimmed zones: a band or shadow cut off the side, and any edge strip removed.
            // A printed mark is several pixels wide; a fleck of dust is one.
            func supported(_ x: Int) -> Bool { marks(x) && ((x > x0 && marks(x - 1)) || (x + 1 < x1 && marks(x + 1))) }
            if let far = stride(from: markX1 - 1, through: min(bx1, rightLimit + 1), by: -1).first(where: supported) {
                right = max(right, far)
            }
            if let far = stride(from: markX0, through: max(bx0 - 1, leftLimit - 1), by: 1).first(where: supported) {
                left = min(left, far)
            }
            // Rows counted only in the text's columns leave out marks found past
            // them since: their rows come back with them.
            if let counted = countedRows {
                let past = Array(left..<min(right + 1, counted.lowerBound)) + Array(max(left, counted.upperBound)..<(right + 1))
                for y in by0..<by1 where (y < top || y > bottom) && past.filter({ isInk($0, y) }).count >= 2 {
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }

        // A line of its own beside the text block (a running foot set off to the
        // side, a folio, a caption): a band of content rows with nothing in the
        // block's columns. Its small type can be too short for the column test.
        // A speck is smaller than any line of type, and stays out.
        if bottom > top && right >= left {
            let rowLimit = Int(Double(bx1 - bx0) * minRunFraction)
            let minThick = max(2, (by1 - by0) / 250), minWide = max(3, (bx1 - bx0) / 100)
            var y = top
            while y <= bottom {
                guard (rowX0..<rowX1).filter({ ink($0, y) }).count > rowLimit else { y += 1; continue }
                var end = y
                while end + 1 <= bottom && (rowX0..<rowX1).filter({ ink($0, end + 1) }).count > rowLimit { end += 1 }
                let inBlock = (y...end).contains { yy in (left...right).contains { ink($0, yy) } }
                if !inBlock && end - y + 1 >= minThick {
                    // Its ink across the band, column by column: a line of type is
                    // pieces side by side (letters, digits); dust is one piece.
                    let inked = (bx0..<bx1).map { x in (y...end).contains { ink(x, $0) } }
                    var lo = Int.max, hi = Int.min, pieces = 0
                    for (i, on) in inked.enumerated() where on {
                        if i == 0 || !inked[i - 1] { pieces += 1 }
                        lo = min(lo, bx0 + i); hi = max(hi, bx0 + i)
                    }
                    if pieces >= 2 && hi - lo + 1 >= minWide { left = min(left, lo); right = max(right, hi) }
                }
                y = end + 1
            }
        }

        // Fallback to the full sub-range if we found nothing.
        // Nothing found (a blank page): the page area left once bands are trimmed.
        // A box under 3% of the page in both directions is a speck of dust, not
        // content (a one-line title is far wider), and so is one at most 2 px
        // thick (a stray scan line; at analysis size, 800 px at most, no line of
        // text or printed rule is that thin): treat the page as blank.
        let boxW = right - left + 1, boxH = bottom - top + 1
        let speck = right >= left && bottom >= top
            && ((Double(boxW) < 0.03 * Double(bx1 - bx0) && Double(boxH) < 0.03 * Double(by1 - by0))
                || boxW <= 2 || boxH <= 2)
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
        // The padding stops at the split, so it never takes in the facing page.
        let x0Clamped = max(rect.x, xRange.lowerBound)
        rect.width = min(rect.maxX, xRange.upperBound) - x0Clamped
        rect.x = x0Clamped
        // A box narrower than the smallest crop grows inward, staying on its side.
        let minWidth = min(0.02, xRange.upperBound - xRange.lowerBound)
        if rect.width < minWidth {
            rect.x = min(rect.x, xRange.upperBound - minWidth)
            rect.width = minWidth
        }
        rect.normalize()
        // normalize() can still widen a box in a region narrower than its minimum.
        let x0Final = max(rect.x, xRange.lowerBound)
        rect.width = min(rect.maxX, xRange.upperBound) - x0Final
        rect.x = x0Final
        return (rect, false)
    }
}
