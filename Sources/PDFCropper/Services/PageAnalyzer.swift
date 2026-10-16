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
        // A shadow that runs at a slant (the binding shadow, once its half has
        // been straightened) fills no single column. Row by row, though, it is
        // ink starting at the region's edge in nearly every row, where text near
        // an edge leaves the gaps between its lines empty. Trim to where that edge
        // ink ends in nearly every row, if it is shadow-narrow (a full-height
        // plate at the gutter is far wider, and stays).
        func slantedShadowEnd(from start: Int, step: Int) -> Int? {
            let depth = max(4, spanW * 8 / 100), wedge = depth / 2
            func inside(_ x: Int) -> Bool { x >= x0 && x < x1 }
            var ends: [(y: Double, end: Double)] = [], sampled = 0
            for y in stride(from: 0, to: g.height, by: 2) {
                sampled += 1
                var x = start, k = 0
                while k < wedge && inside(x) && Double(g.value(x, y)) >= threshold { x += step; k += 1 }
                guard k < wedge && inside(x) else { continue }
                var gap = 0
                while k < depth && gap <= 1 && inside(x) {
                    if Double(g.value(x, y)) < threshold { gap = 0 } else { gap += 1 }
                    x += step; k += 1
                }
                guard k < depth && inside(x) else { return nil }     // ink running deep: not a shadow
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
            let deepest = max(fit.a, fit.a + fit.b * Double(g.height - 1)) + 2
            return start + step * Int(min(Double(depth), deepest).rounded(.up))
        }
        if bx1 - bx0 > spanW / 2 {
            // From the region's own edge: the column test may have taken part of it.
            if let e = slantedShadowEnd(from: x0, step: 1) { bx0 = max(bx0, e) }
            if let e = slantedShadowEnd(from: x1 - 1, step: -1) { bx1 = min(bx1, e + 1) }
        }
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

        var top = by1, bottom = by0 - 1, left = bx1, right = bx0 - 1

        // Rows skip a thin strip along each side: a straightened page can leave a
        // few pixels of a scanner band there in every row.
        let sideStrip = max(1, (bx1 - bx0) * 15 / 1000)
        func scanRows(_ xs: Range<Int>) {
            top = by1; bottom = by0 - 1
            for y in by0..<by1 {
                var darkInRow = 0
                for x in xs where Double(g.value(x, y)) < threshold {
                    darkInRow += 1
                }
                if darkInRow > Int(Double(bx1 - bx0) * minRunFraction) {
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        let rowX0 = min(bx1, bx0 + sideStrip), rowX1 = max(rowX0, bx1 - sideStrip)
        scanRows(rowX0..<rowX1)
        // Columns are judged against the height of the content the rows found, not
        // the whole page: a page holding a single line (a chapter's last line, a
        // footnote) would otherwise have no column dark enough and read as blank.
        let contentHeight = bottom >= top ? bottom - top + 1 : by1 - by0
        var columnDark = [Int](repeating: 0, count: max(0, bx1 - bx0))
        for x in bx0..<bx1 {
            var darkInCol = 0
            for y in by0..<by1 where Double(g.value(x, y)) < threshold {
                darkInCol += 1
            }
            columnDark[x - bx0] = darkInCol
            if darkInCol > Int(Double(contentHeight) * minRunFraction) {
                left = min(left, x); right = max(right, x)
            }
        }

        // The book block's edge (the other pages' edges, seen as thin streaks
        // beside a scanner band or at the fold) is a narrow cluster of tall ink
        // at the very edge of what was found, then a clear gap before the text.
        // A folio is short and a column of line numbers is wide; they stay.
        var leftLimit = x0, rightLimit = x1 - 1
        if right > left {
            let isContent = { (x: Int) in columnDark[x - bx0] > Int(Double(contentHeight) * minRunFraction) }
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
                // there with a clear gap inside it), however short.
                let border = max(2, (bx1 - bx0) * 15 / 1000)
                let atBorder = step > 0 ? last - bx0 <= border : bx1 - 1 - last <= border
                let streak = Double(tallest) >= 0.12 * Double(by1 - by0) && (Double(longest) >= 0.04 * Double(by1 - by0) || dashed)
                guard (last - start) * step <= narrow, streak || atBorder else { return nil }
                var next = last + step
                while next >= left && next <= right && !isContent(next) { next += step }
                guard next >= left && next <= right, (next - last) * step >= clear else { return nil }
                return next
            }
            let before = (left, right)
            if let n = strip(from: left, step: 1) { leftLimit = max(bx0, n - clear + 1); left = n }
            if let n = strip(from: right, step: -1) { rightLimit = min(bx1 - 1, n + clear - 1); right = n }
            // The strip's ink was in every row: count the rows again without it.
            if before != (left, right) {
                let from = max(rowX0, left)
                scanRows(from..<max(from, min(rowX1, right + 1)))
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
            func valley(_ x: Int, _ y: Int) -> Bool {
                var leftMax: UInt8 = 0, rightMax: UInt8 = 0
                for xx in max(x0, x - 6)..<x { leftMax = max(leftMax, g.value(xx, y)) }
                for xx in min(x1, x + 1)..<min(x1, x + 7) { rightMax = max(rightMax, g.value(xx, y)) }
                return Double(g.value(x, y)) < 0.7 * Double(min(leftMax, rightMax))   // print, not mottling
            }
            func isInk(_ x: Int, _ y: Int) -> Bool {
                guard x < bx0 || x >= bx1 else { return Double(g.value(x, y)) < pale }
                return valley(x, y)
            }
            // A column inked over half its height is shading, not a line's tail.
            // Inside a shadow, a stroke runs at least 3 pixels down; the shadow's
            // own mottling leaves flecks of a pixel or two.
            func hasInk(_ x: Int) -> Bool {
                let inShadow = x < bx0 || x >= bx1
                var count = 0, run = 0, stroke = false
                for y in top...bottom {
                    if isInk(x, y) { count += 1; run += 1; if run >= 3 { stroke = true } } else { run = 0 }
                }
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
            if let far = stride(from: x1 - 1, through: min(bx1, rightLimit + 1), by: -1).first(where: supported) {
                right = max(right, far)
            }
            if let far = stride(from: x0, through: max(bx0 - 1, leftLimit - 1), by: 1).first(where: supported) {
                left = min(left, far)
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
                guard (rowX0..<rowX1).filter({ Double(g.value($0, y)) < threshold }).count > rowLimit else { y += 1; continue }
                var end = y
                while end + 1 <= bottom && (rowX0..<rowX1).filter({ Double(g.value($0, end + 1)) < threshold }).count > rowLimit { end += 1 }
                let inBlock = (y...end).contains { yy in (left...right).contains { Double(g.value($0, yy)) < threshold } }
                if !inBlock && end - y + 1 >= minThick {
                    // Its ink across the band, column by column: a line of type is
                    // pieces side by side (letters, digits); dust is one piece.
                    let inked = (bx0..<bx1).map { x in (y...end).contains { Double(g.value(x, $0)) < threshold } }
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
