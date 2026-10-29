import Foundation
import CoreGraphics

/// Detects column / table structure on a page image so each text column can be
/// OCR'd separately. Vision otherwise reads straight across a column gap, merging
/// side-by-side text ("A habit conducive to" + "a stable way of acting" become one
/// scrambled line). A light XY-cut fixes this:
///   1. If the page has a clean full-height gutter, it is a uniform multi-column
///      layout — split into full-height columns.
///   2. Otherwise the page is one main column that may contain embedded multi-column
///      bands (syllogism tables, two-column footnotes). Isolate horizontal bands by
///      white row-gaps, split only the bands that have an internal vertical gutter,
///      and keep runs of single-column prose merged into large blocks (so prose is
///      not needlessly fragmented into many OCR passes).
///
/// Blocks are returned in reading order (bands top→bottom, columns left→right) as
/// normalized [0,1] rects with a TOP-LEFT origin. An empty result means "no useful
/// split — treat the page as one block" (identical to the previous behaviour).
enum LayoutAnalyzer {

    private struct PRect {
        var x0: Int, x1: Int, y0: Int, y1: Int
        var width: Int { x1 - x0 }
        var height: Int { y1 - y0 }
    }

    static func columnBlocks(_ image: CGImage) -> [CGRect] {
        guard let g = GrayBuffer(cgImage: image) else { return [] }

        var maxV: UInt8 = 0
        for p in g.pixels where p > maxV { maxV = p }
        let thr = Double(maxV) * 0.6   // darker than 60% of paper = ink

        let W = g.width, H = g.height
        let minGutter = max(2, Int(0.015 * Double(W)))  // vertical gap = real column gutter
        let minColW   = max(4, Int(0.05 * Double(W)))   // discard thin edge slivers
        let maxJoin   = Int(0.04 * Double(W))           // a sliver this close joins its neighbour
        let minBandH  = max(4, Int(0.025 * Double(H)))  // don't column-split a single line
        let minRowGap = max(2, Int(0.010 * Double(H)))  // white gap that separates bands
        let inkFrac   = 0.01                            // a line this dark counts as "ink"
        let maxColInk = 0.4                             // denser than this = solid shadow, not text

        func colDark(_ x: Int, _ y0: Int, _ y1: Int) -> Double {
            var d = 0
            for y in y0..<y1 where Double(g.value(x, y)) < thr { d += 1 }
            return Double(d) / Double(max(1, y1 - y0))
        }
        func rowDark(_ y: Int, _ x0: Int, _ x1: Int) -> Double {
            var d = 0
            for x in x0..<x1 where Double(g.value(x, y)) < thr { d += 1 }
            return Double(d) / Double(max(1, x1 - x0))
        }

        // Tight ink bounding box within a region (ignores white padding/margins).
        func inkBox(_ ax0: Int, _ ax1: Int, _ ay0: Int, _ ay1: Int) -> PRect? {
            guard ax1 > ax0, ay1 > ay0 else { return nil }
            var left = ax1, right = ax0, top = ay1, bot = ay0
            for y in ay0..<ay1 where rowDark(y, ax0, ax1) > inkFrac { top = min(top, y); bot = max(bot, y + 1) }
            for x in ax0..<ax1 where colDark(x, ay0, ay1) > inkFrac { left = min(left, x); right = max(right, x + 1) }
            guard right > left, bot > top else { return nil }
            return PRect(x0: left, x1: right, y0: top, y1: bot)
        }
        func tighten(_ r: PRect) -> PRect? { inkBox(r.x0, r.x1, r.y0, r.y1) }

        // Fraction of a region's pixels that are ink. Text columns sit around ~0.1;
        // a solid scan-shadow band is far denser, which lets us reject it as a column.
        func inkDensity(_ r: PRect) -> Double {
            guard r.width > 0, r.height > 0 else { return 0 }
            var dark = 0
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 where Double(g.value(x, y)) < thr { dark += 1 }
            }
            return Double(dark) / Double(r.width * r.height)
        }

