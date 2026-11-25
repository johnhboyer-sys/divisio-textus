import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFCropper

/// Hill-climb score for Flatten pages. Runs only when HILLCLIMB_DIR is set; writes
/// results/<label>/flatten.json (and flatten-pages.json, one record per real page side).
/// HILLCLIMB_FLATTEN_ONLY=survey|synthetic|real|speed runs one part (survey runs only when asked).
///
/// The baselines are traced by `HCBaselines`, which shares no code with `Flatten`.
///
/// * **Curl** (real): for each long text line of an output page, the RMS distance of its
///   traced baseline from a straight line, in points; per page the mean over its lines.
///   Before is the export without the option, after with it.
/// * **Synthetic**: leaves from `HCSynth` drawn at 330 DPI with no tilt or fold marks, warped
///   with a known curl into the gutter (a vertical shift growing as the square of the
///   distance into the gutter band, tilted about the page's middle, plus a squash of the
///   band), then flattened. Scored against the unwarped leaf: baseline curl, and every
///   glyph's position (nearest glyph of like size), in points. Some leaves are not warped:
///   they must come back unchanged.
/// * **Print safety**: glyphs (`HCBaselines.glyphs`) before and after; a glyph is lost when
///   no glyph after has its size within 25% (or 3 px) and its centre within the page's
///   largest shift plus 3 px. Also letter width by the gutter over the middle's (1 is even).
/// * **Speed**: seconds per page side for the analysis and remap alone, and an export of
///   Freudenthal-1999 pages 1-20 with the option on and off.
@Suite("HillClimb flatten", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct HillClimbFlattenTests {
    static var only: String? { HillClimb.env["HILLCLIMB_FLATTEN_ONLY"] }

    /// The DPI the exporter renders a page at.
    static func exportDPI(_ page: PDFPage, _ settings: PDFExporter.Settings) -> Double {
        PDFExporter.renderDPI(of: page, settings: settings)
    }

    struct Side {
        var id: String
        var gutterOnRight: Bool?
        var image: CGImage          // as exported without the option
        var flat: CGImage?          // with it (nil: skipped)
        var dpi: Double
        var seconds: Double
    }

    /// Output pages of every `step`-th source page of a book, as the exporter cuts them in
    /// color, without and with flattening. `pages` limits to those source page numbers (1-based).
    static func sides(of url: URL, step: Int, pages wanted: Set<Int>? = nil, flatten: Bool, includeLayered: Bool = true,
                      _ body: (Side) -> Void) async -> (layered: Int, pages: Int) {
        let m = HillClimb.makeModel()
        await HillClimb.load(url, into: m)
        guard let doc = AppModel.reopen(url, password: nil) else { return (0, 0) }
        let name = HillClimb.shortName(url)
        let settings = PDFExporter.Settings(direction: m.direction, ocr: false, enhanceMode: .color)
        var on = settings
        on.flattenPages = true
        var layered = 0, seen = 0
        for (k, page) in m.pages.enumerated() where k % step == 0 {
            if let wanted, !wanted.contains(page.sourceIndex + 1) { continue }
            guard let pdfPage = doc.page(at: page.sourceIndex) else { continue }
            // Layered scans are flattened by the export on their text layer (scored in
            // HillClimbFlattenLayered); this score measures the method on them as a plain render.
            if LayeredScan.layers(of: pdfPage) != nil { layered += 1; if !includeLayered { continue } }
            seen += 1
            autoreleasepool {
                let dpi = exportDPI(pdfPage, settings)
                guard let rendered = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi),
                      let out = PDFExporter.outputImages(of: page, rendered: rendered, settings: settings) else { return }
                var flat: [CGImage]? = nil
                var seconds = 0.0
                if flatten {
                    let t0 = HillClimb.now()
                    flat = PDFExporter.outputImages(of: page, rendered: rendered, settings: on)
                    seconds = HillClimb.now() - t0
                }
                let crops = page.outputCrops(direction: settings.direction)
                for (i, image) in out.enumerated() {
                    var gutterOnRight: Bool? = nil
                    var tag = ""
                    if page.isSpread {
                        let isLeft = crops[i].minX + crops[i].width / 2 < page.splitX
                        gutterOnRight = isLeft
                        tag = isLeft ? "L" : "R"
                    }
                    var f = flat?[i]
                    if let a = f, HillClimb.rgbx(a) == HillClimb.rgbx(image) { f = nil }
                    body(Side(id: "\(name)-\(page.sourceIndex + 1)\(tag)", gutterOnRight: gutterOnRight,
                              image: image, flat: f, dpi: dpi, seconds: seconds / Double(out.count)))
                }
            }
        }
        return (layered, seen)
    }

    struct Curl {
        var lines = 0
        var meanPt = 0.0, maxPt = 0.0
        /// The 75th percentile over long lines of the gutter end's droop (both ends, the larger,
        /// when the gutter side is not known), pt.
        var droopPt = 0.0
        var widthRatio: Double?
        var glyphs: [HCGlyph] = []
    }

    static func curl(_ image: CGImage, dpi: Double, gutterOnRight: Bool?) -> Curl {
        let w = image.width, h = image.height
        let g = HillClimb.gray(image)
        let gs = HCBaselines.glyphs(g, width: w, height: h)
        let ls = HCBaselines.longLines(HCBaselines.lines(gs))
        var c = Curl()
        c.glyphs = gs
        c.lines = ls.count
        let pts = ls.map { $0.curlPx * 72 / dpi }
        c.meanPt = HillClimb.mean(pts)
        c.maxPt = pts.max() ?? 0
        func p75(_ right: Bool) -> Double {
            let d = ls.compactMap { $0.droopPx(endOnRight: right) }.sorted()
            return d.isEmpty ? 0 : d[(3 * d.count) / 4] * 72 / dpi
        }
        c.droopPt = gutterOnRight.map(p75) ?? max(p75(true), p75(false))
        if let gr = gutterOnRight { c.widthRatio = HCBaselines.gutterWidthRatio(ls, gutterOnRight: gr) }
        return c
    }

    /// Print safety of one flattened page. `lost`: glyphs of `before` whose ink is gone: where
    /// the glyph lands (`model`, Flatten's own map), its box grown by 2 px holds under half as
    /// many ink pixels after as it held before. `merged`: pairs of glyphs side by side with a
    /// gap of 2 px or more before that land in one glyph after. Ink is the evened page under
    /// the Otsu threshold of the page before.
    static func printCheck(before: CGImage, after: CGImage, glyphsBefore gb: [HCGlyph], glyphsAfter ga: [HCGlyph],
                           model: Flatten.Model?) -> (lost: [HCGlyph], merged: [HCGlyph]) {
        let w = before.width, h = before.height
        guard after.width == w, after.height == h else { return (gb, []) }
        // One threshold for both, the page's before: resampling softens edges, which moves
        // Otsu's cut on the page after.
        let eb = HCBaselines.evened(HillClimb.gray(before), width: w, height: h)
        let ea = HCBaselines.evened(HillClimb.gray(after), width: w, height: h)
        let t = HCGlyphDetector.otsu(eb)
        let ib = eb.map { Int($0) <= t }, ia = ea.map { Int($0) <= t }
        func count(_ m: [Bool], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            var n = 0
            let ya = max(0, y0), yb = min(h - 1, y1), xa = max(0, x0), xb = min(w - 1, x1)
            guard ya <= yb, xa <= xb else { return 0 }
            for y in ya...yb { for x in xa...xb where m[y * w + x] { n += 1 } }
            return n
        }
        func land(_ g: HCGlyph) -> (Double, Double) {
            let c = (Double(g.x0 + g.x1) / 2, Double(g.y0 + g.y1) / 2)
            return model.map { $0.forward(c.0, c.1) } ?? c
        }
        var lost: [HCGlyph] = []
        // A glyph touching the page's edge is one the crop already cuts: the crop keeps
        // print whole, so it is the bed, a shadow or a neighbouring leaf, not print.
        for g in gb where g.x0 > 0 && g.y0 > 0 && g.x1 < w - 1 && g.y1 < h - 1 {
            let n0 = count(ib, g.x0, g.y0, g.x1, g.y1)
            let (cx, cy) = land(g)
            guard cx.isFinite, cy.isFinite else { lost.append(g); continue }
            let hw = Double(g.x1 - g.x0) / 2, hh = Double(g.y1 - g.y0) / 2
            let n1 = count(ia, Int((cx - hw).rounded()) - 2, Int((cy - hh).rounded()) - 2,
                           Int((cx + hw).rounded()) + 2, Int((cy + hh).rounded()) + 2)
            if 2 * n1 < n0 { lost.append(g) }
        }
        // Merges: neighbours in a row, apart before, in one glyph after.
        let sorted = gb.sorted { $0.x0 < $1.x0 }
        func owner(_ p: (Double, Double)) -> Int? {
            ga.firstIndex { Double($0.x0) <= p.0 && p.0 <= Double($0.x1) && Double($0.y0) <= p.1 && p.1 <= Double($0.y1) }
        }
        var merged: [HCGlyph] = []
        var byRow = [Int: [HCGlyph]]()
        for g in sorted { byRow[(g.y0 + g.y1) / 2 / 8, default: []].append(g) }
        for (_, row) in byRow {
            for k in 1..<max(1, row.count) {
                let a = row[k - 1], b = row[k]
                guard b.x0 - a.x1 - 1 >= 2, b.x0 - a.x1 < 3 * (a.y1 - a.y0 + 1) else { continue }
                if let oa = owner(land(a)), let ob = owner(land(b)), oa == ob { merged.append(a) }
            }
        }
        return (lost, merged)
    }

    // MARK: Score

    @Test("Flatten score")
    func score() async throws {
        guard Self.only != "survey", Self.only != "debug" else { return }
        HillClimb.prepare()
        var out: [String: Any] = ["label": HillClimb.label]
        let t0 = HillClimb.now()
        if Self.only == nil || Self.only == "synthetic" { out["synthetic"] = Self.synthetic() }
        let t1 = HillClimb.now()
        if Self.only == nil || Self.only == "real" { out["real"] = await Self.real() }
        let t2 = HillClimb.now()
        if Self.only == nil || Self.only == "speed" { out["speed"] = await Self.speed() }
        out["seconds"] = ["synthetic": HillClimb.r(t1 - t0, 1), "real": HillClimb.r(t2 - t1, 1),
                          "speed": HillClimb.r(HillClimb.now() - t2, 1)]
        HillClimb.write(out, "flatten.json")
    }

    // MARK: Synthetic

    static let synthDPI = 330.0

    struct Warp {
        var band: Double        // share of the leaf's width, from the gutter
        var tilt: Double        // px at the top and bottom text lines (opposite signs)
        var drop: Double        // px, the same on every line
        var squash: Double      // letters at the gutter this much narrower
    }

    /// The leaves scored: per synthetic book, the first 5 full text leaves of spreads.
    static func synthLeaves() -> [(spec: SynthSpec, leaf: Int)] {
        var out: [(SynthSpec, Int)] = []
        for b in 0..<6 {
            var n = 0
            for s0 in HCSynth.book(b, pages: 52).specs where s0.isSpread && n < 5 {
                for k in 0..<2 where n < 5 {
                    let leaf = s0.leaves[k]
                    let words = leaf.items.filter { if case .word = $0 { return true }; return false }.count
                    let plates = leaf.items.contains { if case .plate = $0 { return true }; return false }
                    guard !leaf.blank, !plates, words > 150 else { continue }
                    var s = HillClimbShadowTests.scaled(s0, 3)
                    s.shadow = .none; s.foldLine = nil; s.binding = nil; s.neighbour = nil
                    s.gradX = 0; s.gradY = 0
                    out.append((s, k)); n += 1
                }
            }
        }
        return out
    }

    /// `g` (w × h) warped: flat point (x, y) appears at (X(x), y + dy(x, y)). The gutter is on the right when `right`.
    static func warp(_ g: [UInt8], _ w: Int, _ h: Int, _ wp: Warp, gutterOnRight right: Bool) -> [UInt8] {
        let bandW = wp.band * Double(w)
        let start = right ? Double(w) - bandW : bandW
        func u(_ x: Double) -> Double { max(0, right ? (x - start) / bandW : (start - x) / bandW) }
        // X(x): unchanged outside the band; inside, dX/dx = 1 - squash * u.
        var X = [Double](repeating: 0, count: w + 1)
        if right {
            for x in 0...w { let xd = Double(x); X[x] = xd <= start ? xd : start + (xd - start) - wp.squash * bandW * pow(u(xd), 2) / 2 }
        } else {
            for x in 0...w { let xd = Double(x); X[x] = xd >= start ? xd : start - (start - xd) + wp.squash * bandW * pow(u(xd), 2) / 2 }
        }
        // Inverse of X by walking.
        var inv = [Double](repeating: -1, count: w)
        var i = 0
        for xo in 0..<w {
            let t = Double(xo)
            while i < w - 1 && X[i + 1] < t { i += 1 }
            if t < X[0] || t > X[w] { inv[xo] = -1; continue }
            let a = X[i], b = X[i + 1]
            inv[xo] = Double(i) + (b > a ? (t - a) / (b - a) : 0)
        }
        let yc = Double(h) / 2, half = Double(h) * 0.4
        var out = [UInt8](repeating: 255, count: w * h)
        for xo in 0..<w where inv[xo] >= 0 {
            let x = inv[xo]
            let uu = u(x) * u(x)
            let xa = min(w - 2, Int(x)), fx = x - Double(xa)
            for yo in 0..<h {
                // y + dy(y) = yo; dy is linear in y: dy = uu * (drop + tilt * (y - yc) / half).
                let k = uu * wp.tilt / half
                let y = (Double(yo) - uu * wp.drop + k * yc) / (1 + k)
                guard y >= 0, y < Double(h - 1) else { continue }
                let ya = Int(y), fy = y - Double(ya)
                let p00 = Double(g[ya * w + xa]), p01 = Double(g[ya * w + xa + 1])
                let p10 = Double(g[(ya + 1) * w + xa]), p11 = Double(g[(ya + 1) * w + xa + 1])
                let v = (p00 * (1 - fx) + p01 * fx) * (1 - fy) + (p10 * (1 - fx) + p11 * fx) * fy
                out[yo * w + xo] = UInt8(max(0, min(255, v.rounded())))
            }
        }
        return out
    }

    static func image(_ g: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(g) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Mean and 95th percentile distance (pt) from each truth glyph to the nearest like glyph of `got`; unmatched count.
    static func positions(_ truth: [HCGlyph], _ got: [HCGlyph], radius: Double) -> (mean: Double, p95: Double, unmatched: Int) {
        var d: [Double] = []
        var unmatched = 0
        for a in truth {
            let cx = Double(a.x0 + a.x1) / 2, cy = Double(a.y0 + a.y1) / 2
            var best = Double.infinity
            for b in got where abs(b.x0 - a.x0) < Int(radius) + 4 && abs(b.y0 - a.y0) < Int(radius) + 4 {
                let wa = a.x1 - a.x0, wb = b.x1 - b.x0, ha = a.y1 - a.y0, hb = b.y1 - b.y0
                guard abs(wa - wb) <= max(3, wa / 3), abs(ha - hb) <= max(3, ha / 4) else { continue }
                let e = hypot(Double(b.x0 + b.x1) / 2 - cx, Double(b.y0 + b.y1) / 2 - cy)
                best = min(best, e)
            }
            if best <= radius { d.append(best * 72 / synthDPI) } else { unmatched += 1 }
        }
        return (HillClimb.mean(d), HillClimb.percentile(d, 0.95), unmatched)
    }

    static func synthetic() -> [String: Any] {
        var rng = HCRandom(20_261_121)
        var rows: [[String: Any]] = []
        var curlBefore: [Double] = [], curlAfter: [Double] = [], curlTruth: [Double] = []
        var droopBefore: [Double] = [], droopAfter: [Double] = [], droopTruth: [Double] = []
        var posBefore: [Double] = [], posAfter: [Double] = [], p95After: [Double] = []
        var lostTotal = 0, mergedTotal = 0, flattened = 0, warpedCount = 0, flatTouched = 0, flatCount = 0
        var unmatchedBefore = 0, unmatchedAfter = 0
        var widthBefore: [Double] = [], widthAfter: [Double] = [], widthTruth: [Double] = []
        for (n, item) in synthLeaves().enumerated() {
            autoreleasepool {
                let s = item.spec, leaf = s.leaves[item.leaf]
                guard let scan = HCSynth.render(s, .scan) else { return }
                let rect = leaf.paper.integral.intersection(CGRect(x: 0, y: 0, width: s.W, height: s.H))
                guard let cut = scan.cropping(to: rect) else { return }
                let w = cut.width, h = cut.height
                let truth = HillClimb.gray(cut)
                let right = item.leaf == 0
                let warped = n % 6 != 5         // every 6th leaf stays flat
                let wp = Warp(band: rng.range(0.25, 0.5), tilt: rng.range(-1, 1) * rng.range(8, 45),
                              drop: rng.range(-1, 1) * rng.range(0, 25), squash: rng.range(0, 0.3))
                let before = warped ? warp(truth, w, h, wp, gutterOnRight: right) : truth
                guard let beforeImage = image(before, w, h) else { return }
                let full = CGRect(x: 0, y: 0, width: w, height: h)
                let flatImage = Flatten.pages(beforeImage, regions: [(full, right)])?.image
                let afterImage = flatImage ?? beforeImage
                let cT = curl(cut, dpi: synthDPI, gutterOnRight: right)
                let cB = curl(beforeImage, dpi: synthDPI, gutterOnRight: right)
                let cA = curl(afterImage, dpi: synthDPI, gutterOnRight: right)
                let report = Flatten.report(before, width: w, height: h, gutterOnRight: right)
                let shift = max(abs(wp.tilt) + abs(wp.drop), wp.squash * wp.band * Double(w) / 2) + 3
                let check = flatImage == nil ? (lost: [HCGlyph](), merged: [HCGlyph]())
                    : printCheck(before: beforeImage, after: afterImage, glyphsBefore: cB.glyphs, glyphsAfter: cA.glyphs,
                                 model: report.model)
                let lostList = check.lost
                let lostGlyphs = lostList.count
                lostTotal += lostGlyphs
                mergedTotal += check.merged.count
                let pB = positions(cT.glyphs, cB.glyphs, radius: shift + 6)
                let pA = positions(cT.glyphs, cA.glyphs, radius: shift + 6)
                if warped {
                    warpedCount += 1
                    if flatImage != nil { flattened += 1 }
                    curlBefore.append(cB.meanPt); curlAfter.append(cA.meanPt); curlTruth.append(cT.meanPt)
                    droopBefore.append(cB.droopPt); droopAfter.append(cA.droopPt); droopTruth.append(cT.droopPt)
                    posBefore.append(pB.mean); posAfter.append(pA.mean); p95After.append(pA.p95)
                    unmatchedBefore += pB.unmatched; unmatchedAfter += pA.unmatched
                    if let a = cB.widthRatio, let b = cA.widthRatio, let t = cT.widthRatio {
                        widthBefore.append(a); widthAfter.append(b); widthTruth.append(t)
                    }
                } else {
                    flatCount += 1
                    if flatImage != nil { flatTouched += 1 }
                }
                rows.append(["id": "synth-\(s.book)-\(s.index)\(right ? "L" : "R")", "warped": warped,
                             "warp": warped ? [HillClimb.r(wp.band, 3), HillClimb.r(wp.tilt, 2), HillClimb.r(wp.drop, 2),
                                               HillClimb.r(wp.squash, 3)] : [],
                             "outcome": report.outcome.rawValue, "note": report.note, "xHeight": report.xHeight,
                             "droopPx": HillClimb.r(report.droop, 1), "flattened": flatImage != nil,
                             "curlPt": [HillClimb.r(cT.meanPt, 3), HillClimb.r(cB.meanPt, 3), HillClimb.r(cA.meanPt, 3)],
                             "droopPt": [HillClimb.r(cT.droopPt, 3), HillClimb.r(cB.droopPt, 3), HillClimb.r(cA.droopPt, 3)],
                             "posErrPt": [HillClimb.r(pB.mean, 3), HillClimb.r(pA.mean, 3)],
                             "posP95Pt": HillClimb.r(pA.p95, 3),
                             "unmatched": [pB.unmatched, pA.unmatched],
                             "glyphs": [cB.glyphs.count, cA.glyphs.count], "lost": lostGlyphs, "merged": check.merged.count,
                             "widthRatio": [cT.widthRatio ?? 0, cB.widthRatio ?? 0, cA.widthRatio ?? 0].map { HillClimb.r($0, 3) }])
                if let dir = HillClimb.env["HILLCLIMB_FLATTEN_DUMP"], n < 12 {
                    let base = URL(fileURLWithPath: dir)
                    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                    HillClimb.png(beforeImage, to: base.appendingPathComponent("synth-\(n)-before.png"))
                    HillClimb.png(afterImage, to: base.appendingPathComponent("synth-\(n)-after.png"))
                    for (k, g) in lostList.prefix(6).enumerated() {
                        let r = CGRect(x: g.x0 - 40, y: g.y0 - 40, width: g.x1 - g.x0 + 80, height: g.y1 - g.y0 + 80)
                        let c = report.model.map { $0.forward(Double(g.x0 + g.x1) / 2, Double(g.y0 + g.y1) / 2) }
                            ?? (Double(g.x0 + g.x1) / 2, Double(g.y0 + g.y1) / 2)
                        let r2 = r.offsetBy(dx: c.0 - r.midX, dy: c.1 - r.midY).integral
                        if let a = beforeImage.cropping(to: r), let b = afterImage.cropping(to: r2) {
                            HillClimb.png(a, to: base.appendingPathComponent("synth-\(n)-lost\(k)-before.png"))
                            HillClimb.png(b, to: base.appendingPathComponent("synth-\(n)-lost\(k)-after.png"))
                        }
                    }
                }
            }
        }
        HillClimb.write(["leaves": rows], "flatten-synth.json")
        return ["warped": warpedCount, "flattened": flattened, "flatLeaves": flatCount, "flatLeavesChanged": flatTouched,
                "curlPt": ["truth": HillClimb.r(HillClimb.mean(curlTruth), 3), "before": HillClimb.r(HillClimb.mean(curlBefore), 3),
                           "after": HillClimb.r(HillClimb.mean(curlAfter), 3)],
                "droopPt": ["truth": HillClimb.r(HillClimb.mean(droopTruth), 3), "before": HillClimb.r(HillClimb.mean(droopBefore), 3),
                            "after": HillClimb.r(HillClimb.mean(droopAfter), 3)],
                "posErrPt": ["before": HillClimb.r(HillClimb.mean(posBefore), 3), "after": HillClimb.r(HillClimb.mean(posAfter), 3),
                             "p95After": HillClimb.r(HillClimb.percentile(p95After, 0.95), 3)],
                "unmatched": ["before": unmatchedBefore, "after": unmatchedAfter],
                "widthRatio": ["truth": HillClimb.r(HillClimb.mean(widthTruth), 3), "before": HillClimb.r(HillClimb.mean(widthBefore), 3),
                               "after": HillClimb.r(HillClimb.mean(widthAfter), 3)],
                "glyphsLost": lostTotal, "glyphsMerged": mergedTotal]
    }

    // MARK: Real

    /// Books whose curl is scored, and how many of their pages (every page when nil).
    static let realBooks: [(name: String, step: Int)] = [
        ("Smith-1950", 1), ("Freudenthal-1999", 1), ("Riezler-1940", 1), ("Wallace-1992", 1),
        ("Simon-1940", 1), ("Simon-1943", 1), ("Cherniss-1935", 3), ("Oesterle-1955", 4)]

    static func real() async -> [String: Any] {
        var books: [[String: Any]] = []
        var records: [[String: Any]] = []
        var worst: [(id: String, curl: Double, side: Side)] = []
        let dumpDir = HillClimb.env["HILLCLIMB_FLATTEN_SHOTS"].map { URL(fileURLWithPath: $0) }
        let only = HillClimb.env["HILLCLIMB_FLATTEN_BOOKS"].map { Set($0.split(separator: ",").map(String.init)) }
        for job in realBooks where only?.contains(job.name) ?? true {
            guard let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == job.name }) else { continue }
            var cb: [Double] = [], ca: [Double] = [], cbCurled: [Double] = [], caCurled: [Double] = []
            var db: [Double] = [], da: [Double] = [], dbCurled: [Double] = [], daCurled: [Double] = []
            var wb: [Double] = [], wa: [Double] = []
            var flattenedCurled = 0, curled = 0, flattenedStraight = 0, straight = 0, lostTotal = 0, mergedTotal = 0, glyphsTotal = 0
            var secs: [Double] = []
            var outcomes: [String: Int] = [:]
            let t0 = HillClimb.now()
            let wanted = HillClimb.env["HILLCLIMB_FLATTEN_PAGES"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
            let counts = await sides(of: url, step: job.step, pages: wanted, flatten: true) { side in
                let b = curl(side.image, dpi: side.dpi, gutterOnRight: side.gutterOnRight)
                let afterImage = side.flat ?? side.image
                let a = side.flat == nil ? b : curl(afterImage, dpi: side.dpi, gutterOnRight: side.gutterOnRight)
                let rep = Flatten.report(side.image, gutterOnRight: side.gutterOnRight)
                outcomes[rep.outcome.rawValue, default: 0] += 1
                secs.append(side.seconds)
                let check = side.flat == nil ? (lost: [HCGlyph](), merged: [HCGlyph]())
                    : printCheck(before: side.image, after: afterImage, glyphsBefore: b.glyphs, glyphsAfter: a.glyphs, model: rep.model)
                let lostGlyphs = check.lost
                lostTotal += lostGlyphs.count
                mergedTotal += check.merged.count
                glyphsTotal += b.glyphs.count
                let measured = b.lines >= 6
                if measured {
                    cb.append(b.meanPt); ca.append(a.meanPt); db.append(b.droopPt); da.append(a.droopPt)
                    // Curled: the lines' gutter ends droop a point or more; straight: under half a point.
                    if b.droopPt >= 1 {
                        curled += 1; cbCurled.append(b.meanPt); caCurled.append(a.meanPt)
                        dbCurled.append(b.droopPt); daCurled.append(a.droopPt)
                        if side.flat != nil { flattenedCurled += 1 }
                    } else if b.droopPt < 0.5 {
                        straight += 1
                        if side.flat != nil { flattenedStraight += 1 }
                    }
                    if let x = b.widthRatio, let y = a.widthRatio, side.flat != nil { wb.append(x); wa.append(y) }
                    worst.append((side.id, b.droopPt, side))
                    worst.sort { $0.curl > $1.curl }
                    if worst.count > 3 { worst.removeLast() }
                }
                records.append(["id": side.id, "dpi": side.dpi, "lines": b.lines, "outcome": rep.outcome.rawValue, "note": rep.note,
                                "flattened": side.flat != nil,
                                "curlPt": [HillClimb.r(b.meanPt, 3), HillClimb.r(a.meanPt, 3)],
                                "maxCurlPt": [HillClimb.r(b.maxPt, 3), HillClimb.r(a.maxPt, 3)],
                                "droopPt": [HillClimb.r(b.droopPt, 3), HillClimb.r(a.droopPt, 3)],
                                "misfitPx": HillClimb.r(rep.misfit, 2), "modelCurlPx": HillClimb.r(rep.curl, 2), "droopPx": HillClimb.r(rep.droop, 1),
                                "xHeightPx": rep.xHeight, "squash": HillClimb.r(rep.squash, 3),
                                "stretchPx": HillClimb.r(rep.stretchPx, 1), "maxShiftPx": HillClimb.r(rep.maxShift, 1),
                                "widthRatio": [b.widthRatio.map { HillClimb.r($0, 3) } ?? 0, a.widthRatio.map { HillClimb.r($0, 3) } ?? 0],
                                "glyphs": [b.glyphs.count, a.glyphs.count], "lost": lostGlyphs.count, "merged": check.merged.count,
                                "mergedAt": check.merged.prefix(5).map { [$0.x0, $0.y0, $0.x1, $0.y1] },
                                "lostAt": lostGlyphs.prefix(5).map { [$0.x0, $0.y0, $0.x1, $0.y1] },
                                "seconds": HillClimb.r(side.seconds, 3)])
                if let dumpDir, side.flat != nil, HillClimb.env["HILLCLIMB_FLATTEN_SHOTS_ALL"] != nil {
                    try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
                    HillClimb.png(side.image, to: dumpDir.appendingPathComponent("\(side.id)-before.png"))
                    HillClimb.png(afterImage, to: dumpDir.appendingPathComponent("\(side.id)-after.png"))
                }
            }
            books.append(["name": job.name, "layeredPages": counts.layered, "pages": counts.pages, "sides": cb.count,
                          "curlPt": [HillClimb.r(HillClimb.mean(cb), 3), HillClimb.r(HillClimb.mean(ca), 3)],
                          "curledSides": curled, "flattenedCurled": flattenedCurled,
                          "curledCurlPt": [HillClimb.r(HillClimb.mean(cbCurled), 3), HillClimb.r(HillClimb.mean(caCurled), 3)],
                          "droopPt": [HillClimb.r(HillClimb.mean(db), 3), HillClimb.r(HillClimb.mean(da), 3)],
                          "curledDroopPt": [HillClimb.r(HillClimb.mean(dbCurled), 3), HillClimb.r(HillClimb.mean(daCurled), 3)],
                          "straightSides": straight, "flattenedStraight": flattenedStraight,
                          "widthRatioFlattened": [HillClimb.r(HillClimb.mean(wb), 3), HillClimb.r(HillClimb.mean(wa), 3)],
                          "glyphs": glyphsTotal, "glyphsLost": lostTotal, "glyphsMerged": mergedTotal, "outcomes": outcomes,
                          "secondsPerSide": HillClimb.r(HillClimb.mean(secs), 3),
                          "wallSeconds": HillClimb.r(HillClimb.now() - t0, 1)])
        }
        HillClimb.write(["label": HillClimb.label, "pages": records], "flatten-pages.json")
        if let dumpDir {
            try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
            for (rank, w) in worst.enumerated() {
                let name = "\(rank + 1)-\(w.id)"
                HillClimb.png(w.side.image, to: dumpDir.appendingPathComponent("\(name)-before.png"))
                HillClimb.png(w.side.flat ?? w.side.image, to: dumpDir.appendingPathComponent("\(name)-after.png"))
            }
        }
        return ["books": books, "worst": worst.map { [$0.id, HillClimb.r($0.curl, 3)] as [Any] }]
    }

    // MARK: Speed

    static func speed() async -> [String: Any] {
        // Smith-1950 is a layered scan, which the export does not flatten: time a plain one.
        guard let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == "Freudenthal-1999" }) else { return [:] }
        let m = HillClimb.makeModel()
        await HillClimb.load(url, into: m)
        let pages = Array(m.pages.prefix(20))
        var out: [String: Any] = [:]
        for on in [false, true] {
            var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false,
                                                reader: m.ocrReader, packs: m.ocrPacks, enhanceMode: m.enhanceMode)
            settings.matchScanResolution = m.matchScanResolution
            settings.flattenPages = on
            let file = HillClimb.scratch.appendingPathComponent("flatten-speed-\(on).pdf")
            try? FileManager.default.removeItem(at: file)
            let t0 = HillClimb.now()
            let report: PDFExporter.Report? = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let doc = AppModel.reopen(url, password: nil) else { cont.resume(returning: nil); return }
                    cont.resume(returning: try? PDFExporter.export(pages: pages, from: doc, to: file, settings: settings))
                }
            }
            let s = HillClimb.now() - t0
            let n = report?.pageCount ?? 0
            out[on ? "on" : "off"] = ["outputPages": n, "seconds": HillClimb.r(s, 2),
                                      "secondsPerPage": HillClimb.r(n > 0 ? s / Double(n) : 0, 3)]
            try? FileManager.default.removeItem(at: file)
        }
        return out
    }

    // MARK: Debug

    /// The side drawn with the score's baselines (red) and Flatten's (green, the long lines it traced).
    static func overlay(_ image: CGImage, dpi: Double, gutterOnRight: Bool?) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        let g = HillClimb.gray(image)
        let ls = HCBaselines.longLines(HCBaselines.lines(HCBaselines.glyphs(g, width: w, height: h)))
        ctx.setLineWidth(2)
        ctx.setStrokeColor(red: 1, green: 0, blue: 0, alpha: 0.8)
        for l in ls {
            ctx.move(to: CGPoint(x: l.base[0].x, y: l.base[0].y))
            for p in l.base.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
            ctx.strokePath()
        }
        let rep = Flatten.report(image, gutterOnRight: gutterOnRight)
        ctx.setStrokeColor(red: 0, green: 0.7, blue: 0, alpha: 0.8)
        for l in rep.traced {
            ctx.move(to: CGPoint(x: l.a, y: l.at(l.a) + 3))
            for k in 1...60 { let x = l.a + (l.b - l.a) * Double(k) / 60; ctx.addLine(to: CGPoint(x: x, y: l.at(x) + 3)) }
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    /// HILLCLIMB_FLATTEN_DEBUG="Book-1950:12,40;Other-1999:3" draws those source pages' sides
    /// (before, and after when flattened) to HILLCLIMB_FLATTEN_DEBUG_OUT.
    @Test("Debug overlays")
    func debug() async {
        guard let spec = HillClimb.env["HILLCLIMB_FLATTEN_DEBUG"], let outDir = HillClimb.env["HILLCLIMB_FLATTEN_DEBUG_OUT"] else { return }
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for part in spec.split(separator: ";") {
            let bits = part.split(separator: ":")
            guard bits.count == 2, let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == String(bits[0]) }) else { continue }
            let pages = Set(bits[1].split(separator: ",").compactMap { Int($0) })
            _ = await Self.sides(of: url, step: 1, pages: pages, flatten: true) { side in
                let rep = Flatten.report(side.image, gutterOnRight: side.gutterOnRight)
                print("debug \(side.id): \(rep.outcome.rawValue) xh \(rep.xHeight) lines \(rep.lines) curl \(HillClimb.r(rep.curl, 2)) droop \(HillClimb.r(rep.droop, 1)) misfit \(HillClimb.r(rep.misfit, 2)) shift \(HillClimb.r(rep.maxShift, 1)) squash \(HillClimb.r(rep.squash, 3)) stretch \(HillClimb.r(rep.stretchPx, 1)) \(rep.note)")
                HillClimb.png(side.image, to: dir.appendingPathComponent("\(side.id)-plain-before.png"))
                if let f = side.flat { HillClimb.png(f, to: dir.appendingPathComponent("\(side.id)-plain-after.png")) }
                if let o = Self.overlay(side.image, dpi: side.dpi, gutterOnRight: side.gutterOnRight) {
                    HillClimb.png(o, to: dir.appendingPathComponent("\(side.id)-before.png"))
                }
                if let f = side.flat, let o = Self.overlay(f, dpi: side.dpi, gutterOnRight: side.gutterOnRight) {
                    HillClimb.png(o, to: dir.appendingPathComponent("\(side.id)-after.png"))
                }
            }
        }
    }

    // MARK: Survey

    @Test("Survey: curl of real pages")
    func survey() async {
        guard Self.only == "survey" else { return }
        HillClimb.prepare()
        var books: [[String: Any]] = []
        var records: [[String: Any]] = []
        let only = HillClimb.env["HILLCLIMB_FLATTEN_BOOKS"].map { Set($0.split(separator: ",").map(String.init)) }
        for url in HillClimb.bookURLs() where only?.contains(HillClimb.shortName(url)) ?? true {
            let name = HillClimb.shortName(url)
            let step = HillClimb.fileSize(url) > 150_000_000 ? 4 : 1
            var curls: [Double] = [], ratios: [Double] = []
            let t0 = HillClimb.now()
            let counts = await Self.sides(of: url, step: step, flatten: false) { side in
                let c = Self.curl(side.image, dpi: side.dpi, gutterOnRight: side.gutterOnRight)
                guard c.lines >= 6 else { return }
                curls.append(c.meanPt)
                if let r = c.widthRatio { ratios.append(r) }
                records.append(["id": side.id, "dpi": side.dpi, "lines": c.lines,
                                "meanCurlPt": HillClimb.r(c.meanPt, 3), "maxCurlPt": HillClimb.r(c.maxPt, 3),
                                "widthRatio": c.widthRatio.map { HillClimb.r($0, 3) } ?? NSNull()])
            }
            books.append(["name": name, "layeredPages": counts.layered, "pages": counts.pages, "sides": curls.count,
                          "medianCurlPt": HillClimb.r(HCBaselines.median(curls), 3),
                          "p90CurlPt": HillClimb.r(HillClimb.percentile(curls, 0.9), 3),
                          "over0_5pt": curls.filter { $0 > 0.5 }.count, "over1pt": curls.filter { $0 > 1 }.count,
                          "medianWidthRatio": HillClimb.r(HCBaselines.median(ratios), 3),
                          "seconds": HillClimb.r(HillClimb.now() - t0, 1)])
        }
        HillClimb.write(["books": books, "pages": records], "flatten-survey.json")
        #expect(!records.isEmpty)
    }
}
