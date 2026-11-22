import Foundation
import CoreGraphics

/// Remove shadows (an export option): the fold's shadow, a black band at the fold,
/// the fold's crease line and the streaks, ticks and specks beside it go, so the
/// page is clean paper up to its sides; print stays.
///
/// - Black and white: `clearSides` runs on the page's ink after `BlackAndWhite.ink`.
/// - Color and grayscale (`page`): the paper is evened out (each pixel brightened by
///   how much darker the paper under it is than the page's paper color, but paper
///   never past that color), and what black and white would call ink but
///   `clearSides` and the steps before it found not to be print is painted the
///   page's paper color, with its rim and fringe (up to 0.025 inch, where joined to it).
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
    /// - a rule: flat, 1.5 `t` long or more, not touching the page's side; or upright,
    ///   unbroken, even, straight and alone, away from the sides (see `uprightRule`);
    /// - a glyph or word on its own (a folio, a marginal number or note): 0.5 to 2.2
    ///   `t` tall, not thin, solid enough, not touching the side, with no other
    ///   marks about it but those of its own row or column (a column of page or line
    ///   numbers) and thin upright ones (a fold's specks come in crowds, near the side
    ///   or many; a stripe or tick beside a folio is no crowd); and a letter beside such
    ///   a glyph (the 1 of a folio 10), punctuation within its rows (the full stop of a
    ///   hanging list number), or a dot or accent over a kept letter.
    /// Specks within 0.1 `t` of each other are judged together, so print broken
    /// into pieces by a pale scan is judged whole. Everything else goes: streaks,
    /// ticks, broken lines, the striped edges of the page stack, specks, and
    /// anything touching the side. A page with fewer than three text lines is left
    /// as it is. Returns whether it ran.
    @discardableResult
    static func clearSides(_ out: inout [UInt8], _ w: Int, _ h: Int, dpi: Double, keep: [Bool]? = nil) -> Bool {
        guard w > 2, h > 2, out.count == w * h else { return false }
        let cc = Components(out, w, h)
        let blobs = cc.blobs
        guard let lines = textLines(blobs, dpi: dpi) else { return false }
        let t = lines.t, minGlyph = lines.minGlyph, lineMembers = lines.lineMembers, chained = lines.chained
        let left = lines.left, right = lines.right
        var parent = lines.parent
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var c = i
            while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
            return r
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
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
        // Marks inside the block near its edges, letter-sized or bigger.
        let inBlock = blobs.indices.filter { k in
            let m = blobs[k]
            return !zoned.contains(k) && m.count >= minGlyph && Double(m.height) >= 0.45 * t
                && (m.minX < left + 4 * reach || m.maxX > right - 4 * reach)
        }
        // Small marks beside a line's mark: punctuation, footnote markers, accents;
        // not a tall thin one (a tick, a piece of a fold line).
        var attached = Set<Int>()
        let small = 1.2 * t
        for i in zone {
            let b = blobs[i]
            if Double(b.width) <= small, Double(b.height) <= small,
               Double(b.height) < 0.5 * t || b.width * 4 >= b.height {
                for m in nearMembers {
                    let gap = max(0, b.minX - m.maxX - 1, m.minX - b.maxX - 1)
                    if Double(gap) <= t, Double(b.minY) >= Double(m.minY) - 0.8 * t, Double(b.maxY) <= Double(m.maxY) + 0.5 * t {
                        attached.insert(i); break
                    }
                }
            } else if Double(b.width) >= 0.3 * t, b.width * 5 >= b.height {
                // A big letter starting or ending a line (a title's capital, a drop cap):
                // not thin, sharing a row with ink inside the block (the rest of its word,
                // which may be too big to be a text line), no further from it than a
                // letter (or half its own height).
                let reachX = max(t, 0.5 * Double(b.height))
                for k in inBlock {
                    let m = blobs[k]
                    let gap = max(0, b.minX - m.maxX - 1, m.minX - b.maxX - 1)
                    let overlap = min(b.maxY, m.maxY) - max(b.minY, m.minY) + 1
                    if Double(gap) <= reachX, 2 * overlap >= min(m.height, b.height) { attached.insert(i); break }
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
        // A printed upright rule (a margin rule, a table's rule that doesn't meet its
        // horizontals): one mark, thin, 0.3 inch and 1.6 `t` tall or more, 0.25 inch or more
        // from the sides, unbroken (one run of ink on every row), even (each row's run
        // within a pixel or a quarter of the middle width), straight (its middles within
        // 1.5 px or 0.004 inch of a line), and alone: no other thin upright mark beside it
        // within 0.1 inch (the page stack's edge is a stack of stripes) nor in line with it
        // within 0.3 inch above or below (a fold line broken into pieces).
        let away = Int((0.1 * dpi).rounded()), fromSide = Int((0.25 * dpi).rounded()), tall = 0.3 * dpi
        func thinUpright(_ m: Mark) -> Bool {
            let mw = m.maxX - m.minX + 1, mh = m.maxY - m.minY + 1
            return mh >= 3 * mw && Double(mh) >= 0.3 * t
        }
        func uprightRule(_ m: Mark, among all: () -> [Mark]) -> Bool {
            let mw = m.maxX - m.minX + 1, mh = m.maxY - m.minY + 1
            guard m.blobs.count == 1, mw * 5 < mh, Double(mh) >= max(tall, 1.6 * t),
                  m.minX >= fromSide, m.maxX < w - fromSide else { return false }
            let rows = cc.rows(m.blobs[0])
            guard rows.count == mh, rows.allSatisfy({ $0.count == 1 }) else { return false }
            let widths = rows.map { $0[0].1 - $0[0].0 + 1 }.sorted()
            let mid = widths[widths.count / 2], slack = max(1, mid / 4)
            guard widths.first! >= mid - slack, widths.last! <= mid + slack else { return false }
            // Straight: the run middles against their least-squares line.
            let ys = (0..<mh).map(Double.init), xs = rows.map { Double($0[0].0 + $0[0].1) / 2 }
            let my = ys.reduce(0, +) / Double(mh), mx = xs.reduce(0, +) / Double(mh)
            var sxy = 0.0, syy = 0.0
            for i in 0..<mh { sxy += (ys[i] - my) * (xs[i] - mx); syy += (ys[i] - my) * (ys[i] - my) }
            let slope = syy > 0 ? sxy / syy : 0
            let worst = (0..<mh).map { abs(xs[$0] - (mx + slope * (ys[$0] - my))) }.max() ?? 0
            guard worst <= max(1.5, 0.004 * dpi) else { return false }
            return !all().contains { q in
                guard q.minY != m.minY || q.minX != m.minX, thinUpright(q) else { return false }
                let overlapY = min(q.maxY, m.maxY) - max(q.minY, m.minY) + 1
                let gapX = max(0, q.minX - m.maxX - 1, m.minX - q.maxX - 1)
                let overlapX = min(q.maxX, m.maxX) - max(q.minX, m.minX) + 1
                let gapY = max(0, q.minY - m.maxY - 1, m.minY - q.maxY - 1)
                return (overlapY > 0 && gapX <= away) || (overlapX > 0 && Double(gapY) <= tall)
            }
        }
        // Print a binding's teeth were judged by (see `clearTeeth`).
        func kept(_ m: Mark) -> Bool {
            guard let keep else { return false }
            return m.blobs.contains { b in cc.count(b, where: { keep[$0] }) > 0 }
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
        func sameColumn(_ a: Mark, _ b: Mark) -> Bool {
            let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX) + 1
            return 2 * overlap >= min(a.maxX - a.minX + 1, b.maxX - b.minX + 1)
        }
        func letterTall(_ m: Mark) -> Bool {
            let mh = Double(m.maxY - m.minY + 1)
            return mh >= 0.45 * t && mh <= 2.2 * t && !touchesSide(m)
        }
        // A glyph on its own: other marks about it, but for its own row's and its own
        // column's (a column of page or line numbers, a list's hanging numbers), hold under
        // a tenth of its ink. Specks count against it only near a side (within 0.25 inch),
        // where the fold is, or eight or more of them: a fold's shadow turns to speckle in
        // black and white, while a few specks of dust on clean paper are no crowd.
        let around = Int(t.rounded()), flank = Int((0.25 * dpi).rounded())
        var keep = [Bool](repeating: false, count: list.count)
        for (n, m) in list.enumerated() {
            if flatRule(m) || kept(m) || uprightRule(m, among: { near(m, Int(tall)).map { list[$0] } }) { keep[n] = true; continue }
            guard shaped[n] else { continue }
            var crowd = 0, specks = 0
            for o in near(m, around) where o != n {
                let q = list[o]
                if (shaped[o] || letterTall(q)) && (sameRow(m, q) || sameColumn(m, q)) { continue }
                // A stripe or tick beside it is the fold's, not a crowd of glyph-like specks.
                let qw = Double(q.maxX - q.minX + 1), qh = Double(q.maxY - q.minY + 1)
                if qw < 0.3 * t && qh >= 0.5 * t { continue }
                crowd += q.count; specks += 1
            }
            let bySide = m.minX < flank || m.maxX >= w - flank
            keep[n] = (!bySide && specks < 8) || crowd * 10 <= m.count
        }
        // And a row of print too small or short for a text line (a word in small capitals,
        // a dedication, dot leaders): three or more solid marks up to 0.3 inch tall (a title
        // in capitals) or 3 `t`, none thin, not touching the side, alike in height (the
        // tallest at most twice the shortest), chained along a row (each overlapping the next by half the shorter's height, no further off than the
        // taller is tall or a text height), two thirds of them standing on one line (their
        // feet within a quarter of the middle height). A fold's speckle lies about at random,
        // not on a line.
        var inRow = Set<Int>()
        do {
            let rowMarks = list.indices.filter { n in
                let m = list[n], mw = m.maxX - m.minX + 1, mh = m.maxY - m.minY + 1
                return !keep[n] && m.count >= minGlyph && Double(mh) <= max(3 * t, 0.3 * dpi) && mw * 5 >= mh && mh * 5 >= mw
                    && Double(m.count) >= 0.12 * Double(mw * mh) && !touchesSide(m)
            }.sorted { list[$0].minX < list[$1].minX }
            var rowParent = [Int: Int]()
            func rowFind(_ i: Int) -> Int { var r = i; while let p = rowParent[r], p != r { r = p }; return r }
            for i in rowMarks { rowParent[i] = i }
            for (k, i) in rowMarks.enumerated() {
                let a = list[i], ah = a.maxY - a.minY + 1
                var j = k + 1
                while j < rowMarks.count, list[rowMarks[j]].minX <= a.maxX + 1 + max(2 * ah, Int(t.rounded())) {
                    let b = list[rowMarks[j]], bh = b.maxY - b.minY + 1
                    j += 1
                    let lo = min(ah, bh), hi = max(ah, bh)
                    let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY) + 1
                    let gap = max(0, b.minX - a.maxX - 1)
                    guard hi <= 2 * lo, 2 * overlap >= lo, Double(gap) <= max(Double(hi), t) else { continue }
                    let ra = rowFind(i), rb = rowFind(rowMarks[j - 1])
                    if ra != rb { rowParent[max(ra, rb)] = min(ra, rb) }
                }
            }
            var rows = [Int: [Int]]()
            for i in rowMarks { rows[rowFind(i), default: []].append(i) }
            for (_, members) in rows where members.count >= 3 {
                let heights = members.map { list[$0].maxY - list[$0].minY + 1 }
                guard heights.max()! <= 2 * heights.min()! else { continue }
                let midH = heights.sorted()[heights.count / 2]
                let feet = members.map { list[$0].maxY }.sorted()
                let foot = feet[feet.count / 2]
                let onLine = feet.filter { 4 * abs($0 - foot) <= midH }.count
                guard 3 * onLine >= 2 * members.count else { continue }
                for n in members { keep[n] = true; inRow.insert(n) }
            }
        }
        // And a word whose letters run together (a coarse scan's small capitals): one mark
        // as tall as a row's above, at least one and a half times as wide as tall, a sixth
        // to three quarters solid, not touching the side, crossed by three or more strokes
        // at half its height, and standing on a line (three in five of its columns end
        // within a quarter of its height of its foot). A clump of speckle has no line to stand on.
        for (n, m) in list.enumerated() where !keep[n] {
            let mw = m.maxX - m.minX + 1, mh = m.maxY - m.minY + 1
            guard Double(mh) >= 0.5 * t, Double(mh) <= max(3 * t, 0.3 * dpi), 2 * mw >= 3 * mh,
                  6 * m.count >= mw * mh, 4 * m.count <= 3 * mw * mh, !touchesSide(m) else { continue }
            var foot = [Int](repeating: -1, count: mw)
            var strokes = 0
            let middle = m.minY + mh / 2
            for b in m.blobs {
                for (y, row) in zip(cc.rowNumbers(b), cc.rows(b)) {
                    for (x0, x1) in row {
                        for x in x0...x1 { foot[x - m.minX] = max(foot[x - m.minX], y) }
                        if y == middle { strokes += 1 }
                    }
                }
            }
            let inked = foot.filter { $0 >= 0 }
            let onLine = inked.filter { 4 * (m.maxY - $0) <= mh }.count
            if strokes >= 3, 5 * onLine >= 3 * inked.count { keep[n] = true; inRow.insert(n) }
        }
        // And a capital starting such a row or word (COPYRIGHT's C, run into its o): at most
        // 6 `t` and two and a half times the row's height, not thin, sharing the row, no
        // further off than half its height.
        for (n, m) in list.enumerated() where !keep[n] {
            let mw = m.maxX - m.minX + 1, mh = m.maxY - m.minY + 1
            guard Double(mh) >= 0.45 * t, Double(mh) <= 6 * t, mw * 5 >= mh, !touchesSide(m) else { continue }
            let reachX = max(Int(t.rounded()), mh / 2)
            keep[n] = near(m, reachX).contains { o in
                let q = list[o]
                return o != n && inRow.contains(o) && sameRow(m, q) && 2 * mh <= 5 * (q.maxY - q.minY + 1)
                    && max(0, q.minX - m.maxX - 1, m.minX - q.maxX - 1) <= reachX
            }
        }
        // And a letter beside a glyph kept so (the 1 of a folio 10).
        let beside = Int((0.6 * t).rounded())
        for (n, m) in list.enumerated() where !keep[n] && letterTall(m) {
            keep[n] = near(m, beside).contains { o in o != n && keep[o] && (shaped[o] || inRow.contains(o)) && sameRow(m, list[o]) }
        }
        // And punctuation beside such a glyph, within its rows (the full stop of a list's
        // hanging number 1.).
        for (n, m) in list.enumerated() where !keep[n] {
            guard Double(m.maxX - m.minX + 1) <= 0.5 * t, Double(m.maxY - m.minY + 1) <= 0.5 * t else { continue }
            keep[n] = near(m, beside).contains { o in
                let g = list[o]
                return o != n && keep[o] && (shaped[o] || inRow.contains(o)) && Double(m.minY) >= Double(g.minY) - 0.3 * t
                    && Double(m.maxY) <= Double(g.maxY) + 0.3 * t
            }
        }
        // And a thin letter on its own, with nothing within two letters of it: a folio
        // or marginal 1. A lone tick looks the same and stays too (losing print is
        // worse than leaving a mark); ticks in a crowd or a column still go.
        for (n, m) in list.enumerated() where !keep[n] {
            let mh = Double(m.maxY - m.minY + 1)
            guard mh >= 0.5 * t, mh <= 1.6 * t, m.maxX - m.minX + 1 >= 2, !touchesSide(m) else { continue }
            keep[n] = near(m, Int((2 * t).rounded())).allSatisfy { $0 == n }
        }
        // And a dot or accent over a kept letter (the i of a folio vi): small, sharing its
        // columns, at most 0.6 `t` above it.
        for (n, m) in list.enumerated() where !keep[n] {
            guard Double(m.maxX - m.minX + 1) <= 0.5 * t, Double(m.maxY - m.minY + 1) <= 0.5 * t else { continue }
            keep[n] = near(m, beside).contains { o in
                let g = list[o]
                return o != n && keep[o] && letterTall(g) && sameColumn(m, g) && m.maxY < g.minY
                    && Double(g.minY - m.maxY) <= 0.6 * t
            }
        }
        for (n, m) in list.enumerated() where !keep[n] { for i in m.blobs { cc.clear(i, in: &out) } }
        return true
    }

    /// A page's text lines, as `clearSides` measures them: its text height `t`, the
    /// marks of its lines (`lineMembers`, and `chained` with a line's stray ends), the
    /// text block's left and right edges, the line-chaining groups (`parent`), and each
    /// line's middle row (the middle of its marks' middles).
    struct TextLines {
        var t: Double
        var minGlyph: Int
        var lineMembers: Set<Int>
        var chained: Set<Int>
        var left: Int
        var right: Int
        var parent: [Int]
        var middles: [Int]
    }

    /// See `TextLines`; nil for a page with fewer than three text lines.
    static func textLines(_ blobs: [Blob], dpi: Double) -> TextLines? {
        guard !blobs.isEmpty else { return nil }
        // The text height.
        let minGlyph = max(4, Int((0.012 * dpi * 0.012 * dpi).rounded()))
        var heights: [Int] = []
        for b in blobs where b.count >= minGlyph {
            let bh = b.height, bw = b.width
            if Double(bh) >= 0.03 * dpi, Double(bh) <= 0.3 * dpi, Double(bw) <= 0.5 * dpi, bw * 4 >= bh {
                heights.append(bh)
            }
        }
        guard heights.count >= 20 else { return nil }
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
        var starts: [Int] = [], ends: [Int] = [], middles: [Int] = []
        for (_, ms) in lineOf where ms.count >= 3 {
            let wide = ms.filter { !thin(blobs[$0]) }
            guard wide.count >= 2, wide.count * 3 >= ms.count else { continue }
            let feet = ms.map { blobs[$0].maxY }.sorted()
            let base = feet[feet.count / 2]
            let onBase = feet.filter { Double(abs($0 - base)) <= 0.3 * t }.count
            guard onBase * 5 >= ms.count * 3 else { continue }
            let lo = wide.map { blobs[$0].minX }.min()!, hi = wide.map { blobs[$0].maxX }.max()!
            lineMembers.formUnion(ms.filter { blobs[$0].maxX >= lo && blobs[$0].minX <= hi })
            chained.formUnion(ms)
            starts.append(lo)
            ends.append(hi)
            middles.append(ms.map { (blobs[$0].minY + blobs[$0].maxY) / 2 }.sorted()[ms.count / 2])
        }
        guard starts.count >= 3 else { return nil }
        starts.sort(); ends.sort(by: >)
        let k = max(2, min(5, starts.count / 8))
        let left = starts[k - 1], right = ends[k - 1]
        guard left < right else { return nil }
        return TextLines(t: t, minGlyph: minGlyph, lineMembers: lineMembers, chained: chained, left: left, right: right,
                         parent: parent, middles: middles)
    }


    // MARK: Comb and spiral bindings

    /// The teeth of a comb or spiral binding down a side of the page, and the zone each
    /// leaves marks in. Teeth are solid dark blocks (under 55% of the page's paper,
    /// still there after an opening that wipes out anything under 0.03 inch or twice
    /// the page's stroke thick: letters' strokes, rules; dark runs down a column over
    /// 0.8 inch, the spine's band, left out), 0.06 to 0.6 inch tall and at least 0.03
    /// inch wide, three-fifths solid, within 0.8 inch of the left or right side, and
    /// four or more of them in one column (all sharing its columns), alike in height and
    /// width (within half to twice the middle one), apart, at a steady pitch (each gap
    /// one to four times the middle gap, give or take a fifth of a pitch each: teeth
    /// may be missed), spanning 1.5 inch or more (not a dark corner's or a shadow's
    /// speckle), and, given the page's ink, beside its text block (`textLines`). Once
    /// found, blocks under 75% of the paper in that column count too:
    /// paler teeth on the pitch, and the paler ends of the dark ones. A tooth's zone is its box
    /// grown by 0.03 inch, and by 0.12 inch toward the page's middle, where a comb's
    /// loops show through its holes; so are the gaps between teeth from their inner
    /// ends out to the side, where the comb's back shows.
    struct Teeth {
        var core: [Bool]       // the teeth themselves, grown by 2 px
        var zone: [Bool]
        var found: Bool
        var boxes: [Blob] = []  // each tooth's box, in the page's pixels
    }

    static func teeth(_ gray: [UInt8], _ w: Int, _ h: Int, dpi: Double, paper paperRef: Int, ink: [UInt8]? = nil) -> Teeth {
        var core = [Bool](repeating: false, count: w * h), zone = core
        var found = false
        var boxes: [Blob] = []
        var block: TextLines?? = nil       // the text block in `ink`, measured when first needed
        let strip = min(w, Int((0.8 * dpi).rounded()))
        guard strip > 4, h > 4 else { return Teeth(core: core, zone: zone, found: false) }
        // The page's stroke: the middle length of dark runs across its middle half. The
        // opening wipes out anything up to twice that thick (bold letters at the line
        // starts of a tight crop, which stand in a column at a steady pitch too).
        var runs: [Int] = []
        for y in stride(from: 0, to: h, by: 4) {
            var x = w / 4
            while x < 3 * w / 4 {
                guard Int(gray[y * w + x]) * 100 < paperRef * 55 else { x += 1; continue }
                let s = x
                while x < 3 * w / 4, Int(gray[y * w + x]) * 100 < paperRef * 55 { x += 1 }
                runs.append(x - s)
            }
        }
        let stroke = runs.isEmpty ? 0 : runs.sorted()[runs.count / 2]
        let open = max(1, Int((0.015 * dpi).rounded()), stroke)
        let grow = Int((0.03 * dpi).rounded()), inward = Int((0.12 * dpi).rounded())
        for right in [false, true] {
            let x0 = right ? w - strip : 0
            // Solid dark blocks under `level` percent of the paper, after an opening of
            // the dark: what survives is 0.03 inch thick or more all through.
            func blocks(_ level: Int) -> (opened: [UInt8], blobs: [Blob]) {
                var map = [UInt8](repeating: 255, count: strip * h)
                for y in 0..<h { for x in 0..<strip where Int(gray[y * w + x0 + x]) * 100 < paperRef * level { map[y * strip + x] = 0 } }
                // Dark runs down a column longer than any tooth (the spine's band or the
                // page's edge, which teeth may touch) are left out.
                let long = Int((0.8 * dpi).rounded())
                for x in 0..<strip {
                    var y = 0
                    while y < h {
                        guard map[y * strip + x] == 0 else { y += 1; continue }
                        let s = y
                        while y < h, map[y * strip + x] == 0 { y += 1 }
                        if y - s > long { for yy in s..<y { map[yy * strip + x] = 255 } }
                    }
                }
                let opened = LayeredScan.minFilter(LayeredScan.maxFilter(map, strip, h, radius: open), strip, h, radius: open)
                let blobs = Components(opened, strip, h).blobs.filter { b in
                    let bh = Double(b.height), bw = Double(b.width)
                    return bh >= 0.06 * dpi && bh <= 0.6 * dpi && bw >= 0.03 * dpi && bw <= 0.6 * dpi
                        && Double(b.count) >= 0.6 * bw * bh
                }
                return (opened, blobs)
            }
            let (opened, candidates) = blocks(55)
            guard candidates.count >= 4 else { continue }
            // The largest series in one column (most dark pixels: the teeth, not a thin
            // strip of their backs along the side).
            var best: [Blob] = []
            var mid = 0, midW = 0, pitch = 0
            for c in candidates {
                let column = candidates.filter { $0.maxX >= c.minX && $0.minX <= c.maxX }.sorted { $0.minY < $1.minY }
                let heights = column.map(\.height).sorted()
                let m = heights[heights.count / 2]
                let tall = column.filter { $0.height * 2 >= m && $0.height <= 2 * m }
                guard tall.count >= 4 else { continue }
                let mw = tall.map(\.width).sorted()[tall.count / 2]
                let alike = tall.filter { $0.width * 2 >= mw && $0.width <= 2 * mw }
                guard alike.count >= 4 else { continue }
                // Teeth cut off by the page's top or foot are left out of the pitch.
                let whole = alike.filter { $0.minY > 0 && $0.maxY < h - 1 }
                guard whole.count >= 4 else { continue }
                let gaps = zip(whole, whole.dropFirst()).map { $1.minY - $0.minY }.sorted()
                let midGap = gaps[gaps.count / 2]
                // Each gap one pitch, or a few (teeth missed), give or take a fifth of each.
                guard midGap > 0, gaps.allSatisfy({ g in
                          let r = Double(g) / Double(midGap), k = r.rounded()
                          return k >= 1 && k <= 4 && abs(r - k) <= 0.05 + 0.15 * k
                      }),
                      zip(whole, whole.dropFirst()).allSatisfy({ ($1.minY - $0.maxY) * 10 >= midGap }),
                      Double(alike[alike.count - 1].maxY - alike[0].minY) >= 1.5 * dpi
                else { continue }
                if alike.reduce(0, { $0 + $1.count }) > best.reduce(0, { $0 + $1.count }) {
                    best = alike; mid = m; midW = mw; pitch = midGap
                }
            }
            guard best.count >= 4 else { continue }
            // A comb, not a list: its teeth run down most of the page (half its height or
            // more), stand beside the text block (not in it, as bullets starting its lines
            // do), and keep their own pitch, not the lines' (a list's markers, even hanging
            // apart from the block, sit on its lines: three in four or more of them have
            // their middle within 0.3 of a text height of a line's middle).
            guard (best[best.count - 1].maxY - best[0].minY) * 2 >= h else { continue }
            if let ink {
                if block == nil { block = .some(textLines(Components(ink, w, h).blobs, dpi: dpi)) }
                if let b = block ?? nil {
                    best = best.filter { x0 + $0.maxX < b.left || x0 + $0.minX > b.right }
                    guard best.count >= 4 else { continue }
                    let near = 0.3 * b.t
                    let onLines = best.filter { o in
                        b.middles.contains { Double(abs($0 - (o.minY + o.maxY) / 2)) <= near }
                    }.count
                    guard onLines * 4 < best.count * 3 else { continue }
                }
            }
            found = true
            var teeth = best.map { ($0, opened) }
            // Paler teeth in the same column (a comb's teeth shade lighter where the
            // page lifts off the glass), under 75% of the paper, alike in size and on
            // the series' pitch.
            let colMin = best.map(\.minX).min()!, colMax = best.map(\.maxX).max()!
            let paler = blocks(75)
            // A tooth's paler end, past its dark part (curling up to 0.06 inch past its
            // rows, and reaching up to 0.15 inch past it toward the page), is the tooth too.
            var ends: [Blob] = []
            for b in paler.blobs where b.maxX >= colMin && b.minX <= colMax && b.height * 2 >= mid && b.height <= 2 * mid {
                if let d = best.first(where: { $0.maxY >= b.minY && $0.minY <= b.maxY }) {
                    if b.minY >= d.minY - 2 * grow, b.maxY <= d.maxY + 2 * grow,
                       right ? b.minX >= d.minX - inward - grow : b.maxX <= d.maxX + inward + grow { ends.append(b) }
                } else {
                    let r = Double(b.minY - best[best.count / 2].minY) / Double(pitch)
                    if b.width * 2 >= midW, b.width <= 2 * midW, abs(r - r.rounded()) <= 0.2 { teeth.append((b, paler.opened)) }
                }
            }
            for b in ends {
                for y in b.minY...b.maxY {
                    for x in b.minX...b.maxX where paler.opened[y * strip + x] == 0 { core[y * w + x0 + x] = true }
                }
            }
            teeth.sort { $0.0.minY < $1.0.minY }
            // The gaps between the teeth, from their inner ends out to the side, and half
            // a gap past the first and last: where the comb's back shows between them.
            let inner = right ? best.map(\.minX).sorted()[best.count / 2] : best.map(\.maxX).sorted()[best.count / 2]
            for y in max(0, teeth[0].0.minY - pitch / 2)...min(h - 1, teeth[teeth.count - 1].0.maxY + pitch / 2) {
                for x in (right ? inner : 0)...(right ? strip - 1 : inner) { zone[y * w + x0 + x] = true }
            }
            for (b, opened) in teeth {
                var page = b
                page.minX += x0; page.maxX += x0
                boxes.append(page)
                for y in b.minY...b.maxY {
                    for x in b.minX...b.maxX where opened[y * strip + x] == 0 { core[y * w + x0 + x] = true }
                }
                let zx0 = right ? b.minX - inward : b.minX - grow, zx1 = right ? b.maxX + grow : b.maxX + inward
                for y in max(0, b.minY - grow)...min(h - 1, b.maxY + grow) {
                    for x in max(0, zx0)...min(strip - 1, zx1) { zone[y * w + x0 + x] = true }
                }
            }
        }
        if found { core = LayeredScan.minFilter(core.map { $0 ? 0 : 255 }, w, h, radius: 2).map { $0 == 0 } }
        return Teeth(core: core, zone: zone, found: found, boxes: boxes)
    }

    /// Black and white: what a binding's teeth leave. Ink on a tooth goes. A mark lying
    /// (nine-tenths of it) in a tooth's zone goes when it is no print: when it holds no
    /// stroke (a straight run of ink 0.02 inch long, across or down, as letters, rules
    /// and brackets have), or when it is clearly paler than the page's print (its mean
    /// gray in `gray` more than a quarter of the way from the print's to `paper`): the
    /// loops and shading round a comb's teeth, which the scan turns to pale clumps. So does
    /// a pale mark touching a tooth (within 3 px) and lying in its zone. Nothing that
    /// looks like print goes (a stroke and print's darkness, or, however pale, a solid
    /// rule-shaped mark with a straight run 0.06 inch long); a tooth's ends go as part of the tooth (see
    /// `teeth`). A letter or folio touching a tooth keeps all of it off the tooth; a
    /// dark speck touching one is left to `clearSides` (losing print is worse than a speck).
    /// Returns the print it judged there (marks reaching into a zone with a stroke, as
    /// dark as print, but for thin upright lines), for `clearSides` to keep: a rule or
    /// bracket by a comb's teeth.
    @discardableResult
    static func clearTeeth(_ out: inout [UInt8], _ t: Teeth, _ gray: [UInt8], _ w: Int, _ h: Int, dpi: Double,
                           paper: Int) -> [Bool]? {
        guard t.found else { return nil }
        for i in 0..<(w * h) where t.core[i] { out[i] = 255 }
        // The page's print: the middle gray of its ink outside the zones.
        var counts = [Int](repeating: 0, count: 256), n = 0
        for i in stride(from: 0, to: w * h, by: 3) where out[i] == 0 && !t.zone[i] { counts[Int(gray[i])] += 1; n += 1 }
        var seen = 0, print = 0
        for v in 0..<256 { seen += counts[v]; if seen * 2 >= n { print = v; break } }
        let pale = Double(print) + 0.25 * Double(max(0, paper - print))
        let cc = Components(out, w, h)
        let run = max(4, Int((0.02 * dpi).rounded()))
        let nearTooth = LayeredScan.minFilter(t.core.map { $0 ? 0 : 255 }, w, h, radius: 3)
        let grow = Int((0.03 * dpi).rounded()), tall = Int((0.15 * dpi).rounded())
        let thin = Int((0.03 * dpi).rounded())
        var drop: [Int] = [], printed: [Int] = []
        for (k, b) in cc.blobs.enumerated() {
            let inZone = cc.count(k, where: { t.zone[$0] })
            guard inZone > 0 else { continue }
            var sum = 0
            _ = cc.count(k, where: { sum += Int(gray[$0]); return true })
            let paler = Double(sum) > pale * Double(b.count)
            // Print: as dark as the page's print with a stroke in it; or, paler, a gray rule:
            // three times as long as it is thick, solid (half its box or more, not a loop's
            // speckle), with a straight run 0.06 inch long. Nothing that looks like print goes.
            let isPrint = cc.hasStroke(k, run, in: out) && !paler
            let ruleLike = 3 * min(b.width, b.height) <= max(b.width, b.height) && b.count * 2 >= b.width * b.height
            let looksPrint = isPrint || (ruleLike && cc.hasStroke(k, 2 * grow, in: out))
            if cc.count(k, where: { nearTooth[$0] == 0 }) > 0 {
                // Touching a tooth: its loop if pale, lying in its zone and no print; else left
                // to the side rule, never kept for it (a tooth's trimmed rim is dark and
                // straight too).
                if paler && inZone * 10 >= b.count * 9 && !looksPrint { drop.append(k) }
                continue
            }
            // A thin upright line (under 0.03 inch wide, 0.15 inch tall or more) is left to
            // the side rule, unkept, when it is a page stack's stripe, whole or broken: 0.3
            // inch tall or more itself, or in line with other thin upright pieces (sharing
            // its columns, alike in width, gaps under 0.3 inch) that run 0.6 inch together,
            // by a binding as by the fold. Other ink above or below it (the rule under a
            // folio's 1) takes nothing away.
            func stripe() -> Bool {
                if b.height >= 2 * tall { return true }
                let pieces = cc.blobs.indices.filter { j in
                    let o = cc.blobs[j]
                    return j != k && o.height >= 2 * o.width && o.maxX >= b.minX - 1 && o.minX <= b.maxX + 1
                        && o.width * 2 >= b.width && o.width <= 2 * b.width
                }.map { cc.blobs[$0] }
                var lo = b.minY, hi = b.maxY, grew = true
                while grew {
                    grew = false
                    for o in pieces where (o.minY < lo || o.maxY > hi) && o.maxY >= lo - 2 * tall && o.minY <= hi + 2 * tall {
                        lo = min(lo, o.minY); hi = max(hi, o.maxY); grew = true
                    }
                }
                return hi - lo + 1 >= 4 * tall
            }
            if isPrint { if b.width >= thin || b.height < tall || !stripe() { printed.append(k) } }
            else if inZone * 10 >= b.count * 9 && !looksPrint { drop.append(k) }
        }
        var keep = [Bool](repeating: false, count: w * h)
        for k in printed { cc.mark(k, in: &keep) }
        for k in drop { cc.clear(k, in: &out) }
        return keep
    }

    // MARK: Color and grayscale

    /// A color or gray output page with its shadows removed (see the type's notes),
    /// at `dpi`. Pictures (see `BlackAndWhite.pictureCells`) are left as they are, and so
    /// is a page that is mostly dark itself (a cover).
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
        let ink = BlackAndWhite.ink(gray: gray, sharp: nil, tone: BlackAndWhite.holdsTones(gray, width: w, height: h), width: w, height: h,
                                    dpi: dpi, removeShadows: true, paper: paper)
        let reachPx = max(1, Int((0.004 * dpi).rounded()))
        let printNear = LayeredScan.minFilter(ink, w, h, radius: reachPx)        // 0 within reach of print
        // What black and white would take for ink, but isn't print.
        var junk = [UInt8](repeating: 255, count: w * h)
        for i in 0..<(w * h) {
            let b = Int(paper[i])
            if ink[i] != 0, gray[i] < 128 || Int(gray[i]) < b - max(20, b * 12 / 100) { junk[i] = 0 }
        }
        // How far painting may reach (see `paint` below), and kept out of the paper's color.
        let junkNear = LayeredScan.minFilter(junk, w, h, radius: max(reachPx, Int((0.025 * dpi).rounded())))
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
        // A page whose paper is mostly that dark, or that dark all round its edges (three
        // fifths of its outer 0.1 inch), is dark itself (a cover, light print on a dark
        // ground), not a light page with a band down a side: left as it is.
        var dark = 0
        for i in stride(from: 0, to: w * h, by: 7) where Double(paper[i]) < floor { dark += 1 }
        let edge = max(1, Int((0.1 * dpi).rounded()))
        var ring = 0, ringDark = 0
        for y in 0..<h {
            let rim = y < edge || y >= h - edge
            for x in 0..<w where rim || x < edge || x >= w - edge {
                ring += 1
                if Double(paper[y * w + x]) < floor { ringDark += 1 }
            }
        }
        if dark * 2 > (w * h + 6) / 7 || ringDark * 5 >= ring * 3 { return image }
        // What is painted: what isn't print, and on out to 0.025 inch through pixels
        // joined to it that aren't paper (darker than the paper under them, or off
        // the paper's hue): its soft rim and colored fringe (a comb tooth's pink edge).
        // Faint print apart from it has paper between, however close, and stays.
        var paint = junk.map { $0 == 0 }
        func offPaper(_ i: Int) -> Bool {
            if Int(gray[i]) < Int(paper[i]) - 6 { return true }
            guard channels == 4 else { return false }
            let r = Int(px[4 * i]), g = Int(px[4 * i + 1]), b = Int(px[4 * i + 2])
            let pr = Int(paperColor[0]), pg = Int(paperColor[1]), pb = Int(paperColor[2])
            return abs((r - g) - (pr - pg)) > 12 || abs((g - b) - (pg - pb)) > 12
        }
        var stack = paint.indices.filter { paint[$0] }
        while let k = stack.popLast() {
            let x = k % w, y = k / w
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let n = ny * w + nx
                if !paint[n], junkNear[n] == 0, offPaper(n) { paint[n] = true; stack.append(n) }
            }
        }
        let picture = BlackAndWhite.pictureMap(paper, gray, w, h, dpi: dpi)
        // A binding's teeth and the marks round them: painted, but for print.
        let comb = teeth(gray, w, h, dpi: dpi, paper: clean + 20, ink: ink)
        for i in 0..<(w * h) where !picture[i] {
            let isPrint = printNear[i] == 0
            let p = Double(paper[i])
            if !isPrint && (paint[i] || p < floor || comb.zone[i]) {
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

        /// Whether blob `k` holds a straight run of `run` pixels of ink across or down
        /// (`p` is the page it was found on; ink below one of its pixels is its own).
        func hasStroke(_ k: Int, _ run: Int, in p: [UInt8]) -> Bool {
            let h = p.count / width
            for i in runsOf[k] {
                let x0 = Int(runStart[i]), x1 = Int(runEnd[i]), y = Int(runRow[i])
                if x1 - x0 + 1 >= run { return true }
                guard y + run <= h else { continue }
                for x in x0...x1 where y == 0 || p[(y - 1) * width + x] != 0 {
                    if (1..<run).allSatisfy({ p[(y + $0) * width + x] == 0 }) { return true }
                }
            }
            return false
        }

        /// Blob `k`'s runs of ink row by row, top first: each row's (first, last) columns.
        func rows(_ k: Int) -> [[(Int, Int)]] {
            var byRow = [Int: [(Int, Int)]]()
            for i in runsOf[k] { byRow[Int(runRow[i]), default: []].append((Int(runStart[i]), Int(runEnd[i]))) }
            return byRow.keys.sorted().map { byRow[$0]! }
        }

        /// The rows `rows(k)` gives, top first.
        func rowNumbers(_ k: Int) -> [Int] {
            Array(Set(runsOf[k].map { Int(runRow[$0]) })).sorted()
        }

        /// How many of blob `k`'s pixels `inside` holds.
        func count(_ k: Int, where inside: (Int) -> Bool) -> Int {
            var n = 0
            for i in runsOf[k] {
                let row = Int(runRow[i]) * width
                for x in Int(runStart[i])...Int(runEnd[i]) where inside(row + x) { n += 1 }
            }
            return n
        }

        /// Set blob `k`'s pixels in `mask`.
        func mark(_ k: Int, in mask: inout [Bool]) {
            for i in runsOf[k] {
                let row = Int(runRow[i]) * width
                for x in Int(runStart[i])...Int(runEnd[i]) { mask[row + x] = true }
            }
        }

        /// Paint blob `k` paper.
        func clear(_ k: Int, in p: inout [UInt8]) {
            for i in runsOf[k] {
                let row = Int(runRow[i]) * width
                for x in Int(runStart[i])...Int(runEnd[i]) { p[row + x] = 255 }
            }
        }
    }
}