        // Split a region into columns at white vertical gutters; join or drop slivers; tighten.
        func columnsIn(_ r: PRect) -> [PRect] {
            var gaps: [(Int, Int)] = []
            var s = -1
            for x in r.x0..<r.x1 {
                if colDark(x, r.y0, r.y1) < inkFrac {
                    if s < 0 { s = x }
                } else if s >= 0 {
                    if x - s >= minGutter { gaps.append((s, x)) }
                    s = -1
                }
            }
            if s >= 0, r.x1 - s >= minGutter { gaps.append((s, r.x1)) }

            var cols: [PRect] = []
            var cx = r.x0
            for gp in gaps {
                if gp.0 > cx { cols.append(PRect(x0: cx, x1: gp.0, y0: r.y0, y1: r.y1)) }
                cx = gp.1
            }
            if cx < r.x1 { cols.append(PRect(x0: cx, x1: r.x1, y0: r.y0, y1: r.y1)) }

            // A column too narrow to stand alone joins the nearer full-width
            // neighbour when it is close: dropping it lost the item numbers ("3." of
            // "3. Type D") on Wallace 1957. Farther slivers, and ones that aren't
            // print, are dropped: dense over the region's height (scanner strip,
            // shadow) or near solid where they have ink (a short mark, a rule).
            while let i = cols.firstIndex(where: { $0.width < minColW }) {
                let c = cols.remove(at: i)
                guard inkDensity(c) < maxColInk, let ink = tighten(c), inkDensity(ink) < 0.85 else { continue }
                let left = i > 0 && cols[i - 1].width >= minColW ? c.x0 - cols[i - 1].x1 : Int.max
                let right = i < cols.count && cols[i].width >= minColW ? cols[i].x0 - c.x1 : Int.max
                guard min(left, right) <= maxJoin else { continue }
                let j = left <= right ? i - 1 : i
                cols[j] = PRect(x0: min(cols[j].x0, c.x0), x1: max(cols[j].x1, c.x1), y0: r.y0, y1: r.y1)
            }

            return cols
                .compactMap { tighten($0) }
                .filter { inkDensity($0) < maxColInk }   // drop solid shadow bands
        }

        // Split a region into horizontal bands at white row-gaps.
        func bandsIn(_ r: PRect) -> [PRect] {
            var gaps: [(Int, Int)] = []
            var s = -1
            for y in r.y0..<r.y1 {
                if rowDark(y, r.x0, r.x1) < inkFrac {
                    if s < 0 { s = y }
                } else if s >= 0 {
                    if y - s >= minRowGap { gaps.append((s, y)) }
                    s = -1
                }
            }
            if s >= 0, r.y1 - s >= minRowGap { gaps.append((s, r.y1)) }

            var bands: [PRect] = []
            var cy = r.y0
            for gp in gaps {
                if gp.0 > cy { bands.append(PRect(x0: r.x0, x1: r.x1, y0: cy, y1: gp.0)) }
                cy = gp.1
            }
            if cy < r.y1 { bands.append(PRect(x0: r.x0, x1: r.x1, y0: cy, y1: r.y1)) }
            return bands
        }

        func union(_ a: PRect, _ b: PRect) -> PRect {
            PRect(x0: min(a.x0, b.x0), x1: max(a.x1, b.x1),
                  y0: min(a.y0, b.y0), y1: max(a.y1, b.y1))
        }
        func norm(_ r: PRect) -> CGRect {
            CGRect(x: Double(r.x0) / Double(W), y: Double(r.y0) / Double(H),
                   width: Double(r.width) / Double(W), height: Double(r.height) / Double(H))
        }

        guard let ink = inkBox(0, W, 0, H) else { return [] }

        // 1. Uniform full-height columns (journal / dictionary layouts).
        let fullColumns = columnsIn(ink)
        if fullColumns.count > 1 {
            return fullColumns.map { norm($0) }
        }

        // 2. Single main column with possible embedded multi-column bands.
        var blocks: [PRect] = []
        var pending: PRect?
        for band in bandsIn(ink) {
            let cols = band.height >= minBandH ? columnsIn(band) : [tighten(band)].compactMap { $0 }
            if cols.count > 1 {
                if let p = pending { blocks.append(p); pending = nil }
                blocks.append(contentsOf: cols)
            } else if let only = cols.first {
                pending = pending.map { union($0, only) } ?? only
            }
        }
        if let p = pending { blocks.append(p) }

        guard blocks.count > 1 else { return [] }
        return blocks.map { norm($0) }
    }
}
