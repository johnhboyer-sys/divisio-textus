import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFCropper

/// Hill-climb score for Remove shadows. Runs only when HILLCLIMB_DIR is set; writes
/// results/<label>/shadow.json. HILLCLIMB_SHADOW=off scores the export without the
/// option (the baseline); HILLCLIMB_SHADOW_ONLY=synthetic, real, pages or comb runs one part.
/// **Whole books** (`pages`): the print-loss gate, every output page of every corpus book.
///
/// **Synthetic.** Spreads from `HCSynth` (the split score's generator), drawn 3 times
/// larger (330 DPI) and level, with the fold's distractors it draws (soft and hard
/// shadows, a crease, comb and spiral binding, uneven paper) plus marks it doesn't:
/// the striped edges of the page stack broken into dashes, ticks and specks by the
/// fold, none touching print. Each leaf, cut at its paper, goes through
/// `PDFExporter.finished` in Black and white and in Color (gray). Per mode:
/// * `residue`: of the pixels in the fold zone (from the fold to the print nearest it,
///   the median over rows) that are not print (2 px from it), the share darker than
///   paper (black in black and white; elsewhere 30 or more off the page's paper, either way,
///   so paper evened out too far, to white, counts as well). Lower is
///   better. `residuePage` is the same over the whole leaf.
/// * `printLoss`: the share of solid print pixels (mask under 60) gone to paper, and
///   `glyphsLost`, print components that lost half their solid pixels. Hard gate.
///
/// **Real.** Chosen pages of the corpus (`cases`), each book cut to the pages near
/// them and Auto-detected, exported as the app does in Color and in Black and white,
/// with and without the option, each output page drawn again at its own resolution.
/// * `residue`: dark pixels (at most the Otsu cut of the page without the option)
///   beside the text block on the fold side (both sides for a single page), outside
///   the boxes of glyphs in text lines (`HCGlyphDetector`, vertical marks left out,
///   a glyph with a row neighbour); `marks` counts their groups of 4 px or more.
/// * `glyphsLost`: glyphs of the page without the option with under 30% of their dark
///   pixels left with it; `lostInLines` those with a row neighbour (hard gate),
///   `lostAlone` the rest (look at them: they may be the fold's marks); `losses` lists them.
@Suite("HillClimb shadow", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct HillClimbShadowTests {
    static var removeOn: Bool { HillClimb.env["HILLCLIMB_SHADOW"] != "off" }
    static var only: String? { HillClimb.env["HILLCLIMB_SHADOW_ONLY"] }

    @Test("Shadow score")
    func score() async throws {
        HillClimb.prepare()
        var out: [String: Any] = ["removeShadows": Self.removeOn]
        let t0 = HillClimb.now()
        if Self.only == nil || Self.only == "synthetic" { out["synthetic"] = Self.synthetic() }
        let t1 = HillClimb.now()
        if Self.only == nil || Self.only == "real" { out["real"] = try await Self.real() }
        if Self.only == nil || Self.only == "pages" { out["pages"] = try await Self.pages() }
        if Self.only == nil || Self.only == "comb" {
            out["combSynthetic"] = Self.combSynthetic()
            out["combReal"] = try await Self.combReal()
        }
        out["seconds"] = ["synthetic": HillClimb.r(t1 - t0, 1), "real": HillClimb.r(HillClimb.now() - t1, 1)]
        HillClimb.write(out, "shadow.json")
        if let dir = HillClimb.env["HILLCLIMB_SHADOW_TRIAGE"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for start in stride(from: 0, to: Self.triage.count, by: 24) {
                let rows = Array(Self.triage[start..<min(Self.triage.count, start + 24)])
                if let im = BWShowTests.grid(rows, height: nil) {
                    HillClimb.png(im, to: URL(fileURLWithPath: dir).appendingPathComponent("losses-\(start / 24).png"))
                }
            }
        }
    }

    // MARK: Synthetic

    static let scale: CGFloat = 3
    static let synthDPI = 330.0

    /// `s` drawn `k` times larger and level.
    static func scaled(_ s: SynthSpec, _ k: CGFloat) -> SynthSpec {
        var t = s
        t.W = Int((CGFloat(s.W) * k).rounded()); t.H = Int((CGFloat(s.H) * k).rounded())
        t.tiltDegrees = 0
        func r(_ c: CGRect) -> CGRect { CGRect(x: c.minX * k, y: c.minY * k, width: c.width * k, height: c.height * k) }
        t.leaves = s.leaves.map { leaf in
            SynthLeaf(paper: r(leaf.paper), items: leaf.items.map { item -> SynthItem in
                switch item {
                case .word(let text, let font, let size, let x, let b):
                    return .word(text, font: font, size: size * k, x: x * k, baseline: b * k)
                case .rule(let c): return .rule(r(c))
                case .plate(let c, let shade): return .plate(r(c), shade: shade)
                }
            }, blank: leaf.blank)
        }
        t.foldX = s.foldX * k
        t.shadowX = s.isSpread ? t.foldX : s.shadowX * k
        let kd = Double(k)
        switch s.shadow {
        case .none: break
        case .soft(let d, let sg): t.shadow = .soft(depth: d, sigma: sg * kd)
        case .hard(let d, let half, let fall): t.shadow = .hard(depth: d, half: half * kd, fall: fall * kd)
        }
        if let f = s.foldLine { t.foldLine = (f.gray, f.width * k) }
        if let b = s.binding { t.binding = (b.spiral, b.x * k, b.pitch * k, b.size * k) }
        if let n = s.neighbour { t.neighbour = (n.onLeft, n.width * k, n.gray) }
        t.paperRows = (s.paperRows.lowerBound * k)...(s.paperRows.upperBound * k)
        return t
    }

    /// The spreads scored: per book, the first 4 with a fold distractor and the first without.
    static func synthSpecs() -> [SynthSpec] {
        var out: [SynthSpec] = []
        for b in 0..<6 {
            let specs = HCSynth.book(b, pages: 52).specs.filter { $0.isSpread }
            func marked(_ s: SynthSpec) -> Bool {
                if case .none = s.shadow { return s.foldLine != nil || s.binding != nil }
                return true
            }
            out += specs.filter(marked).prefix(4)
            out += specs.filter { !marked($0) }.prefix(1)
        }
        return out
    }

    /// Dark marks by the fold that the generator doesn't draw, none within 4 px of print:
    /// stripes of the page stack broken into dashes, ticks, specks. Their tags.
    static func addJunk(_ g: inout [UInt8], _ w: Int, _ h: Int, _ s: SynthSpec, printMask: [UInt8]) -> [String] {
        var rng = HCRandom(s.seed ^ 0x5AD0)
        let inch = synthDPI
        let fold = Int(s.foldX.rounded())
        let top = max(0, Int(s.paperRows.lowerBound)), foot = min(h, Int(s.paperRows.upperBound))
        var tags: [String] = []
        func clearOfPrint(_ x0: Int, _ y0: Int, _ bw: Int, _ bh: Int) -> Bool {
            for y in max(0, y0 - 4)..<min(h, y0 + bh + 4) {
                for x in max(0, x0 - 4)..<min(w, x0 + bw + 4) where printMask[y * w + x] < 200 { return false }
            }
            return true
        }
        func mark(_ x0: Int, _ y0: Int, _ bw: Int, _ bh: Int, _ v: UInt8) {
            guard bw > 0, bh > 0, x0 >= 0, y0 >= top, x0 + bw < w, y0 + bh < foot, clearOfPrint(x0, y0, bw, bh) else { return }
            for y in y0..<(y0 + bh) { for x in x0..<(x0 + bw) { g[y * w + x] = min(g[y * w + x], v) } }
        }
        if rng.chance(0.5) {
            tags.append("stripes")
            for _ in 0..<rng.int(3, 7) {
                let x = fold + (rng.chance(0.5) ? 1 : -1) * Int(rng.range(0.03, 0.25) * inch)
                let bw = rng.int(1, 3), v = UInt8(rng.int(40, 90))
                var y = top + rng.int(0, 40)
                while y < foot {
                    let len = Int(rng.range(0.1, 1.0) * inch)
                    mark(x, y, bw, min(len, foot - y - 1), v)
                    y += len + Int(rng.range(0.02, 0.2) * inch)
                }
            }
        }
        if rng.chance(0.5) {
            tags.append("ticks")
            for _ in 0..<rng.int(10, 30) {
                let x = fold + Int(rng.range(-0.3, 0.3) * inch)
                mark(x, rng.int(top, foot), rng.int(2, 4), Int(rng.range(0.03, 0.08) * inch), UInt8(rng.int(30, 90)))
            }
        }
        if rng.chance(0.6) {
            tags.append("specks")
            for _ in 0..<rng.int(50, 200) {
                let x = fold + Int(rng.range(-0.4, 0.4) * inch), sz = rng.int(1, 4)
                mark(x, rng.int(top, foot), sz, sz, UInt8(rng.int(20, 100)))
            }
        }
        return tags
    }

    struct Tally {
        var zoneNonPrint = 0, zoneDark = 0, pageNonPrint = 0, pageDark = 0
        var solid = 0, solidLost = 0, glyphs = 0, glyphsLost = 0, glyphsLostNew = 0
        var newBoxes: [(Int, Int, Int, Int)] = []
        mutating func add(_ o: Tally) {
            glyphsLostNew += o.glyphsLostNew
            zoneNonPrint += o.zoneNonPrint; zoneDark += o.zoneDark; pageNonPrint += o.pageNonPrint; pageDark += o.pageDark
            solid += o.solid; solidLost += o.solidLost; glyphs += o.glyphs; glyphsLost += o.glyphsLost
        }
        var json: [String: Any] {
            ["residue": HillClimb.r(Double(zoneDark) / Double(max(1, zoneNonPrint)), 6),
             "residuePage": HillClimb.r(Double(pageDark) / Double(max(1, pageNonPrint)), 6),
             "printLoss": HillClimb.r(Double(solidLost) / Double(max(1, solid)), 7),
             "printLossPx": solidLost, "glyphs": glyphs, "glyphsLost": glyphsLost, "glyphsLostNew": glyphsLostNew]
        }
    }

    /// Score one leaf's output `out` against its print mask; the fold on the right if `foldRight`.
    /// `glyphsLostNew`: glyphs lost in `out` but not in `ref` (the leaf without the option).
    static func tally(out: [UInt8], ref: [UInt8]?, mask: [UInt8], w: Int, h: Int, foldRight: Bool, bw: Bool) -> Tally {
        var t = Tally()
        // Print and 2 px about it.
        let near = LayeredScan.minFilter(mask.map { $0 < 250 ? 0 : 255 }, w, h, radius: 2)
        // The fold zone: from the fold to the median over rows of the print nearest it.
        var nearest: [Int] = []
        for y in 0..<h {
            let row = y * w
            if foldRight { if let x = (0..<w).last(where: { mask[row + $0] < 128 }) { nearest.append(x) } }
            else if let x = (0..<w).first(where: { mask[row + $0] < 128 }) { nearest.append(x) }
        }
        nearest.sort()
        let edge = nearest.isEmpty ? (foldRight ? w - Int(1.2 * synthDPI) : Int(1.2 * synthDPI)) : nearest[nearest.count / 2]
        // The page's paper, away from the zone.
        var paperSample: [Int] = []
        for i in stride(from: 0, to: w * h, by: 5) where near[i] == 255 {
            let x = i % w
            if foldRight ? x < edge - 20 : x > edge + 20 { paperSample.append(Int(out[i])) }
        }
        paperSample.sort()
        let paper = paperSample.isEmpty ? 255 : paperSample[paperSample.count / 2]
        let darkCut = bw ? 128 : paper - 30
        let lostCut = bw ? 128 : paper - 40
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if near[i] == 255 {
                    let dark = bw ? Int(out[i]) < darkCut : abs(Int(out[i]) - paper) >= 30
                    t.pageNonPrint += 1; if dark { t.pageDark += 1 }
                    if foldRight ? x > edge + 2 : x < edge - 2 { t.zoneNonPrint += 1; if dark { t.zoneDark += 1 } }
                } else if mask[i] < 60 {
                    t.solid += 1
                    if Int(out[i]) >= lostCut { t.solidLost += 1 }
                }
            }
        }
        // Print components that lost half their solid pixels.
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for start in 0..<(w * h) where mask[start] < 128 && !seen[start] {
            seen[start] = true; stack = [start]
            var solid = 0, lost = 0, refLost = 0
            var bx0 = w, bx1 = 0, by0 = h, by1 = 0
            while let k = stack.popLast() {
                if mask[k] < 60 {
                    solid += 1
                    if Int(out[k]) >= lostCut { lost += 1 }
                    if let ref, Int(ref[k]) >= lostCut { refLost += 1 }
                }
                let x = k % w, y = k / w
                bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y)
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) where mask[ny * w + nx] < 128 && !seen[ny * w + nx] {
                        seen[ny * w + nx] = true; stack.append(ny * w + nx)
                    }
                }
            }
            guard solid >= 3 else { continue }
            t.glyphs += 1
            if lost * 2 >= solid {
                t.glyphsLost += 1
                if ref != nil, refLost * 2 < solid { t.glyphsLostNew += 1; t.newBoxes.append((bx0, by0, bx1, by1)) }
            }
        }
        return t
    }

    static func synthetic() -> [String: Any] {
        var totals: [String: Tally] = ["bw": Tally(), "color": Tally()]
        var byTag: [String: [String: Tally]] = [:]
        var pages: [[String: Any]] = []
        for spec in synthSpecs() {
            let s = scaled(spec, scale)
            guard let scanImage = HCSynth.render(s, .scan) else { continue }
            var scan = HillClimb.gray(scanImage)
            let masks = s.leaves.indices.compactMap { HCSynth.render(s, .print($0)).map(HillClimb.gray) }
            guard masks.count == s.leaves.count else { continue }
            var all = masks[0]
            for m in masks.dropFirst() { for i in all.indices { all[i] = min(all[i], m[i]) } }
            var tags = spec.tags.filter { ["shadowSoft", "shadowHard", "foldLine", "comb", "spiral", "uneven"].contains($0) }
            tags += addJunk(&scan, s.W, s.H, s, printMask: all)
            if tags.isEmpty { tags = ["clean"] }
            for (k, leaf) in s.leaves.enumerated() {
                let x0 = max(0, Int(leaf.paper.minX.rounded())), x1 = min(s.W, Int(leaf.paper.maxX.rounded()))
                let y0 = max(0, Int(s.paperRows.lowerBound.rounded())), y1 = min(s.H, Int(s.paperRows.upperBound.rounded()))
                let w = x1 - x0, h = y1 - y0
                guard w > 10, h > 10 else { continue }
                var g = [UInt8](repeating: 255, count: w * h), m = g
                for y in 0..<h {
                    for x in 0..<w { g[y * w + x] = scan[(y + y0) * s.W + x + x0]; m[y * w + x] = masks[k][(y + y0) * s.W + x + x0] }
                }
                guard let image = BlackAndWhite.image(g, width: w, height: h) else { continue }
                var record: [String: Any] = ["book": spec.book, "index": spec.index, "leaf": k, "tags": tags]
                for (mode, enhance) in [("bw", EnhanceMode.blackAndWhite), ("color", EnhanceMode.color)] {
                    var settings = PDFExporter.Settings()
                    settings.enhanceMode = enhance
                    settings.removeShadows = removeOn
                    let outImage = PDFExporter.finished(image, dpi: synthDPI, settings: settings)
                    let out = BlackAndWhite.grayPixels(outImage)
                    var ref: [UInt8]?
                    if removeOn {
                        settings.removeShadows = false
                        ref = BlackAndWhite.grayPixels(PDFExporter.finished(image, dpi: synthDPI, settings: settings))
                    }
                    let t = tally(out: out, ref: ref, mask: m, w: w, h: h, foldRight: k == 0, bw: mode == "bw")
                    if HillClimb.env["HILLCLIMB_SHADOW_TRIAGE"] != nil,
                       let refImage = ref.flatMap({ BlackAndWhite.image($0, width: w, height: h) }) {
                        for b in t.newBoxes {
                            let x0 = max(0, b.0 - 60), y0 = max(0, b.1 - 60)
                            let r = CGRect(x: x0, y: y0, width: min(w, b.2 + 60) - x0, height: min(h, b.3 + 60) - y0)
                            if let a = image.cropping(to: r), let c = refImage.cropping(to: r), let d = outImage.cropping(to: r) {
                                triage.append([("b\(spec.book) i\(spec.index) leaf\(k) \(mode) scan", a), ("off", c), ("on", d)])
                            }
                        }
                    }
                    totals[mode]!.add(t)
                    for tag in tags { byTag[tag, default: [:]][mode, default: Tally()].add(t) }
                    record[mode] = t.json
                }
                pages.append(record)
            }
        }
        var tagJSON: [String: Any] = [:]
        for (tag, modes) in byTag { tagJSON[tag] = modes.mapValues { $0.json } }
        print("SHADOW synthetic bw \(totals["bw"]!.json)")
        print("SHADOW synthetic color \(totals["color"]!.json)")
        return ["leaves": pages.count, "bw": totals["bw"]!.json, "color": totals["color"]!.json,
                "byTag": tagJSON, "pages": pages]
    }

    // MARK: Comb bindings

    /// Residue inside a comb or spiral binding's marks: the pixels in them (each mark
    /// grown by `grow` px) that aren't print (2 px from it) and end up darker than paper
    /// (black in black and white, 30 or more off the page's paper elsewhere, or 30 off
    /// its hue), their groups of 4 px or more (`marks`), and glyphs lost.
    struct CombTally {
        var bandPx = 0, residuePx = 0, marks = 0, glyphsLost = 0, glyphsLostNew = 0, lostInLines = 0, lostAlone = 0
        mutating func add(_ o: CombTally) {
            bandPx += o.bandPx; residuePx += o.residuePx; marks += o.marks; glyphsLost += o.glyphsLost
            glyphsLostNew += o.glyphsLostNew; lostInLines += o.lostInLines; lostAlone += o.lostAlone
        }
        var json: [String: Any] {
            ["bandPx": bandPx, "residuePx": residuePx, "marks": marks, "glyphsLost": glyphsLost,
             "glyphsLostNew": glyphsLostNew, "lostInLines": lostInLines, "lostAlone": lostAlone]
        }
    }

    /// Residue and its groups in `band`: `off(i)` says a pixel is not paper.
    static func combResidue(band: [Bool], keep: [Bool], w: Int, h: Int, off: (Int) -> Bool) -> (Int, Int, Int) {
        var dark = [Bool](repeating: false, count: w * h)
        var bandPx = 0, residue = 0
        for i in 0..<(w * h) where band[i] && !keep[i] {
            bandPx += 1
            if off(i) { dark[i] = true; residue += 1 }
        }
        var seen = [Bool](repeating: false, count: w * h), marks = 0
        for s in 0..<(w * h) where dark[s] && !seen[s] {
            seen[s] = true
            var stack = [s], n = 0
            while let k = stack.popLast() {
                n += 1
                let x = k % w, y = k / w
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) where dark[ny * w + nx] && !seen[ny * w + nx] {
                        seen[ny * w + nx] = true; stack.append(ny * w + nx)
                    }
                }
            }
            if n >= 4 { marks += 1 }
        }
        return (bandPx, residue, marks)
    }

    /// The synthetic spreads with a comb or spiral binding (all of them, six books),
    /// each leaf through `PDFExporter.finished` in Black and white and Color, its comb
    /// residue (the drawn binding marks grown by 6 px) and glyphs lost.
    static func combSynthetic() -> [String: Any] {
        var totals: [String: CombTally] = ["bw": CombTally(), "color": CombTally()]
        var leaves = 0
        for b in 0..<6 {
            for spec in HCSynth.book(b, pages: 52).specs where spec.isSpread && spec.binding != nil {
                let s = scaled(spec, scale)
                guard let bind = s.binding, let scanImage = HCSynth.render(s, .scan) else { continue }
                let scan = HillClimb.gray(scanImage)
                let masks = s.leaves.indices.compactMap { HCSynth.render(s, .print($0)).map(HillClimb.gray) }
                guard masks.count == s.leaves.count else { continue }
                var rects: [CGRect] = []
                var y = s.paperRows.lowerBound + 14
                while y < s.paperRows.upperBound - 14 {
                    rects.append(CGRect(x: bind.x - bind.size / 2, y: y, width: bind.size,
                                        height: bind.spiral ? bind.size : bind.size * 1.8))
                    y += bind.pitch
                }
                for (k, leaf) in s.leaves.enumerated() {
                    let x0 = max(0, Int(leaf.paper.minX.rounded())), x1 = min(s.W, Int(leaf.paper.maxX.rounded()))
                    let y0 = max(0, Int(s.paperRows.lowerBound.rounded())), y1 = min(s.H, Int(s.paperRows.upperBound.rounded()))
                    let w = x1 - x0, h = y1 - y0
                    guard w > 10, h > 10 else { continue }
                    var band = [Bool](repeating: false, count: w * h)
                    for r in rects {
                        let g = r.offsetBy(dx: -CGFloat(x0), dy: -CGFloat(y0)).insetBy(dx: -6, dy: -6)
                        let ya = max(0, Int(g.minY)), yb = min(h, Int(g.maxY.rounded(.up)))
                        let xa = max(0, Int(g.minX)), xb = min(w, Int(g.maxX.rounded(.up)))
                        guard ya < yb, xa < xb else { continue }
                        for yy in ya..<yb { for xx in xa..<xb { band[yy * w + xx] = true } }
                    }
                    guard band.contains(true) else { continue }
                    leaves += 1
                    var g = [UInt8](repeating: 255, count: w * h), m = g
                    for yy in 0..<h {
                        for xx in 0..<w { g[yy * w + xx] = scan[(yy + y0) * s.W + xx + x0]; m[yy * w + xx] = masks[k][(yy + y0) * s.W + xx + x0] }
                    }
                    guard let image = BlackAndWhite.image(g, width: w, height: h) else { continue }
                    let near = LayeredScan.minFilter(m.map { $0 < 250 ? 0 : 255 }, w, h, radius: 2).map { $0 == 0 }
                    for (mode, enhance) in [("bw", EnhanceMode.blackAndWhite), ("color", EnhanceMode.color)] {
                        var settings = PDFExporter.Settings()
                        settings.enhanceMode = enhance
                        settings.removeShadows = removeOn
                        let out = BlackAndWhite.grayPixels(PDFExporter.finished(image, dpi: synthDPI, settings: settings))
                        var ref: [UInt8]?
                        if removeOn {
                            settings.removeShadows = false
                            ref = BlackAndWhite.grayPixels(PDFExporter.finished(image, dpi: synthDPI, settings: settings))
                        }
                        var sample: [Int] = []
                        for i in stride(from: 0, to: w * h, by: 5) where !near[i] && !band[i] { sample.append(Int(out[i])) }
                        sample.sort()
                        let paper = sample.isEmpty ? 255 : sample[sample.count / 2]
                        let (bandPx, residue, marks) = combResidue(band: band, keep: near, w: w, h: h) { i in
                            mode == "bw" ? out[i] < 128 : abs(Int(out[i]) - paper) >= 30
                        }
                        let t = tally(out: out, ref: ref, mask: m, w: w, h: h, foldRight: k == 0, bw: mode == "bw")
                        if HillClimb.env["HILLCLIMB_SHADOW_TRIAGE"] != nil, let ref,
                           let refImage = BlackAndWhite.image(ref, width: w, height: h),
                           let outImage = BlackAndWhite.image(out, width: w, height: h) {
                            for b in t.newBoxes {
                                let bx = max(0, b.0 - 60), by = max(0, b.1 - 60)
                                let r = CGRect(x: bx, y: by, width: min(w, b.2 + 60) - bx, height: min(h, b.3 + 60) - by)
                                if let a = image.cropping(to: r), let c = refImage.cropping(to: r), let d = outImage.cropping(to: r) {
                                    triage.append([("comb b\(spec.book) i\(spec.index) leaf\(k) \(mode) scan", a), ("off", c), ("on", d)])
                                }
                            }
                        }
                        totals[mode]!.add(CombTally(bandPx: bandPx, residuePx: residue, marks: marks,
                                                    glyphsLost: t.glyphsLost, glyphsLostNew: t.glyphsLostNew))
                    }
                }
            }
        }
        print("SHADOW comb synthetic bw \(totals["bw"]!.json)")
        print("SHADOW comb synthetic color \(totals["color"]!.json)")
        return ["leaves": leaves, "bw": totals["bw"]!.json, "color": totals["color"]!.json]
    }

    /// Oesterle's comb-bound pages, exported in Color, Grayscale and Black and white,
    /// without and with the option. The teeth are found on the source (the Color export
    /// without the option), within 1.2 inch of the fold: groups of dark or strongly
    /// colored pixels (gray under 110, or channels 60 apart) of 200 px or more, at least
    /// 20 px each way and two-fifths solid. Their boxes grown by 12 px are the band.
    static let combCases: [(name: String, book: String, page: Int)] = [
        ("oesterle-p26", "Oesterle-1955", 26), ("oesterle-p50", "Oesterle-1955", 50), ("oesterle-p74", "Oesterle-1955", 74),
        ("oesterle-p82", "Oesterle-1955", 82), ("oesterle-p114", "Oesterle-1955", 114),
    ]

    static func teethBand(_ image: CGImage, side: Int) -> [Bool] {
        let w = image.width, h = image.height
        let px = HillClimb.rgbx(image)
        let reach = Int(1.2 * Double(w) / 5.5)      // about 1.2 inch on a 5.5-inch page
        var mark = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where side > 0 ? x >= w - reach : x < reach {
                let i = y * w + x
                let r = Int(px[4 * i]), g = Int(px[4 * i + 1]), b = Int(px[4 * i + 2])
                let lum = (r * 299 + g * 587 + b * 114) / 1000
                if lum < 110 || max(r, g, b) - min(r, g, b) > 60 { mark[i] = true }
            }
        }
        var band = [Bool](repeating: false, count: w * h)
        var seen = [Bool](repeating: false, count: w * h)
        for s in 0..<(w * h) where mark[s] && !seen[s] {
            seen[s] = true
            var stack = [s], n = 0, x0 = w, x1 = 0, y0 = h, y1 = 0
            while let k = stack.popLast() {
                n += 1
                let x = k % w, y = k / w
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) where mark[ny * w + nx] && !seen[ny * w + nx] {
                        seen[ny * w + nx] = true; stack.append(ny * w + nx)
                    }
                }
            }
            let bw = x1 - x0 + 1, bh = y1 - y0 + 1
            guard n >= 200, bw >= 20, bh >= 20, n * 5 >= bw * bh * 2 else { continue }
            for y in max(0, y0 - 12)...min(h - 1, y1 + 12) { for x in max(0, x0 - 12)...min(w - 1, x1 + 12) { band[y * w + x] = true } }
        }
        return band
    }

    static func combReal() async throws -> [String: Any] {
        var totals: [String: [String: CombTally]] = [:]
        var records: [[String: Any]] = []
        for c in combCases {
            guard let (m, url, page) = await loadCase(c) else { continue }
            var outputs: [String: [CGImage]] = [:]
            for (mode, enhance) in [("color", EnhanceMode.color), ("gray", EnhanceMode.grayscale), ("bw", EnhanceMode.blackAndWhite)] {
                for remove in [false, true] {
                    var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false,
                                                        reader: m.ocrReader, packs: m.ocrPacks, enhanceMode: enhance)
                    settings.matchScanResolution = m.matchScanResolution
                    settings.removeShadows = remove
                    outputs["\(mode)-\(remove ? "on" : "off")"] = try exported(page, from: url, settings: settings,
                                                                             name: "comb-\(c.name)-\(mode)-\(remove).pdf")
                }
            }
            guard let source = outputs["color-off"] else { continue }
            for k in source.indices {
                let side = source.count == 2 ? (k == 0 ? 1 : -1) : 1
                let band = teethBand(source[k], side: side)
                let w = source[k].width, h = source[k].height
                var noLosses: [[String: Any]] = []
                for mode in ["color", "gray", "bw"] {
                    for state in ["off", "on"] {
                        guard let im = outputs["\(mode)-\(state)"]?[k], im.width == w, im.height == h else { continue }
                        let rgb = HillClimb.rgbx(im), gray = HillClimb.gray(im)
                        // The page's paper: the upper quarter of the grays outside the band, and
                        // its hue (red less green, green less blue) there.
                        var sample: [Int] = [], rg: [Int] = [], gb: [Int] = []
                        for i in stride(from: 0, to: w * h, by: 7) where !band[i] { sample.append(Int(gray[i])) }
                        sample.sort()
                        let paper = sample.isEmpty ? 255 : sample[sample.count * 3 / 4]
                        for i in stride(from: 0, to: w * h, by: 7) where !band[i] && abs(Int(gray[i]) - paper) < 15 {
                            rg.append(Int(rgb[4 * i]) - Int(rgb[4 * i + 1])); gb.append(Int(rgb[4 * i + 1]) - Int(rgb[4 * i + 2]))
                        }
                        rg.sort(); gb.sort()
                        let prg = rg.isEmpty ? 0 : rg[rg.count / 2], pgb = gb.isEmpty ? 0 : gb[gb.count / 2]
                        let none = [Bool](repeating: false, count: w * h)
                        let (bandPx, residue, marks) = combResidue(band: band, keep: none, w: w, h: h) { i in
                            if mode == "bw" { return gray[i] < 128 }
                            let r = Int(rgb[4 * i]), g = Int(rgb[4 * i + 1]), b = Int(rgb[4 * i + 2])
                            return abs(Int(gray[i]) - paper) >= 30 || abs((r - g) - prg) > 30 || abs((g - b) - pgb) > 30
                        }
                        var t = CombTally(bandPx: bandPx, residuePx: residue, marks: marks)
                        if state == "on", let before = outputs["\(mode)-off"]?[k] {
                            let r = realTally(before: before, after: im, side: side, losses: &noLosses, name: "\(c.name)-\(mode)-\(k + 1)")
                            t.lostInLines = r.lostInLines; t.lostAlone = r.lostAlone
                        }
                        totals["\(mode)-\(state)", default: [:]][c.name, default: CombTally()].add(t)
                        records.append(["case": c.name, "page": k + 1, "mode": mode, "state": state] .merging(t.json) { a, _ in a })
                    }
                }
            }
        }
        var summary: [String: Any] = [:]
        for (key, byCase) in totals {
            var all = CombTally()
            for (_, t) in byCase { all.add(t) }
            summary[key] = all.json
            print("SHADOW comb real \(key) \(all.json)")
        }
        return ["totals": summary, "pages": records]
    }

    // MARK: Real

    /// Name, book, 1-based source page.
    static let cases: [(name: String, book: String, page: Int)] = [
        ("smith-p1", "Smith-1950", 1), ("smith-p40", "Smith-1950", 40), ("smith-p58", "Smith-1950", 58),
        ("smith-p76", "Smith-1950", 76), ("riezler-p44", "Riezler-1940", 44), ("wallace-p20", "Wallace-1992", 20),
        ("cherniss-p131", "Cherniss-1935", 131), ("oesterle-p26", "Oesterle-1955", 26),
        ("oesterle-p74", "Oesterle-1955", 74), ("freudenthal-p13", "Freudenthal-1999", 13),
        ("freudenthal-p101", "Freudenthal-1999", 101),
    ]

    /// A PDF of `source`'s pages `first...last` (1-based), in scratch.
    static func subset(_ source: URL, _ first: Int, _ last: Int, named name: String) -> URL? {
        guard let src = PDFDocument(url: source) else { return nil }
        let out = PDFDocument()
        for (k, i) in (max(1, first)...min(src.pageCount, last)).enumerated() {
            guard let page = src.page(at: i - 1)?.copy() as? PDFPage else { return nil }
            out.insert(page, at: k)
        }
        let url = HillClimb.scratch.appendingPathComponent(name)
        return out.write(to: url) ? url : nil
    }

    /// Each case's book cut to the case's page and two either side, Auto-detected:
    /// the model, the cut PDF, and the case's page in it.
    static func loadCase(_ c: (name: String, book: String, page: Int)) async -> (AppModel, URL, BookPage)? {
        guard let book = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == c.book }),
              let url = subset(book, c.page - 2, c.page + 2, named: "shadow-\(c.name).pdf") else { return nil }
        let m = HillClimb.makeModel()
        await HillClimb.load(url, into: m)
        let index = c.page - max(1, c.page - 2)
        guard let page = m.pages.first(where: { $0.sourceIndex == index }) else { return nil }
        return (m, url, page)
    }

    /// The output pages of `page` exported with `settings`, each drawn at its own resolution.
    static func exported(_ page: BookPage, from url: URL, settings: PDFExporter.Settings, name: String) throws -> [CGImage] {
        let pdf = HillClimb.scratch.appendingPathComponent(name)
        let doc = try #require(AppModel.reopen(url, password: nil))
        _ = try PDFExporter.export(pages: [page], from: doc, to: pdf, settings: settings)
        let made = try #require(PDFDocument(url: pdf))
        var out: [CGImage] = []
        for k in 0..<made.pageCount {
            let p = try #require(made.page(at: k))
            let image = try #require(PDFRenderer.drawnContent(p.pageRef!)?.images.first)
            let dpi = Double(image.pixelWidth) / (p.bounds(for: .mediaBox).width / 72)
            out.append(try #require(PDFRenderer.renderCGImage(page: p, dpi: dpi)))
        }
        return out
    }

    /// Glyphs with a row neighbour (overlapping half the shorter height, no further off than the
    /// taller is tall) that isn't thin (a third as wide as tall): pieces of the page stack's
    /// stripes side by side are not a line.
    static func inLines(_ gs: [HCGlyph]) -> [Bool] {
        func thin(_ g: HCGlyph) -> Bool { 3 * (g.x1 - g.x0 + 1) < g.y1 - g.y0 + 1 }
        let byX = gs.indices.sorted { gs[$0].x0 < gs[$1].x0 }
        let maxH = gs.map { $0.y1 - $0.y0 + 1 }.max() ?? 0
        var mate = [Bool](repeating: false, count: gs.count)
        for (k, i) in byX.enumerated() {
            let a = gs[i]
            var m = k + 1
            while m < byX.count, gs[byX[m]].x0 <= a.x1 + 1 + maxH {
                let j = byX[m], b = gs[j]
                m += 1
                let ha = a.y1 - a.y0 + 1, hb = b.y1 - b.y0 + 1
                let overlap = min(a.y1, b.y1) - max(a.y0, b.y0) + 1
                let gap = max(0, b.x0 - a.x1 - 1)
                if 2 * overlap >= min(ha, hb), gap <= max(ha, hb) {
                    if !thin(b) { mate[i] = true }
                    if !thin(a) { mate[j] = true }
                }
            }
        }
        return mate
    }

    struct RealTally {
        var zonePx = 0, residuePx = 0, marks = 0, glyphs = 0, lostInLines = 0, lostAlone = 0
        mutating func add(_ o: RealTally) {
            zonePx += o.zonePx; residuePx += o.residuePx; marks += o.marks; glyphs += o.glyphs
            lostInLines += o.lostInLines; lostAlone += o.lostAlone
        }
        var json: [String: Any] {
            ["residue": HillClimb.r(Double(residuePx) / Double(max(1, zonePx)), 6), "residuePx": residuePx,
             "marks": marks, "glyphs": glyphs, "lostInLines": lostInLines, "lostAlone": lostAlone]
        }
    }

    /// Score `after` against `before` (the same page without the option). `sides`: 1 the
    /// right, -1 the left, 0 both.
    static func realTally(before: CGImage, after: CGImage, side: Int, losses: inout [[String: Any]],
                          name: String) -> RealTally {
        var t = RealTally()
        let w = min(before.width, after.width), h = min(before.height, after.height)
        let b0 = HillClimb.gray(before), a0 = HillClimb.gray(after)
        var b = [UInt8](repeating: 255, count: w * h), a = b
        for y in 0..<h { for x in 0..<w { b[y * w + x] = b0[y * before.width + x]; a[y * w + x] = a0[y * after.width + x] } }
        let cut = HCGlyphDetector.otsu(b)
        let gb = HCGlyphDetector.withoutVerticalMarks(HCGlyphDetector.glyphs(b, width: w, height: h), gray: b, width: w, height: h)
        let lineB = inLines(gb)
        t.glyphs = gb.count
        func dark(_ p: [UInt8], _ g: HCGlyph) -> Int {
            var n = 0
            for y in g.y0...g.y1 { for x in g.x0...g.x1 where Int(p[y * w + x]) <= cut { n += 1 } }
            return n
        }
        for (i, g) in gb.enumerated() {
            let was = dark(b, g), now = dark(a, g)
            guard was > 0, now * 10 < was * 3 else { continue }
            if lineB[i] { t.lostInLines += 1 } else { t.lostAlone += 1 }
            if losses.count < 400 { losses.append(["page": name, "box": [g.x0, g.y0, g.x1, g.y1], "inLine": lineB[i]]) }
            if HillClimb.env["HILLCLIMB_SHADOW_TRIAGE"] != nil, lineB[i] || HillClimb.env["HILLCLIMB_SHADOW_TRIAGE_ALL"] != nil {
                let pad = 2 * (g.y1 - g.y0 + 1) + 20
                let x0 = max(0, g.x0 - pad), y0 = max(0, g.y0 - pad)
                let r = CGRect(x: x0, y: y0, width: min(w, g.x1 + pad) - x0, height: min(h, g.y1 + pad) - y0)
                if let pb = before.cropping(to: r), let pa = after.cropping(to: r) {
                    triage.append([("\(name) \(lineB[i] ? "LINE" : "alone") \(g.x0),\(g.y0)", pb), ("after", pa)])
                }
            }
        }
        // The text block's edges, from lines of 5 glyphs or more.
        let ga = HCGlyphDetector.withoutVerticalMarks(HCGlyphDetector.glyphs(a, width: w, height: h), gray: a, width: w, height: h)
        let lineA = inLines(ga)
        var lefts: [Int] = [], rights: [Int] = []
        do {
            // Chain glyphs in lines into rows by their middle, coarse: bins of the middle glyph height.
            let hs = gb.map { $0.y1 - $0.y0 + 1 }.sorted()
            let mh = hs.isEmpty ? 20 : hs[hs.count / 2]
            var rows = [Int: [HCGlyph]]()
            for (i, g) in gb.enumerated() where lineB[i] { rows[(g.y1) / max(1, mh), default: []].append(g) }
            for (_, gs) in rows where gs.count >= 5 {
                lefts.append(gs.map(\.x0).min()!); rights.append(gs.map(\.x1).max()!)
            }
            lefts.sort(); rights.sort()
            guard !lefts.isEmpty else { return t }
            let left = lefts[lefts.count / 20], right = rights[rights.count - 1 - rights.count / 20]
            let pad = Int(0.6 * Double(mh))
            func inZone(_ x: Int) -> Bool { (side >= 0 && x > right + pad) || (side <= 0 && x < left - pad) }
            var isPrint = [Bool](repeating: false, count: w * h)
            for (list, line) in [(gb, lineB), (ga, lineA)] {
                for (i, g) in list.enumerated() where line[i] {
                    for y in g.y0...g.y1 { for x in g.x0...g.x1 { isPrint[y * w + x] = true } }
                }
            }
            var marked = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w where inZone(x) {
                    t.zonePx += 1
                    let i = y * w + x
                    if Int(a[i]) <= cut && !isPrint[i] { t.residuePx += 1; marked[i] = true }
                }
            }
            var seen = [Bool](repeating: false, count: w * h)
            var stack: [Int] = []
            for s in 0..<(w * h) where marked[s] && !seen[s] {
                seen[s] = true; stack = [s]
                var n = 0
                while let k = stack.popLast() {
                    n += 1
                    let x = k % w, y = k / w
                    for ny in max(0, y - 1)...min(h - 1, y + 1) {
                        for nx in max(0, x - 1)...min(w - 1, x + 1) where marked[ny * w + nx] && !seen[ny * w + nx] {
                            seen[ny * w + nx] = true; stack.append(ny * w + nx)
                        }
                    }
                }
                if n >= 4 { t.marks += 1 }
            }
        }
        return t
    }

    /// HILLCLIMB_SHADOW_TRIAGE=<folder>: each lost glyph before and after, for checking by eye.
    nonisolated(unsafe) static var triage: [[(String, CGImage)]] = []

    static func real() async throws -> [String: Any] {
        var totals: [String: RealTally] = ["bw": RealTally(), "color": RealTally()]
        var records: [[String: Any]] = []
        var losses: [[String: Any]] = []
        for c in cases {
            guard let (m, url, page) = await loadCase(c) else {
                records.append(["case": c.name, "error": "not loaded"]); continue
            }
            for (mode, enhance) in [("bw", EnhanceMode.blackAndWhite), ("color", EnhanceMode.color)] {
                var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false,
                                                    reader: m.ocrReader, packs: m.ocrPacks, enhanceMode: enhance)
                settings.matchScanResolution = m.matchScanResolution
                let off = try exported(page, from: url, settings: settings, name: "shadow-\(c.name)-\(mode)-off.pdf")
                var after = off
                if removeOn {
                    settings.removeShadows = true
                    after = try exported(page, from: url, settings: settings, name: "shadow-\(c.name)-\(mode)-on.pdf")
                }
                for (k, (b, a)) in zip(off, after).enumerated() {
                    let side = off.count == 2 ? (k == 0 ? 1 : -1) : 0
                    let t = realTally(before: b, after: a, side: side, losses: &losses, name: "\(c.name)-\(mode)-\(k + 1)")
                    totals[mode]!.add(t)
                    var r = t.json
                    r["case"] = c.name; r["mode"] = mode; r["page"] = k + 1
                    records.append(r)
                }
            }
        }
        print("SHADOW real bw \(totals["bw"]!.json)")
        print("SHADOW real color \(totals["color"]!.json)")
        return ["bw": totals["bw"]!.json, "color": totals["color"]!.json, "pages": records, "losses": losses]
    }

    // MARK: Whole books

    /// The print-loss gate over every output page of every corpus book (HILLCLIMB_SHADOW_BOOKS=
    /// Book,Book to run fewer, in that order; HILLCLIMB_SHADOW_JOBS pages judged at once, for a
    /// busy or small machine: Cherniss's pages are drawn 5,000 px wide). The `real` cases above are eleven chosen fold pages, and their
    /// hard gate counts only glyphs with a row neighbour, so a column of page numbers on a
    /// contents page (Wallace p3), alone on its rows, was never looked at.
    ///
    /// Each output page is made as the export makes it, without and with the option, in Black
    /// and white (`bw`) and in Color (`color`: a pixel of the page with the option is kept
    /// when still darker than its paper by 25, or no more than 20 lighter than the scan, as
    /// faint print left alone is; a page kept as a picture in Black and white is this too).
    /// Every mark of the page in Black and white without the
    /// option (8-connected ink at least a full stop in size, at most 0.5 inch each way) that
    /// keeps under 30% of its pixels with it is lost. The text height `t` is the page's own
    /// (`ShadowRemoval.textLines`, else 0.06 inch). Lost marks are sorted by shape and place
    /// only, never by where the text block is:
    /// * `side`: within 0.02 inch of the crop's left or right side (a stripe, a band's rim);
    /// * `stripe`: thin (three times as tall as wide) and one of three or more lost thin
    ///   marks in a column (within 0.03 inch) spanning 0.5 inch or more: the page stack's edge;
    /// * `shadow`: on shadowed paper (the paper map under it below the page's clean level);
    /// * `dot`: under 0.4 `t` tall (a full stop, an i's dot, a speck);
    /// * `letter`: the rest, letter-sized (0.4 to 2.5 `t` tall), on clean paper, away from the
    ///   sides: the gate. `large`: taller or wider (rules, figures, bands), listed.
    /// HILLCLIMB_SHADOW_TRIAGE=<folder> draws each lost letter, dot and large mark before and
    /// after (`pages-<book>-<n>.png`), to judge by eye.
    static func pages() async throws -> [String: Any] {
        let urls = HillClimb.bookURLs()
        let chosen = HillClimb.env["HILLCLIMB_SHADOW_BOOKS"].map { list in
            list.split(separator: ",").compactMap { b in urls.first { HillClimb.shortName($0) == String(b) } }
        } ?? urls
        var books: [[String: Any]] = []
        var all: [String: Int] = [:]
        for url in chosen {
            let name = HillClimb.shortName(url)
            let m = HillClimb.makeModel()
            await HillClimb.load(url, into: m)
            guard let doc = AppModel.reopen(url, password: nil) else { books.append(["book": name, "error": "not opened"]); continue }
            var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false, enhanceMode: .blackAndWhite)
            settings.matchScanResolution = m.matchScanResolution
            var totals: [String: Int] = [:], listed: [[String: Any]] = []
            var sheet: [[(String, CGImage)]] = [], sheets = 0
            func flush() {
                guard let dir = HillClimb.env["HILLCLIMB_SHADOW_TRIAGE"], !sheet.isEmpty else { return }
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if let im = BWShowTests.grid(sheet, height: nil) {
                    HillClimb.png(im, to: URL(fileURLWithPath: dir).appendingPathComponent("pages-\(name)-\(sheets).png"))
                }
                sheet = []; sheets += 1
            }
            // Pages drawn one at a time, then judged several at once.
            let batch = Int(HillClimb.env["HILLCLIMB_SHADOW_JOBS"] ?? "") ?? max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
            for start in stride(from: 0, to: m.pages.count, by: batch) {
              let chunk = Array(m.pages[start..<min(m.pages.count, start + batch)])
              let drawnPages = chunk.map { page in
                  autoreleasepool { doc.page(at: page.sourceIndex).map { drawn(page, $0, settings: settings) } ?? Drawn() }
              }
              var judged = [[(BWPair, [(kind: String, box: HCGlyph)])]](repeating: [], count: chunk.count)
              judged.withUnsafeMutableBufferPointer { buf in
                  DispatchQueue.concurrentPerform(iterations: chunk.count) { i in
                      buf[i] = pairs(drawnPages[i]).map { p in (p, lostMarks(p.off, p.on, p.paper, p.w, p.h, dpi: p.dpi)) }
                  }
              }
              for (page, results) in zip(chunk, judged) {
                let spread = page.outputCrops(direction: settings.direction).count > 1
                for (p, lost) in results {
                    let tag = "\(name) p\(page.sourceIndex + 1)" + (spread ? (p.k == 0 ? "L" : "R") : "") + " \(p.mode)"
                    var count: [String: Int] = [:]
                    for l in lost { count[l.kind, default: 0] += 1 }
                    for (kind, n) in count { totals["\(p.mode) \(kind)", default: 0] += n; all["\(p.mode) \(kind)", default: 0] += n }
                    totals["\(p.mode) pages", default: 0] += 1
                    let shown = lost.filter { ["letter", "dot", "large"].contains($0.kind) }
                    guard !shown.isEmpty else { continue }
                    print("SHADOWPAGE \(tag): \(count.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
                    listed.append(["page": tag, "mode": p.mode, "lost": count])
                    guard HillClimb.env["HILLCLIMB_SHADOW_TRIAGE"] != nil else { continue }
                    for l in shown.prefix(16) {
                        let pad = Int(0.25 * p.dpi)
                        let x0 = max(0, l.box.x0 - pad), y0 = max(0, l.box.y0 - pad)
                        let x1 = min(p.w - 1, l.box.x1 + pad), y1 = min(p.h - 1, l.box.y1 + pad)
                        func cut(_ px: [UInt8]) -> CGImage? {
                            var c = [UInt8](repeating: 255, count: (x1 - x0 + 1) * (y1 - y0 + 1))
                            for y in y0...y1 { for x in x0...x1 { c[(y - y0) * (x1 - x0 + 1) + x - x0] = px[y * p.w + x] } }
                            return BlackAndWhite.image(c, width: x1 - x0 + 1, height: y1 - y0 + 1)
                        }
                        if let b = cut(p.off), let a = cut(p.on) {
                            sheet.append([("\(tag) \(l.kind) \(l.box.x0),\(l.box.y0) off", b), ("on", a)])
                            if sheet.count == 24 { flush() }
                        }
                    }
                }
              }
              print("SHADOWPROGRESS \(name) \(min(m.pages.count, start + batch)) of \(m.pages.count)")
            }
            flush()
            print("SHADOWBOOK \(name) \(totals.sorted { $0.key < $1.key })")
            books.append(["book": name, "totals": totals, "pages": listed])
        }
        print("SHADOWPAGES all \(all.sorted { $0.key < $1.key })")
        return ["all": all, "books": books]
    }

    /// One output page without and with Remove shadows in one mode: `off` is its Black and white
    /// without the option (0 ink, 255 paper), `on` the same page with it, as ink (`bw`) or, for
    /// the Color export, its pixels still darker than its paper by 25 or no more than 20 lighter than the scan (`color`).
    struct BWPair { var mode: String, k: Int, off: [UInt8], on: [UInt8], paper: [UInt8], w: Int, h: Int, dpi: Double }

    /// The page's output pages made as `PDFExporter.export` makes them, in Black and white and in
    /// Color: a layered page's Color with the option is its Black and white, so only that; a page
    /// kept as a picture in Black and white is its Color export, so only that.
    /// What `pairs` needs of a page, drawn (PDFKit draws one page at a time): a layered page's
    /// pairs made already, or a plain page's output images at `dpi` and, for a turned page under
    /// 250 DPI, at twice that (`fine`).
    struct Drawn { var made: [BWPair] = [], images: [CGImage] = [], dpi = 0.0, fine: [CGImage]? = nil, fineDPI = 0.0 }

    static func bwPairs(_ page: BookPage, _ pdfPage: PDFPage, settings: PDFExporter.Settings) -> [BWPair] {
        pairs(drawn(page, pdfPage, settings: settings))
    }

    /// Color with the option against Black and white without it, both from `image` at `d`.
    static func colorPair(_ k: Int, _ image: CGImage, _ d: Double) -> BWPair? {
        let p = BlackAndWhite.prepare(image, dpi: d)
        let off = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: BlackAndWhite.holdsTones(p.gray, width: p.width, height: p.height),
                                    width: p.width, height: p.height, dpi: d, paper: p.paper)
        guard let made = ShadowRemoval.page(image, dpi: d) else { return nil }
        let g = BlackAndWhite.grayPixels(made)
        var counts = [Int](repeating: 0, count: 256), n = 0
        for i in stride(from: 0, to: g.count, by: 5) where off[i] != 0 { counts[Int(g[i])] += 1; n += 1 }
        var seen = 0, paperOut = 255
        for v in 0..<256 { seen += counts[v]; if seen * 2 >= n { paperOut = v; break } }
        return BWPair(mode: "color", k: k, off: off, on: g.indices.map { i in Int(g[i]) <= paperOut - 25 || Int(g[i]) <= Int(p.gray[i]) + 20 ? 0 : 255 }, paper: p.paper,
                      w: p.width, h: p.height, dpi: d)
    }

    static func drawn(_ page: BookPage, _ pdfPage: PDFPage, settings: PDFExporter.Settings) -> Drawn {
        let dpi = PDFExporter.renderDPI(of: pdfPage, settings: settings)
        var color = settings; color.enhanceMode = .color
        func rendered(_ d: Double) -> [CGImage]? {
            guard let r = PDFRenderer.renderCGImage(page: pdfPage, dpi: d) else { return nil }
            return PDFExporter.outputImages(of: page, rendered: r, settings: color)
        }
        var out: [BWPair] = []
        if let layers = LayeredScan.layers(of: pdfPage) {
            guard let off = LayeredScan.textPages(of: page, pdfPage, layers: layers, direction: settings.direction,
                                                  bothLayers: true, removeShadows: false),
                  let on = LayeredScan.textPages(of: page, pdfPage, layers: layers, direction: settings.direction,
                                                 bothLayers: true, removeShadows: true) else { return Drawn() }
            let images = off.contains(where: { $0 == nil }) ? rendered(dpi) : nil
            for (k, (o, n)) in zip(off, on).enumerated() {
                if let o, let n {
                    let a = BlackAndWhite.grayPixels(o)
                    out.append(BWPair(mode: "bw", k: k, off: a, on: BlackAndWhite.grayPixels(n),
                                      paper: [UInt8](repeating: 255, count: a.count), w: o.width, h: o.height,
                                      dpi: LayeredScan.textDPI(layers)))
                } else if let images, k < images.count, let c = colorPair(k, images[k], dpi) {
                    out.append(c)
                }
            }
            return Drawn(made: out)
        }
        guard let images = rendered(dpi) else { return Drawn() }
        var bw = settings; bw.enhanceMode = .blackAndWhite
        let fineDPI = PDFExporter.fineDPI(page, pdfPage, dpi: dpi, settings: bw)
        return Drawn(images: images, dpi: dpi, fine: fineDPI.flatMap(rendered), fineDPI: fineDPI ?? dpi)
    }

    /// `drawn`'s pairs; safe to run on several pages at once.
    static func pairs(_ d: Drawn) -> [BWPair] {
        var out = d.made
        let images = d.images, dpi = d.dpi, fineDPI = d.fineDPI
        let prepared = images.map { BlackAndWhite.prepare($0, dpi: dpi) }
        // Black and white of a turned page may be made finer (PDFExporter.fineDPI), unless a page holds a picture.
        var fine: [BlackAndWhite.Prepared]?
        if let f = d.fine {
            let p = f.map { BlackAndWhite.prepare($0, dpi: fineDPI) }
            if !p.contains(where: \.picture) { fine = p }
        }
        for (k, image) in images.enumerated() {
            if let c = colorPair(k, image, dpi) { out.append(c) }
            let (p, d) = fine.map { ($0[k], fineDPI) } ?? (prepared[k], dpi)
            guard !p.picture else { continue }
            let tone = BlackAndWhite.holdsTones(p.gray, width: p.width, height: p.height)
            func ink(_ remove: Bool) -> [UInt8] {
                BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: tone, width: p.width, height: p.height, dpi: d,
                                  removeShadows: remove, paper: p.paper)
            }
            out.append(BWPair(mode: "bw", k: k, off: ink(false), on: ink(true), paper: p.paper, w: p.width, h: p.height, dpi: d))
        }
        return out
    }

    /// The marks of `off` that `on` loses (see `pages`), each with its kind.
    static func lostMarks(_ off: [UInt8], _ on: [UInt8], _ paper: [UInt8], _ w: Int, _ h: Int, dpi: Double)
        -> [(kind: String, box: HCGlyph)] {
        let cc = ShadowRemoval.Components(off, w, h)
        let blobs = cc.blobs
        let t = ShadowRemoval.textLines(blobs, dpi: dpi)?.t ?? 0.06 * dpi
        let minGlyph = max(4, Int((0.012 * dpi * 0.012 * dpi).rounded()))
        let clean = BlackAndWhite.cleanLevel(paper)
        let side = max(2, Int((0.02 * dpi).rounded())), most = Int(0.5 * dpi)
        var lost: [(k: Int, kind: String)] = []
        for (k, b) in blobs.enumerated() where b.count >= minGlyph && b.width <= most && b.height <= most {
            let gone = cc.count(k, where: { on[$0] != 0 })
            guard gone * 10 > b.count * 7 else { continue }
            let mid = ((b.minY + b.maxY) / 2) * w + (b.minX + b.maxX) / 2
            let kind: String
            if b.minX <= side || b.maxX >= w - 1 - side { kind = "side" }
            else if Int(paper[mid]) < clean { kind = "shadow" }
            else if Double(b.height) < 0.4 * t { kind = "dot" }
            else if Double(b.height) > 2.5 * t || Double(b.width) > 3 * t { kind = "large" }
            else { kind = "letter" }
            lost.append((k, kind))
        }
        // The page stack's edge: thin lost marks three or more to a column, over half an inch.
        let thin = lost.filter { let b = blobs[$0.k]; return b.height >= 3 * b.width && $0.kind != "side" }
        let col = max(1, Int((0.03 * dpi).rounded()))
        var stripe = Set<Int>()
        for a in thin {
            let ax = (blobs[a.k].minX + blobs[a.k].maxX) / 2
            let mates = thin.filter { abs((blobs[$0.k].minX + blobs[$0.k].maxX) / 2 - ax) <= col }
            let lo = mates.map { blobs[$0.k].minY }.min()!, hi = mates.map { blobs[$0.k].maxY }.max()!
            if mates.count >= 3, Double(hi - lo) >= 0.5 * dpi { stripe.insert(a.k) }
        }
        return lost.map { l in
            let b = blobs[l.k]
            return (stripe.contains(l.k) ? "stripe" : l.kind, HCGlyph(x0: b.minX, y0: b.minY, x1: b.maxX, y1: b.maxY))
        }
    }
}
