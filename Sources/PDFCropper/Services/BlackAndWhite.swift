import Foundation
import CoreGraphics

/// Black and white from a gray page: ink black, everything else white, judged
/// against the paper around each pixel rather than one fixed gray, so the fold's
/// soft shadow, the paper's tint and the darkening at the page's edges go white
/// while print inside them stays.
///
/// - The paper: the page drawn small (about 50 DPI) and closed (lightest within
///   0.12 inch, then darkest within the same), which wipes out print up to a
///   quarter inch thick but follows shading that changes more slowly (and
///   shading that runs off the page's side, however narrow), then the darker of
///   each cell's neighbours, so a hard edge isn't ink either.
/// - Ink: grays darker than that paper by a margin. The sharp layer (a layered
///   scan's text layer, or a black-and-white scan's own black) is kept pixel for
///   pixel on clean paper; on shadow it is judged a touching group at a time on a
///   small blur, so the speckle a scanner makes of a shadow goes and a letter stays.
/// - Then what is not print: the color layer's blurred copy of the text, solid
///   dark bands and patches at the page's sides (`bands`, `clearRims`), and thin lines
///   along the sides (`clearEdgeLines`).
enum BlackAndWhite {

    /// The ink of a `width` × `height` page drawn at `dpi`. `gray` is the page with
    /// every layer (top-left origin rows); `sharp`, if given, marks the sharp
    /// layer's ink. With `sharp` nil, pixels under half gray are the sharp layer,
    /// and `tone` says whether the page holds grays worth reading as ink too (a
    /// grayscale scan, not a black-and-white one). Out: 0 for ink, 255 for paper;
    /// with `preview`, ink keeps its gray instead of turning black. With
    /// `removeShadows`, what is not print beside the text block goes too
    /// (`ShadowRemoval.clearSides`). `paper`, if given, is `background` of `gray` at `dpi`,
    /// already made by the caller.
    static func ink(gray: [UInt8], sharp: [Bool]?, tone: Bool, width w: Int, height h: Int,
                    dpi: Double, preview: Bool = false, removeShadows: Bool = false, paper given: [UInt8]? = nil) -> [UInt8] {
        guard w > 0, h > 0, gray.count == w * h else { return gray }
        let paper = given ?? background(gray, w, h, dpi: dpi)
        let clean = cleanLevel(paper)
        let sharpCut = preview ? 192 : 128
        func isSharp(_ i: Int) -> Bool { sharp?[i] ?? (Int(gray[i]) < sharpCut) }
        var out = [UInt8](repeating: 255, count: w * h)
        // Sharp ink on clean paper stays as it is; tones darker than the paper by the
        // margin are ink wherever they are.
        var pending = [Bool](repeating: false, count: w * h)
        var toneInk = [Bool](repeating: false, count: w * h)
        out.withUnsafeMutableBufferPointer { out in pending.withUnsafeMutableBufferPointer { pending in
        toneInk.withUnsafeMutableBufferPointer { toneInk in
        paper.withUnsafeBufferPointer { paper in gray.withUnsafeBufferPointer { gray in
            if let sharp {
                sharp.withUnsafeBufferPointer { sharp in
                    for i in 0..<(w * h) {
                        let b = Int(paper[i])
                        let sharpInk = sharp[i]
                        if sharpInk, b >= clean {
                            out[i] = 0
                        } else if tone, !sharpInk, Int(gray[i]) < b - max(20, b * 12 / 100) {
                            out[i] = 0
                            toneInk[i] = true
                        } else if sharpInk {
                            pending[i] = true
                        }
                    }
                }
            } else {
                for i in 0..<(w * h) {
                    let b = Int(paper[i])
                    let sharpInk = Int(gray[i]) < sharpCut
                    if sharpInk, b >= clean {
                        out[i] = 0
                    } else if tone, Int(gray[i]) < b - max(20, b * 12 / 100) {
                        out[i] = 0
                    } else if sharpInk {
                        pending[i] = true
                    }
                }
            }
        }}}}}
        // Bands first, found on all that might be ink, so a band's solid core
        // doesn't carry the speckle around it through as one dark group.
        let cleared = bands(out.indices.map { out[$0] == 0 || pending[$0] }, w, h, dpi: dpi)
        cleared.withUnsafeBufferPointer { cleared in
            out.withUnsafeMutableBufferPointer { out in pending.withUnsafeMutableBufferPointer { pending in
                toneInk.withUnsafeMutableBufferPointer { toneInk in
                    for i in 0..<(w * h) where cleared[i] { out[i] = 255; pending[i] = false; toneInk[i] = false }
                }
            }}
        }
        // Sharp ink on shadow, a touching group of the sharp layer at a time (a
        // letter half on clean paper is judged whole): kept when the group is at
        // least the size of a full stop and on the whole darker, on the small blur,
        // than the mean 0.05 inch around by a margin. A letter's strokes are; the
        // speckle a scanner makes of a shadow, which is the shadow's own gray on
        // average, is not.
        let minGlyph = max(4, Int((0.012 * dpi * 0.012 * dpi).rounded()))   // a full stop
        let sharpPx = (0..<(w * h)).map { isSharp($0) && !cleared[$0] }
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = [], group: [Int] = []
        var failed: [[Int]] = []
        // The blurs serve this test alone: none are made for a page without such ink.
        if pending.contains(true) {
            let blur = boxBlur(gray, w, h, radius: Int((0.008 * dpi).rounded()))
            let around = boxBlur(gray, w, h, radius: Int((0.05 * dpi).rounded()))
            blur.withUnsafeBufferPointer { blur in around.withUnsafeBufferPointer { around in
            sharpPx.withUnsafeBufferPointer { sharpPx in seen.withUnsafeMutableBufferPointer { seen in
            pending.withUnsafeBufferPointer { pending in out.withUnsafeMutableBufferPointer { out in
                for start in 0..<(w * h) where pending[start] && !seen[start] {
                    seen[start] = true
                    stack.removeAll(keepingCapacity: true); stack.append(start)
                    group.removeAll(keepingCapacity: true)
                    var sumBlur = 0, sumAround = 0
                    while let k = stack.popLast() {
                        group.append(k)
                        sumBlur += Int(blur[k]); sumAround += Int(around[k])
                        let x = k % w, y = k / w
                        for ny in max(0, y - 1)...min(h - 1, y + 1) {
                            for nx in max(0, x - 1)...min(w - 1, x + 1) where sharpPx[ny * w + nx] && !seen[ny * w + nx] {
                                seen[ny * w + nx] = true
                                stack.append(ny * w + nx)
                            }
                        }
                    }
                    let mb = sumBlur / group.count, ma = sumAround / group.count
                    if group.count >= minGlyph, mb < ma - max(20, ma / 6) {
                        for k in group where pending[k] { out[k] = 0 }
                    } else if sharp != nil {
                        failed.append(group)
                    }
                }
            }}}}}}
        }
        // A layered scan's text layer is the publisher's own ink: a piece of it too
        // small or faint for the test above (a letter's hairline broken off) stays when
        // kept ink lies within 0.02 inch of it. Specks away from letters still go; so
        // does anything over 0.15 inch across (not a piece of a letter).
        let beside = max(2, Int((0.02 * dpi).rounded())), piece = Int((0.15 * dpi).rounded())
        var rescued: [[Int]] = []
        // Kept ink of a letter: a group the size the test above asks of print (a full
        // stop) or more, holding a stroke (a straight run of ink 0.02 inch long, across
        // or down). A small letter's stem rescues its dot; a cluster of a shadow's
        // speckle, a loose chain of single pixels, rescues nothing; nor do rescued pieces.
        let stroke = max(4, beside), looked = 40 * minGlyph
        var isLetter = [Int: Bool]()
        func letter(_ start: Int) -> Bool {
            if let known = isLetter[start] { return known }
            var seenHere: Set<Int> = [start], todo = [start]
            while let k = todo.popLast(), seenHere.count < looked {
                let x = k % w, y = k / w
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) where out[ny * w + nx] == 0 && !seenHere.contains(ny * w + nx) {
                        seenHere.insert(ny * w + nx); todo.append(ny * w + nx)
                    }
                }
            }
            // A group too big to search to its end is no speck: a letter (or more).
            var found = seenHere.count >= looked
            if !found, seenHere.count >= minGlyph {
                for k in seenHere where !found {
                    let x = k % w
                    if x + stroke <= w, !seenHere.contains(k - 1), (0..<stroke).allSatisfy({ seenHere.contains(k + $0) }) { found = true }
                    if !seenHere.contains(k - w), (0..<stroke).allSatisfy({ seenHere.contains(k + $0 * w) }) { found = true }
                }
            }
            for k in seenHere { isLetter[k] = found }
            return found
        }
        for group in failed {
            var x0 = w, x1 = 0, y0 = h, y1 = 0
            for k in group { x0 = min(x0, k % w); x1 = max(x1, k % w); y0 = min(y0, k / w); y1 = max(y1, k / w) }
            guard x1 - x0 <= piece, y1 - y0 <= piece else { continue }
            var near = false
            search: for y in max(0, y0 - beside)...min(h - 1, y1 + beside) {
                for x in max(0, x0 - beside)...min(w - 1, x1 + beside) where out[y * w + x] == 0 && letter(y * w + x) {
                    near = true; break search
                }
            }
            if near { rescued.append(group) }
        }
        for group in rescued { for k in group where pending[k] { out[k] = 0 } }
        if let sharp { clearHalo(&out, toneInk, sharp, gray, w, h, dpi: dpi, minGlyph: minGlyph) }
        clearRims(&out, cleared, w, h, dpi: dpi)
        clearEdgeLines(&out, toneInk, paper, gray, clean: clean, w, h, dpi: dpi)
        if removeShadows {
            let teeth = ShadowRemoval.teeth(gray, w, h, dpi: dpi, paper: clean + 20, ink: out)
            let combPrint = ShadowRemoval.clearTeeth(&out, teeth, gray, w, h, dpi: dpi, paper: clean + 20)
            ShadowRemoval.clearSides(&out, w, h, dpi: dpi, keep: combPrint)
        }
        if preview { for i in 0..<(w * h) where out[i] == 0 { out[i] = gray[i] } }
        return out
    }

    /// A layered scan's color layer holds a blurred copy of the text beneath the
    /// text layer, which read as ink would embolden every letter. Ink from the color
    /// layer alone, a touching group at a time, goes white when all of it lies
    /// within 0.01 inch of the text layer's ink and some of it borders paper: a
    /// rim. Groups reaching further (the rest of a letter the text layer holds only
    /// part of, a stamp, a rule) stay, and so do holes inside the text layer's letters.
    /// But a light group (mean gray over 160), three quarters of it within 0.02 inch
    /// of the text layer's ink, goes too: the copy smudged beside a letter. Print
    /// the text layer lacks is darker (the rest of a big letter, a rule, a stamp)
    /// or lies apart from it (pencil). Groups smaller than a full stop go too: the
    /// color layer's noise.
    static func clearHalo(_ out: inout [UInt8], _ toneInk: [Bool], _ sharp: [Bool], _ gray: [UInt8],
                          _ w: Int, _ h: Int, dpi: Double, minGlyph: Int) {
        let r = max(1, Int((0.01 * dpi).rounded()))
        let sharpMap = sharp.map { $0 ? UInt8(0) : 255 }
        let near = boxBlur(sharpMap, w, h, radius: r)    // under 255: sharp ink within r
        let beside = boxBlur(sharpMap, w, h, radius: 2 * r)
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = [], group: [Int] = []
        toneInk.withUnsafeBufferPointer { toneInk in sharp.withUnsafeBufferPointer { sharp in
        gray.withUnsafeBufferPointer { gray in near.withUnsafeBufferPointer { near in
        beside.withUnsafeBufferPointer { beside in seen.withUnsafeMutableBufferPointer { seen in
        out.withUnsafeMutableBufferPointer { out in
            for start in 0..<(w * h) where toneInk[start] && !seen[start] {
                seen[start] = true
                stack.removeAll(keepingCapacity: true); stack.append(start)
                group.removeAll(keepingCapacity: true)
                var reaches = false, bordersPaper = false
                var besides = 0, sum = 0
                while let k = stack.popLast() {
                    group.append(k)
                    if near[k] == 255 { reaches = true }
                    if beside[k] < 255 { besides += 1 }
                    sum += Int(gray[k])
                    let x = k % w, y = k / w
                    for ny in max(0, y - 1)...min(h - 1, y + 1) {
                        for nx in max(0, x - 1)...min(w - 1, x + 1) {
                            let n = ny * w + nx
                            if toneInk[n] { if !seen[n] { seen[n] = true; stack.append(n) } }
                            else if !sharp[n] { bordersPaper = true }
                        }
                    }
                }
                let smudge = besides * 4 >= group.count * 3 && sum > 160 * group.count
                if (!reaches && bordersPaper) || smudge || group.count < minGlyph { for k in group { out[k] = 255 } }
            }
        }
        }}}}}}
    }

    /// Lines and smudges along the page's sides that are not print: the edges of
    /// the book's other pages, the paper's own edge at the fold, the rim of the
    /// page's dark edge where its shading crosses the margin. Near a side means
    /// within 0.15 inch of the top or foot, or 0.25 inch of the left or right
    /// (the fold, the outer edge). Goes white:
    /// - a thin line (at most 0.015 inch thick on average, so a slanting one
    ///   counts) along the top or foot and within
    ///   0.15 inch of it, standing alone (little ink within 0.04 inch either end,
    ///   where a hyphen has its word), where it is a layered scan's color layer
    ///   alone or lies on shadow;
    /// - a thin line 0.4 inch or more long down a left or right side, within
    ///   0.05 inch of it whatever it is (the paper's edge at the crop's edge);
    /// - a line of the color layer or on shadow down a left or right side broken
    ///   into thin upright pieces that stand in one column (within 0.02 inch) an
    ///   inch long between them, each alone (as above: a letter has the rest of
    ///   its word beside it);
    /// - a pale smudge of the color layer alone (mean gray over 160) on shadow near
    ///   a left or right side;
    /// and then the specks about what went (see `clearRims`). Print on clean paper
    /// stays (a rule or a dash near the crop's top or foot, the l's and I's down a
    /// tight crop's side), and a folio's 1 alone is too short to be a line.
    static func clearEdgeLines(_ out: inout [UInt8], _ toneInk: [Bool], _ paper: [UInt8], _ gray: [UInt8], clean: Int,
                               _ w: Int, _ h: Int, dpi: Double) {
        let side = Int((0.15 * dpi).rounded()), flank = Int((0.25 * dpi).rounded())
        let rim = Int((0.05 * dpi).rounded()), apart = Int((0.04 * dpi).rounded())
        let thin = max(2, Int((0.015 * dpi).rounded())), long = Int((0.4 * dpi).rounded())
        var seen = [Bool](repeating: false, count: w * h)
        var cleared = [Bool](repeating: false, count: w * h)
        var slivers: [(pixels: [Int], x: Int, h: Int)] = []
        var stack: [Int] = [], group: [Int] = []
        func scan(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) {
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let start = y * w + x
                    guard out[start] == 0, !seen[start] else { continue }
                    seen[start] = true
                    stack = [start]; group = []
                    var minX = w, maxX = 0, minY = h, maxY = 0
                    var tones = 0, onShadow = 0, sum = 0
                    while let k = stack.popLast() {
                        group.append(k)
                        if toneInk[k] { tones += 1 }
                        sum += Int(gray[k])
                        if Int(paper[k]) < clean { onShadow += 1 }
                        let x = k % w, y = k / w
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        for ny in max(0, y - 1)...min(h - 1, y + 1) {
                            for nx in max(0, x - 1)...min(w - 1, x + 1) where out[ny * w + nx] == 0 && !seen[ny * w + nx] {
                                seen[ny * w + nx] = true
                                stack.append(ny * w + nx)
                            }
                        }
                    }
                    let bw = maxX - minX + 1, bh = maxY - minY + 1
                    let atFlank = minX < flank || maxX >= w - flank
                    let colorOrShadow = tones == group.count || onShadow * 2 > group.count
                    // Standing alone: a letter or a hyphen has neighbours on its line.
                    var beside = 0
                    for y in minY...maxY {
                        for x in max(0, minX - apart)..<minX where out[y * w + x] == 0 { beside += 1 }
                        for x in (maxX + 1)..<min(w, maxX + 1 + apart) where out[y * w + x] == 0 { beside += 1 }
                    }
                    let alone = beside * 2 <= group.count
                    // Thin on average, so a line the straightening left slanting counts.
                    let upright = bh > bw && group.count <= thin * bh && bw <= 4 * thin
                    let flat = bw > bh && group.count <= thin * bw && bh <= 4 * thin
                    let along = flat && (minY < side || maxY >= h - side) && alone
                    let atRim = minX < rim || maxX >= w - rim
                    let rail = upright && bh >= long && (atRim || (atFlank && colorOrShadow))
                    let smudge = tones == group.count && onShadow * 2 > group.count
                        && sum > 160 * group.count && atFlank
                    if rail || smudge || (along && colorOrShadow) {
                        for k in group { out[k] = 255; cleared[k] = true }
                    } else if upright, bh >= 2 * bw, atFlank, colorOrShadow, alone {
                        slivers.append((group, (minX + maxX) / 2, bh))
                    }
                }
            }
        }
        // Only what starts near a side can be one of these; look there alone.
        scan(0, w, 0, min(h, side)); scan(0, w, max(0, h - side), h)
        scan(0, min(w, flank), 0, h); scan(max(0, w - flank), w, 0, h)
        let bin = max(1, Int((0.02 * dpi).rounded()))
        var height = [Int: Int]()
        for s in slivers { height[s.x / bin, default: 0] += s.h }
        for s in slivers {
            let b = s.x / bin
            let total = (height[b - 1] ?? 0) + (height[b] ?? 0) + (height[b + 1] ?? 0)
            if total >= Int(dpi.rounded()) { for k in s.pixels { out[k] = 255; cleared[k] = true } }
        }
        clearRims(&out, cleared, w, h, dpi: dpi)
    }

    /// Paper at least this light is clean: no shadow on it to speak of. Judged
    /// against the page's own paper, its lightest twentieth (a shadow or a dark
    /// board can cover most of a page), so tinted paper counts as clean.
    static func cleanLevel(_ paper: [UInt8]) -> Int {
        // Counted in four tallies, a pixel to each in turn, then added: paper is mostly
        // one gray, and four tallies don't each wait on the last pixel's count.
        var counts = [Int](repeating: 0, count: 256)
        var tallies = [Int](repeating: 0, count: 4 * 256)
        tallies.withUnsafeMutableBufferPointer { c in
            paper.withUnsafeBufferPointer { p in
                let n = p.count, whole = n & ~3
                var i = 0
                while i < whole {
                    c[Int(p[i])] += 1; c[256 + Int(p[i + 1])] += 1
                    c[512 + Int(p[i + 2])] += 1; c[768 + Int(p[i + 3])] += 1
                    i += 4
                }
                while i < n { c[Int(p[i])] += 1; i += 1 }
            }
        }
        for v in 0..<256 { counts[v] = tallies[v] + tallies[256 + v] + tallies[512 + v] + tallies[768 + v] }
        var seen = 0, level = 255
        for v in 0..<256 {
            seen += counts[v]
            if seen * 20 >= paper.count * 19 { level = v; break }
        }
        return level - 20
    }

    /// The paper's gray at each pixel (see the type's notes).
    static func background(_ gray: [UInt8], _ w: Int, _ h: Int, dpi: Double) -> [UInt8] {
        let f = max(1, Int((dpi / 50).rounded()))
        let lw = (w + f - 1) / f, lh = (h + f - 1) / f
        var small = [UInt8](repeating: 255, count: lw * lh)
        // Each cell's mean, its rows summed a row of cells at a time.
        var sums = [Int](repeating: 0, count: lw)
        gray.withUnsafeBufferPointer { g in
            sums.withUnsafeMutableBufferPointer { sums in
                for cy in 0..<lh {
                    for cx in 0..<lw { sums[cx] = 0 }
                    let ys = cy * f, ye = min(h, cy * f + f)
                    for y in ys..<ye {
                        let row = y * w
                        for cx in 0..<lw {
                            var sum = 0
                            for x in (cx * f)..<min(w, cx * f + f) { sum += Int(g[row + x]) }
                            sums[cx] += sum
                        }
                    }
                    for cx in 0..<lw {
                        let n = (ye - ys) * (min(w, cx * f + f) - cx * f)
                        small[cy * lw + cx] = UInt8(sums[cx] / max(1, n))
                    }
                }
            }
        }
        let cellDPI = dpi / Double(f)
        let r = max(1, Int((0.12 * cellDPI).rounded()))
        // Closed with the darkest of the outer 0.1 inch carried on outward past
        // each side, so shading that runs off the page (the fold's shadow at a
        // page's side, even with a sliver of white beyond it where straightening
        // turned the page) stays paper rather than being filled in from the
        // lighter side, as a narrow dark strip would be.
        let k = max(1, Int((0.1 * cellDPI).rounded()))
        let pw = lw + 2 * r, ph = lh + 2 * r
        var padded = [UInt8](repeating: 255, count: pw * ph)
        for y in 0..<lh {
            let row = y * lw
            let left = small[row..<(row + min(k, lw))].min() ?? 255
            let right = small[(row + max(0, lw - k))..<(row + lw)].min() ?? 255
            for x in 0..<pw {
                let sx = x - r
                padded[(y + r) * pw + x] = sx < 0 ? left : sx >= lw ? right : small[row + sx]
            }
        }
        for x in 0..<pw {
            var top: UInt8 = 255, foot: UInt8 = 255
            for y in 0..<min(k, lh) { top = min(top, padded[(y + r) * pw + x]) }
            for y in max(0, lh - k)..<lh { foot = min(foot, padded[(y + r) * pw + x]) }
            for y in 0..<r { padded[y * pw + x] = top; padded[(lh + r + y) * pw + x] = foot }
        }
        let closedPadded = LayeredScan.minFilter(LayeredScan.maxFilter(padded, pw, ph, radius: r), pw, ph, radius: r)
        var closed = small
        for y in 0..<lh { for x in 0..<lw { closed[y * lw + x] = closedPadded[(y + r) * pw + x + r] } }
        // The darker of the cells around: enlarging blurs a step (a page's edge on
        // the scanner bed) and the step's dark side mustn't count as ink.
        let smooth = LayeredScan.minFilter(closed, lw, lh, radius: 1)
        // Back to full size, bilinear, cell centers at (c + 0.5) * f.
        // The column weights are the same on every row, and the blend across a row
        // the same for every row between the same two rows of cells: worked out once.
        var cx0 = [Int](repeating: 0, count: w), cx1 = cx0
        var wx = [Double](repeating: 0, count: w), wx1 = wx
        for x in 0..<w {
            let fx = max(0, min(Double(lw - 1), (Double(x) + 0.5) / Double(f) - 0.5))
            let x0 = Int(fx)
            cx0[x] = x0; cx1[x] = min(lw - 1, x0 + 1); wx[x] = fx - Double(x0); wx1[x] = 1 - wx[x]
        }
        var out = [UInt8](repeating: 255, count: w * h)
        var rowA = [Double](repeating: 0, count: w), rowB = rowA
        var lastY0 = -1, lastY1 = -1
        for y in 0..<h {
            let fy = max(0, min(Double(lh - 1), (Double(y) + 0.5) / Double(f) - 0.5))
            let y0 = Int(fy), y1 = min(lh - 1, y0 + 1), ty = fy - Double(y0)
            if y0 != lastY0 || y1 != lastY1 {
                for x in 0..<w {
                    rowA[x] = Double(smooth[y0 * lw + cx0[x]]) * wx1[x] + Double(smooth[y0 * lw + cx1[x]]) * wx[x]
                    rowB[x] = Double(smooth[y1 * lw + cx0[x]]) * wx1[x] + Double(smooth[y1 * lw + cx1[x]]) * wx[x]
                }
                lastY0 = y0; lastY1 = y1
            }
            let ty1 = 1 - ty
            out.withUnsafeMutableBufferPointer { o in
                let row = y * w
                for x in 0..<w { o[row + x] = UInt8((rowA[x] * ty1 + rowB[x] * ty).rounded()) }
            }
        }
        return out
    }

    /// Each pixel's mean over a square of `radius` (cut short at the page's
    /// edges), by running sums: along each row, then down the columns a row at a
    /// time, so memory is read in order. Each mean is a whole-number quotient,
    /// worked out by `Divider` where its sizes allow.
    static func boxBlur(_ p: [UInt8], _ w: Int, _ h: Int, radius r: Int) -> [UInt8] {
        guard r > 0, w > 0, h > 0, p.count == w * h else { return p }
        // Sums of up to 2r + 1 means, each at most 255 × 16: `Divider` holds for them
        // up to a radius of 512.
        guard r <= 512 else { return boxBlurDividing(p, w, h, radius: r) }
        var rows = [UInt32](repeating: 0, count: w * h)     // row means, 4 bits of fraction
        let span = Divider(2 * r + 1)
        p.withUnsafeBufferPointer { src in
            rows.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    var sum = 0
                    let base = y * w
                    for x in 0..<min(w, r + 1) { sum += Int(src[base + x]) }
                    for x in 0..<w {
                        if x >= r && x + r < w {
                            dst[base + x] = span.divide(UInt32(sum * 16))
                        } else {
                            dst[base + x] = UInt32(sum * 16 / (min(w - 1, x + r) - max(0, x - r) + 1))
                        }
                        if x + r + 1 < w { sum += Int(src[base + x + r + 1]) }
                        if x - r >= 0 { sum -= Int(src[base + x - r]) }
                    }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        var column = [UInt32](repeating: 0, count: w)
        rows.withUnsafeBufferPointer { rows in
            out.withUnsafeMutableBufferPointer { out in
                column.withUnsafeMutableBufferPointer { col in
                    for y in 0..<min(h, r + 1) { for x in 0..<w { col[x] &+= rows[y * w + x] } }
                    for y in 0..<h {
                        let n = min(h - 1, y + r) - max(0, y - r) + 1
                        if n == 1 {
                            for x in 0..<w { out[y * w + x] = UInt8(min(255, (col[x] + 8) / 16)) }
                        } else {
                            let d = Divider(n)
                            for x in 0..<w { out[y * w + x] = UInt8(min(255, (d.divide(col[x]) + 8) / 16)) }
                        }
                        if y + r + 1 < h { for x in 0..<w { col[x] &+= rows[(y + r + 1) * w + x] } }
                        if y - r >= 0 { for x in 0..<w { col[x] &-= rows[(y - r) * w + x] } }
                    }
                }
            }
        }
        return out
    }

    /// Whole-number division by a fixed `n` of 2 or more, by a multiply and a shift:
    /// with m = 2^32 / n rounded up, m × n = 2^32 + e (e < n), so a × m / 2^32 is
    /// a / n plus under a / 2^32, which is under 1/n while a × n < 2^32: never enough
    /// to reach the next whole number, so dropping the fraction gives a / n exactly.
    struct Divider {
        let m: UInt64
        init(_ n: Int) { m = ((1 << 32) + UInt64(n) - 1) / UInt64(n) }
        @inline(__always) func divide(_ a: UInt32) -> UInt32 { UInt32(truncatingIfNeeded: (UInt64(a) &* m) >> 32) }
    }

    /// `boxBlur` by plain division, for radii too big for `Divider`.
    static func boxBlurDividing(_ p: [UInt8], _ w: Int, _ h: Int, radius r: Int) -> [UInt8] {
        var rows = [Int](repeating: 0, count: w * h)     // row means, 4 bits of fraction
        p.withUnsafeBufferPointer { src in
            rows.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    var sum = 0
                    let base = y * w
                    for x in 0..<min(w, r + 1) { sum += Int(src[base + x]) }
                    for x in 0..<w {
                        dst[base + x] = sum * 16 / (min(w - 1, x + r) - max(0, x - r) + 1)
                        if x + r + 1 < w { sum += Int(src[base + x + r + 1]) }
                        if x - r >= 0 { sum -= Int(src[base + x - r]) }
                    }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        var column = [Int](repeating: 0, count: w)
        rows.withUnsafeBufferPointer { rows in
            out.withUnsafeMutableBufferPointer { out in
                column.withUnsafeMutableBufferPointer { col in
                    for y in 0..<min(h, r + 1) { for x in 0..<w { col[x] += rows[y * w + x] } }
                    for y in 0..<h {
                        let n = min(h - 1, y + r) - max(0, y - r) + 1
                        for x in 0..<w { out[y * w + x] = UInt8(min(255, (col[x] / n + 8) / 16)) }
                        if y + r + 1 < h { for x in 0..<w { col[x] += rows[(y + r + 1) * w + x] } }
                        if y - r >= 0 { for x in 0..<w { col[x] -= rows[(y - r) * w + x] } }
                    }
                }
            }
        }
        return out
    }

    /// Solid dark strips and patches along the page's sides, to white out. Measured on
    /// cells of 0.01 inch: a cell is dark when at least 30% of it is ink. In a group
    /// of touching dark cells that runs off the crop (a figure printed near a side has
    /// paper between it and the edge) and comes within 0.1 inch of a side, the solid cells
    /// (dark for 0.03 inch all round, as print's strokes never are) go white. If
    /// the group runs at least an inch along that side and is somewhere 0.04 inch
    /// thick across it (more than a printed rule), it is a band, and its cells in a
    /// straight run of 0.4 inch or more along that side (no letter has one) go too.
    /// The pixels to white out. Print touching a band keeps the rest of its pixels.
    static func bands(_ ink: [Bool], _ w: Int, _ h: Int, dpi: Double) -> [Bool] {
        let c = max(1, Int((dpi / 100).rounded()))
        let cw = (w + c - 1) / c, ch = (h + c - 1) / c
        let cellDPI = dpi / Double(c)
        var dark = [Bool](repeating: false, count: cw * ch)
        for cy in 0..<ch {
            for cx in 0..<cw {
                var inked = 0, n = 0
                for y in (cy * c)..<min(h, cy * c + c) {
                    for x in (cx * c)..<min(w, cx * c + c) { inked += ink[y * w + x] ? 1 : 0; n += 1 }
                }
                dark[cy * cw + cx] = inked * 10 >= n * 3
            }
        }
        let near = max(1, Int((0.1 * cellDPI).rounded()))
        let longRun = max(2, Int((0.4 * cellDPI).rounded()))
        let inch = Int(cellDPI.rounded())
        let thick = max(2, Int((0.04 * cellDPI).rounded()))
        // Straight runs of dark cells, down each column and along each row.
        var vRun = [Int](repeating: 0, count: cw * ch), hRun = [Int](repeating: 0, count: cw * ch)
        for x in 0..<cw {
            var y = 0
            while y < ch {
                guard dark[y * cw + x] else { y += 1; continue }
                var e = y
                while e < ch, dark[e * cw + x] { e += 1 }
                for k in y..<e { vRun[k * cw + x] = e - y }
                y = e
            }
        }
        for y in 0..<ch {
            var x = 0
            while x < cw {
                guard dark[y * cw + x] else { x += 1; continue }
                var e = x
                while e < cw, dark[y * cw + e] { e += 1 }
                for k in x..<e { hRun[y * cw + k] = e - x }
                x = e
            }
        }
        // Solid: within 0.03 inch of a cell that has every cell within 0.03 inch
        // dark, and itself with 80% of the cells within 0.03 inch dark, which
        // print's strokes, a few hundredths of an inch thick with paper between,
        // never are; print touching a solid patch keeps its own cells.
        let reach = max(1, Int((0.03 * cellDPI).rounded()))
        let darkShare = boxBlur(dark.map { $0 ? 255 : 0 }, cw, ch, radius: reach)
        let core = boxBlur(darkShare.map { $0 == 255 ? 255 : 0 }, cw, ch, radius: reach)
        func solid(_ k: Int) -> Bool { core[k] > 0 && darkShare[k] >= 204 }
        var seen = [Bool](repeating: false, count: cw * ch)
        var clear = [Bool](repeating: false, count: cw * ch)
        var stack: [Int] = [], group: [Int] = []
        for start in 0..<(cw * ch) where dark[start] && !seen[start] {
            seen[start] = true
            stack = [start]; group = []
            var minX = cw, maxX = 0, minY = ch, maxY = 0
            while let k = stack.popLast() {
                group.append(k)
                let x = k % cw, y = k / cw
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < cw, ny < ch else { continue }
                    let n = ny * cw + nx
                    if dark[n], !seen[n] { seen[n] = true; stack.append(n) }
                }
            }
            let atSide = minX < near || maxX >= cw - near, atEdge = minY < near || maxY >= ch - near
            guard atSide || atEdge else { continue }
            // A band runs off the crop; a figure printed near the side, however long,
            // has paper between it and the edge.
            guard minX == 0 || maxX == cw - 1 || minY == 0 || maxY == ch - 1 else { continue }
            let side = atSide && maxY - minY + 1 >= inch && group.contains { hRun[$0] >= thick }
            let edge = atEdge && maxX - minX + 1 >= inch && group.contains { vRun[$0] >= thick }
            for k in group where solid(k) || (side && vRun[k] >= longRun) || (edge && hRun[k] >= longRun) {
                clear[k] = true
            }
        }
        var cleared = [Bool](repeating: false, count: w * h)
        for cy in 0..<ch {
            for cx in 0..<cw where clear[cy * cw + cx] {
                for y in (cy * c)..<min(h, cy * c + c) {
                    for x in (cx * c)..<min(w, cx * c + c) { cleared[y * w + x] = true }
                }
            }
        }
        return cleared
    }

    /// What a band leaves about it (see `bands`).
    static func clearRims(_ out: inout [UInt8], _ cleared: [Bool], _ w: Int, _ h: Int, dpi: Double) {
        guard let box = markBox(cleared, w, h) else { return }
        let c = max(1, Int((dpi / 100).rounded()))
        var stack: [Int] = []
        // The band's ragged rim: ink left touching it that lies mostly (60%) within
        // two cells of it, or in a strip at most a cell and a pixel thick but 0.4
        // inch long; and specks within 0.05 inch of it no more than 0.02 inch
        // across. Print touching the band reaches further, and is bigger than a speck.
        let reach = Int((0.05 * dpi).rounded())
        let zone = blurOfMarks(cleared, w, h, radius: reach, box: box)
        let hugging = blurOfMarks(cleared, w, h, radius: 2 * c, box: box)
        var visited = [Bool](repeating: false, count: w * h)
        let thin = c + 1, long = Int((0.4 * dpi).rounded()), speck = Int((0.02 * dpi).rounded())
        var pixels: [Int] = []
        // Pixels touching what went.
        var touching = [Bool](repeating: false, count: w * h)
        for y in box.y0...box.y1 {
            for x in box.x0...box.x1 where cleared[y * w + x] {
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) { touching[ny * w + nx] = true }
                }
            }
        }
        // Only a group with a pixel in the zone or touching what went can go, so the
        // search starts from those pixels alone (it still takes in each such group
        // whole); they all lie within the box of what went grown by the zone's reach.
        let g = max(1, reach)
        cleared.withUnsafeBufferPointer { cleared in zone.withUnsafeBufferPointer { zone in
        hugging.withUnsafeBufferPointer { hugging in touching.withUnsafeBufferPointer { touching in
        visited.withUnsafeMutableBufferPointer { visited in out.withUnsafeMutableBufferPointer { out in
            for sy in max(0, box.y0 - g)...min(h - 1, box.y1 + g) {
                for sx in max(0, box.x0 - g)...min(w - 1, box.x1 + g) {
                    let start = sy * w + sx
                    guard out[start] == 0, !visited[start], zone[start] < 255 || touching[start] else { continue }
                    visited[start] = true
                    stack.removeAll(keepingCapacity: true); stack.append(start)
                    pixels.removeAll(keepingCapacity: true)
                    var touches = false, inZone = false, hugs = 0
                    var minX = w, maxX = 0, minY = h, maxY = 0
                    while let k = stack.popLast() {
                        pixels.append(k)
                        if zone[k] < 255 { inZone = true }
                        if hugging[k] < 255 { hugs += 1 }
                        let x = k % w, y = k / w
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        for ny in max(0, y - 1)...min(h - 1, y + 1) {
                            for nx in max(0, x - 1)...min(w - 1, x + 1) {
                                let n = ny * w + nx
                                if cleared[n] { touches = true }
                                if out[n] == 0, !visited[n] { visited[n] = true; stack.append(n) }
                            }
                        }
                    }
                    let bw = maxX - minX + 1, bh = maxY - minY + 1
                    let rim = touches && ((bw <= thin && bh >= long) || (bh <= thin && bw >= long)
                                          || hugs * 5 >= pixels.count * 3)
                    guard rim || (inZone && bw <= speck && bh <= speck) else { continue }
                    for k in pixels { out[k] = 255 }
                }
            }
        }}}}}}
    }

    /// The box holding every mark, nil if there is none.
    static func markBox(_ marks: [Bool], _ w: Int, _ h: Int) -> (x0: Int, x1: Int, y0: Int, y1: Int)? {
        var x0 = w, x1 = -1, y0 = h, y1 = -1
        marks.withUnsafeBufferPointer { m in
            for y in 0..<h {
                let row = y * w
                var first = -1, last = -1
                for x in 0..<w where m[row + x] { if first < 0 { first = x }; last = x }
                if first >= 0 { x0 = min(x0, first); x1 = max(x1, last); y0 = min(y0, y); y1 = max(y1, y) }
            }
        }
        return x1 >= 0 ? (x0, x1, y0, y1) : nil
    }

    /// `boxBlur` of a map that is 0 where `marks` holds and 255 elsewhere, worked out
    /// only about the marks: a window holding no mark has mean 255 exactly, so the
    /// blur is 255 wherever the marks' box grown by `radius` doesn't reach. Within it
    /// the blur is made on the box grown by twice the radius (cut short at the page's
    /// edges), where every window reaching that far is cut short just as on the page.
    static func blurOfMarks(_ marks: [Bool], _ w: Int, _ h: Int, radius r: Int,
                            box: (x0: Int, x1: Int, y0: Int, y1: Int)) -> [UInt8] {
        let (x0, x1, y0, y1) = box
        var out = [UInt8](repeating: 255, count: w * h)
        guard r > 0 else {
            for i in 0..<(w * h) where marks[i] { out[i] = 0 }
            return out
        }
        // The box grown by twice the radius, and the part of it the blur can reach.
        let bx0 = max(0, x0 - 2 * r), bx1 = min(w - 1, x1 + 2 * r)
        let by0 = max(0, y0 - 2 * r), by1 = min(h - 1, y1 + 2 * r)
        let bw = bx1 - bx0 + 1, bh = by1 - by0 + 1
        var sub = [UInt8](repeating: 255, count: bw * bh)
        marks.withUnsafeBufferPointer { m in
            sub.withUnsafeMutableBufferPointer { sub in
                for y in 0..<bh {
                    let row = (by0 + y) * w + bx0
                    for x in 0..<bw where m[row + x] { sub[y * bw + x] = 0 }
                }
            }
        }
        let blurred = boxBlur(sub, bw, bh, radius: r)
        let rx0 = max(0, x0 - r), rx1 = min(w - 1, x1 + r)
        let ry0 = max(0, y0 - r), ry1 = min(h - 1, y1 + r)
        blurred.withUnsafeBufferPointer { b in
            out.withUnsafeMutableBufferPointer { o in
                for y in ry0...ry1 {
                    let from = (y - by0) * bw - bx0, to = y * w
                    for x in rx0...rx1 { o[to + x] = b[from + x] }
                }
            }
        }
        return out
    }

    /// An output page in black and white, from its gray or color image at `dpi`,
    /// or nil when it holds a picture (see `holdsPicture`) and should stay as it is.
    /// `preview` and `removeShadows` as for `ink`.
    static func page(_ image: CGImage, dpi: Double, preview: Bool = false, removeShadows: Bool = false) -> CGImage? {
        page(prepare(image, dpi: dpi), dpi: dpi, preview: preview, removeShadows: removeShadows)
    }

    /// An output page's gray pixels and paper, and whether it holds a picture: worked
    /// out once, so the picture test can come before any other work (see `page`).
    struct Prepared {
        let gray: [UInt8], paper: [UInt8]
        let width: Int, height: Int
        let picture: Bool
    }

    static func prepare(_ image: CGImage, dpi: Double) -> Prepared {
        let w = image.width, h = image.height
        let gray = grayPixels(image)
        let paper = background(gray, w, h, dpi: dpi)
        return Prepared(gray: gray, paper: paper, width: w, height: h, picture: holdsPicture(paper, gray, w, h, dpi: dpi))
    }

    /// `page` from a page already prepared at `dpi`.
    static func page(_ p: Prepared, dpi: Double, preview: Bool = false, removeShadows: Bool = false) -> CGImage? {
        guard !p.picture else { return nil }
        let w = p.width, h = p.height
        return Self.image(ink(gray: p.gray, sharp: nil, tone: holdsTones(p.gray, width: w, height: h), width: w, height: h,
                              dpi: dpi, preview: preview, removeShadows: removeShadows, paper: p.paper),
                          width: w, height: h)
    }

    /// A picture on the paper map: a group of touching places at least 20% darker
    /// than the page's usual paper, at least 0.4 inch each way, not a band or shadow
    /// (near a side, with the scan `gray` dark at the crop's edge beside it: it runs
    /// off the crop), and over 0.15 square inch in all. Print is gone from the paper
    /// map, but a photo, plate or shaded figure stays.
    static func holdsPicture(_ paper: [UInt8], _ gray: [UInt8], _ w: Int, _ h: Int, dpi: Double) -> Bool {
        pictureCells(paper, gray, w, h, dpi: dpi).area > LayeredScan.pictureLimit
    }

    /// Where a picture is (see `holdsPicture`), pixel by pixel, grown by 0.1 inch.
    static func pictureMap(_ paper: [UInt8], _ gray: [UInt8], _ w: Int, _ h: Int, dpi: Double) -> [Bool] {
        let cells = pictureCells(paper, gray, w, h, dpi: dpi)
        var out = [Bool](repeating: false, count: w * h)
        guard cells.mark.contains(true) else { return out }
        let grow = max(1, Int((0.1 * dpi / Double(cells.step)).rounded()))
        let grown = LayeredScan.minFilter(cells.mark.map { $0 ? 0 : 255 }, cells.width, cells.mark.count / cells.width,
                                          radius: grow)
        for y in 0..<h {
            for x in 0..<w where grown[(y / cells.step) * cells.width + x / cells.step] == 0 { out[y * w + x] = true }
        }
        return out
    }

    /// The picture groups of `holdsPicture` on cells of `step` pixels, `width` cells
    /// a row, and their area in square inches.
    static func pictureCells(_ paper: [UInt8], _ gray: [UInt8], _ w: Int, _ h: Int, dpi: Double)
        -> (mark: [Bool], width: Int, step: Int, area: Double) {
        let step = max(1, Int((dpi / 50).rounded()))
        let sw = (w + step - 1) / step, sh = (h + step - 1) / step
        var small = [UInt8](repeating: 255, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw { small[y * sw + x] = paper[(y * step) * w + x * step] } }
        let usual = cleanLevel(small) + 20
        var mark = small.map { Int($0) * 5 <= usual * 4 }
        var picture = [Bool](repeating: false, count: sw * sh)
        var group: [Int] = []
        let cellDPI = dpi / Double(step)
        let edge = max(1, Int((0.1 * cellDPI).rounded())), span = Int((0.4 * cellDPI).rounded())
        var area = 0
        var stack: [Int] = []
        for start in mark.indices where mark[start] {
            mark[start] = false
            stack = [start]; group = []
            var size = 0, minX = sw, maxX = 0, minY = sh, maxY = 0
            while let k = stack.popLast() {
                size += 1
                group.append(k)
                let x = k % sw, y = k / sw
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < sw, ny < sh, mark[ny * sw + nx] else { continue }
                    mark[ny * sw + nx] = false
                    stack.append(ny * sw + nx)
                }
            }
            // A band or shadow runs off the crop: on 30% or more of its rows (or columns)
            // the scan is as dark without a break from the crop's edge inward for 0.1
            // inch. A picture near a side has paper between it and the edge, even with a
            // thin dark strip (a page's edge) along the edge itself.
            let inward = max(1, Int((0.1 * dpi).rounded()))
            func dark(_ x: Int, _ y: Int) -> Bool { Int(gray[y * w + x]) * 5 <= usual * 4 }
            func runsIn(_ lines: Range<Int>, _ at: (Int, Int) -> Bool) -> Bool {
                guard !lines.isEmpty else { return false }
                var joined = 0
                for l in lines where (0..<inward).allSatisfy({ at(l, $0) }) { joined += 1 }
                return joined * 10 >= lines.count * 3
            }
            let x0 = minX * step, x1 = min(w, (maxX + 1) * step), y0 = minY * step, y1 = min(h, (maxY + 1) * step)
            let runsOff = (minX < edge && inward < w && runsIn(y0..<y1) { y, d in dark(d, y) })
                || (maxX >= sw - edge && inward < w && runsIn(y0..<y1) { y, d in dark(w - 1 - d, y) })
                || (minY < edge && inward < h && runsIn(x0..<x1) { x, d in dark(x, d) })
                || (maxY >= sh - edge && inward < h && runsIn(x0..<x1) { x, d in dark(x, h - 1 - d) })
            if !runsOff, maxX - minX >= span, maxY - minY >= span {
                area += size
                for k in group { picture[k] = true }
            }
        }
        return (picture, sw, step, Double(area) / (cellDPI * cellDPI))
    }

    /// An 8-bit gray image of `pixels` (top-left origin rows).
    static func image(_ pixels: [UInt8], width w: Int, height h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 8-bit gray pixels of an image (luma), top-left origin.
    static func grayPixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 255, count: w * h)
        buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    /// Whether a gray page holds tones worth reading (a grayscale scan) rather than
    /// black and white with a little gray at the edges of strokes: a twentieth of it
    /// mid gray (between 40 and 215), or a thousandth of it mid gray more than 2 px from
    /// any near-black pixel (40 or under): pale or gray print, or gray shading, which
    /// the gray edges of black strokes, always beside their near-black cores, are not.
    static func holdsTones(_ gray: [UInt8], width w: Int, height h: Int) -> Bool {
        guard w > 0, h > 0, gray.count == w * h else { return false }
        var mid = 0
        for v in gray where v > 40 && v < 215 { mid += 1 }
        if mid * 20 > gray.count { return true }
        guard mid * 1000 > gray.count else { return false }
        let nearDark = LayeredScan.minFilter(gray.map { $0 <= 40 ? 0 : 255 }, w, h, radius: 2)
        var alone = 0
        for i in 0..<(w * h) where gray[i] > 40 && gray[i] < 215 && nearDark[i] != 0 { alone += 1 }
        return alone * 1000 > gray.count
    }
}
