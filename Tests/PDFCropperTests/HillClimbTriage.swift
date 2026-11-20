import Testing
import Foundation
import AppKit
import PDFKit
@testable import PDFCropper

/// Close-ups of the glyphs the split and crop proxies count, to look at by eye.
///
/// Runs only when HILLCLIMB_TRIAGE is set. Reads a past run's split-pages.json
/// (results/$HILLCLIMB_TRIAGE_FROM) and, for the pages it names, draws the analysis-DPI
/// render with the glyph finder's boxes: red for a glyph the split or a crop edge runs
/// through, green for the rest, a magenta cross on a vertical-mark piece the counts leave
/// out; the split or crop edge in blue. Full height, in two halves side by side, 2x.
/// HILLCLIMB_TRIAGE: comma list of page ids, or "split:N" / "crop:N" for the N real pages
/// with the highest count; HILLCLIMB_TRIAGE_FULL=1 adds the whole straightened page with
/// the crop boxes. Output: $HILLCLIMB_TRIAGE_OUT, with triage.txt (per page: glyphs cut,
/// how many are not marks, each piece's box; crop cuts are summed per box, so a glyph
/// across both boxes counts twice there).
@Suite("HillClimb triage", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HILLCLIMB_TRIAGE"] != nil))
@MainActor
struct HillClimbTriageTests {

    @Test("Draw counted glyphs about the split and the cut crop edges")
    func triage() throws {
        let env = HillClimb.env
        guard env["HILLCLIMB_TRIAGE"] != "synth" else { return }
        let from = HillClimb.dir.appendingPathComponent("results/\(env["HILLCLIMB_TRIAGE_FROM"] ?? "split-r1b")/split-pages.json")
        let out = URL(fileURLWithPath: env["HILLCLIMB_TRIAGE_OUT"] ?? NSTemporaryDirectory() + "hc-triage", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let data = try Data(contentsOf: from)
        let all = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["pages"] as? [[String: Any]] ?? [])
            .filter { $0["kind"] as? String == "real" }
        var wanted: [[String: Any]] = []
        for item in (env["HILLCLIMB_TRIAGE"] ?? "").split(separator: ",").map(String.init) {
            let parts = item.split(separator: ":").map(String.init)
            if parts.count == 2, let n = Int(parts[1]), parts[0] == "split" || parts[0] == "crop" {
                let key = parts[0] == "split" ? "splitCutsGlyphs" : "cropCutsGlyphs"
                wanted += all.filter { ($0[key] as? Int ?? 0) > 0 }
                    .sorted { ($0[key] as? Int ?? 0) > ($1[key] as? Int ?? 0) }.prefix(n)
            } else {
                wanted += all.filter { $0["id"] as? String == item }
            }
        }
        var seen = Set<String>()
        wanted = wanted.filter { seen.insert($0["id"] as? String ?? "").inserted }
        var log = ""
        var docs: [String: PDFDocument] = [:]
        for rec in wanted {
            guard let id = rec["id"] as? String, let book = rec["book"] as? String, let n = rec["page"] as? Int else { continue }
            let doc = docs[book] ?? PDFDocument(url: HillClimb.dir.appendingPathComponent(book))
            docs[book] = doc
            guard let pdfPage = doc?.page(at: n) else { continue }
            autoreleasepool {
                log += draw(rec, id: id, page: pdfPage, out: out)
            }
        }
        try log.write(to: out.appendingPathComponent("triage.txt"), atomically: true, encoding: .utf8)
        #expect(!wanted.isEmpty)
    }

    /// HILLCLIMB_TRIAGE=synth: on every synthetic page, how many glyph-finder pieces the
    /// vertical-mark rule leaves out, and how many of those touch drawn print (should be none).
    @Test("Vertical marks against synthetic print")
    func marksOnSyntheticPrint() {
        guard HillClimb.env["HILLCLIMB_TRIAGE"] == "synth" else { return }
        var pieces = 0, marks = 0, onPrint = 0, printGlyphs = 0, printGlyphsMarked = 0
        var report = ""
        let out = URL(fileURLWithPath: HillClimb.env["HILLCLIMB_TRIAGE_OUT"] ?? NSTemporaryDirectory() + "hc-triage", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for b in 1...HillClimbSplitTests.syntheticBooks {
            let book = HCSynth.book(b, pages: HillClimbSplitTests.pagesPerBook)
            for (i, s) in book.specs.enumerated() {
                autoreleasepool {
                    guard let scan = HCSynth.render(s, .scan) else { return }
                    let g = HillClimb.gray(scan)
                    let gs = HCGlyphDetector.glyphs(g, width: s.W, height: s.H)
                    let m = HCGlyphDetector.verticalMarks(gs, gray: g, width: s.W, height: s.H)
                    var ink = [Bool](repeating: false, count: s.W * s.H)
                    for k in s.leaves.indices where !s.leaves[k].items.isEmpty {
                        guard let mask = HCSynth.render(s, .print(k)) else { continue }
                        let p = HillClimb.gray(mask)
                        for j in 0..<p.count where p[j] < 100 { ink[j] = true }
                    }
                    func touches(_ q: HCGlyph) -> Bool {
                        for y in q.y0...q.y1 { for x in q.x0...q.x1 where ink[y * s.W + x] { return true } }
                        return false
                    }
                    pieces += gs.count; marks += m.count
                    for (j, q) in gs.enumerated() where touches(q) {
                        printGlyphs += 1
                        if m.contains(j) {
                            printGlyphsMarked += 1
                            report += "synth-\(b)-\(i) \(s.tags) mark on print x \(q.x0)-\(q.x1) y \(q.y0)-\(q.y1)\n"
                            let r = CGRect(x: max(0, q.x0 - 60), y: max(0, q.y0 - 60), width: 120, height: 120)
                                .intersection(CGRect(x: 0, y: 0, width: s.W, height: s.H))
                            save(scan, gray: g, region: r, glyphs: gs, cut: [q], marks: m.map { gs[$0] }, vline: nil, hline: nil,
                                 rects: [], scale: 4, to: out.appendingPathComponent("synth-\(b)-\(i)-\(q.y0).png"))
                        }
                    }
                    onPrint = printGlyphsMarked
                }
            }
        }
        report += "pieces \(pieces) marks \(marks) printGlyphs \(printGlyphs) marksOnPrint \(onPrint)\n"
        try? report.write(to: out.appendingPathComponent("synth-marks.txt"), atomically: true, encoding: .utf8)
        #expect(pieces > 0)
    }

    private func crop(_ v: Any?) -> CropRect? {
        guard let a = v as? [Double], a.count == 4 else { return nil }
        return CropRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }

    private func draw(_ rec: [String: Any], id: String, page: PDFPage, out: URL) -> String {
        let size = PDFRenderer.displaySize(of: page)
        let dpi = min(110.0, 1600.0 / Double(max(size.width, size.height)) * 72)
        guard let raw = PDFRenderer.renderCGImage(page: page, dpi: dpi) else { return "\(id): no render\n" }
        let spread = rec["cls"] as? String == "spread"
        let split = rec["split"] as? Double ?? 0.5
        let skew = rec["skew"] as? [Double] ?? [0, 0]
        let trim = crop(rec["trim"]) ?? .full
        let straight = ImageTransform.deskewedComposite(raw, splitX: split, leftDegrees: skew[0],
                                                        rightDegrees: skew[1], isSpread: spread)
        let w = raw.width, h = raw.height
        let sg = HillClimb.gray(straight)
        let straightGlyphs = HCGlyphDetector.glyphs(sg, width: w, height: h)
        let straightMarks = HCGlyphDetector.verticalMarks(straightGlyphs, gray: sg, width: w, height: h).map { straightGlyphs[$0] }
        var allMarks = 0, nearMarks = 0
        var line = "\(id) W=\(w) H=\(h) split=\(split) skew=\(skew)"
        if spread {
            let rg = HillClimb.gray(raw)
            let rawGlyphs = skew == [0, 0] ? straightGlyphs : HCGlyphDetector.glyphs(rg, width: w, height: h)
            let sp = max(1, min(w - 1, Int(split * Double(w))))
            let cut = rawGlyphs.filter { $0.x0 <= sp - 1 && $0.x1 >= sp }
            let marks = HCGlyphDetector.verticalMarks(rawGlyphs, gray: rg, width: w, height: h).map { rawGlyphs[$0] }
            allMarks = marks.count
            nearMarks = marks.filter { abs(($0.x0 + $0.x1) / 2 - sp) < Int(0.08 * Double(w)) }.count
            line += " splitCuts=\(cut.count)/rec \(rec["splitCutsGlyphs"] ?? "-") letters \(cut.filter { !marks.contains($0) }.count)"
            if !cut.isEmpty {
                let x0 = max(0, sp - Int(0.07 * Double(w))), x1 = min(w, sp + Int(0.07 * Double(w)))
                save(raw, gray: rg, region: CGRect(x: x0, y: 0, width: x1 - x0, height: h), glyphs: rawGlyphs, cut: cut,
                     marks: marks, vline: sp, hline: nil, to: out.appendingPathComponent("\(id)-split.png"))
                for g in cut { line += "\n   split glyph " + describe(g, rg, w) }
            }
        }
        var rects: [CropRect] = []
        if let l = crop(rec["left"]) { rects.append(l.normalized().kept(in: trim)) }
        if spread, let r = crop(rec["right"]) { rects.append(r.normalized().kept(in: trim)) }
        let px = rects.map { $0.normalized().pixelRect(in: CGSize(width: w, height: h)).integral }
        var total = 0, cropLetters = 0
        for (k, r) in px.enumerated() {
            let x0 = Int(r.minX), x1 = Int(r.maxX) - 1, y0 = Int(r.minY), y1 = Int(r.maxY) - 1
            let meets = straightGlyphs.filter { $0.x0 <= x1 && $0.x1 >= x0 && $0.y0 <= y1 && $0.y1 >= y0 }
            let cut = meets.filter { !($0.x0 >= x0 && $0.x1 <= x1 && $0.y0 >= y0 && $0.y1 <= y1) }
            total += cut.count
            cropLetters += cut.filter { !straightMarks.contains($0) }.count
            let edges: [(String, (HCGlyph) -> Bool)] = [
                ("L", { $0.x0 < x0 }), ("R", { $0.x1 > x1 }), ("T", { $0.y0 < y0 }), ("B", { $0.y1 > y1 })]
            for (name, test) in edges {
                let c = cut.filter(test)
                guard !c.isEmpty else { continue }
                let region: CGRect, v: Int?, hl: Int?
                switch name {
                case "L", "R":
                    let ex = name == "L" ? x0 : x1 + 1
                    let a = max(0, ex - Int(0.06 * Double(w))), b = min(w, ex + Int(0.06 * Double(w)))
                    region = CGRect(x: a, y: 0, width: b - a, height: h); v = ex; hl = nil
                default:
                    let ey = name == "T" ? y0 : y1 + 1
                    let a = max(0, ey - Int(0.05 * Double(h))), b = min(h, ey + Int(0.05 * Double(h)))
                    let xa = max(0, x0 - 20), xb = min(w, x1 + 20)
                    region = CGRect(x: xa, y: a, width: xb - xa, height: b - a); v = nil; hl = ey
                }
                save(straight, gray: sg, region: region, glyphs: straightGlyphs, cut: c, marks: straightMarks, vline: v, hline: hl,
                     to: out.appendingPathComponent("\(id)-crop\(k)\(name).png"))
                for g in c { line += "\n   crop\(k)\(name) glyph " + describe(g, sg, w) }
            }
        }
        line += " cropCuts=\(total)/rec \(rec["cropCutsGlyphs"] ?? "-") letters \(cropLetters) marks \(allMarks) nearFold \(nearMarks)"
        for g in straightMarks { line += "\n   MARK \(g.x0) \(g.x1) \(g.y0) \(g.y1)" }
        // HILLCLIMB_TRIAGE_FULL: also the whole straightened page, crop boxes in blue.
        if HillClimb.env["HILLCLIMB_TRIAGE_FULL"] != nil {
            let cut = straightGlyphs.filter { g in px.contains { r in
                let x0 = Int(r.minX), x1 = Int(r.maxX) - 1, y0 = Int(r.minY), y1 = Int(r.maxY) - 1
                return g.x0 <= x1 && g.x1 >= x0 && g.y0 <= y1 && g.y1 >= y0
                    && !(g.x0 >= x0 && g.x1 <= x1 && g.y0 >= y0 && g.y1 <= y1) } }
            save(straight, gray: sg, region: CGRect(x: 0, y: 0, width: w, height: h), glyphs: straightGlyphs, cut: cut,
                 marks: straightMarks, vline: nil, hline: nil, rects: px, scale: 1, to: out.appendingPathComponent("\(id)-full.png"))
        }
        return line + "\n"
    }

    /// Size, ink share of its box, and the gray of the paper around it.
    private func describe(_ g: HCGlyph, _ gray: [UInt8], _ w: Int) -> String {
        let t = HCGlyphDetector.otsu(gray)
        var ink = 0, area = 0, sum = 0
        for y in g.y0...g.y1 { for x in g.x0...g.x1 { area += 1; let v = Int(gray[y * w + x]); sum += v; if v <= t { ink += 1 } } }
        return "x \(g.x0)-\(g.x1) y \(g.y0)-\(g.y1) (\(g.x1 - g.x0 + 1)x\(g.y1 - g.y0 + 1)) fill \(ink * 100 / max(1, area))% mean \(sum / max(1, area)) otsu \(t)"
    }

    private func save(_ img: CGImage, gray: [UInt8], region: CGRect, glyphs: [HCGlyph], cut: [HCGlyph], marks: [HCGlyph] = [],
                      vline: Int?, hline: Int?, rects: [CGRect] = [], scale s: CGFloat = 2, to url: URL) {
        guard let sub = img.cropping(to: region) else { return }
        let rw = CGFloat(sub.width), rh = CGFloat(sub.height)
        // A tall strip goes in two halves side by side.
        let halves = rects.isEmpty && rh > rw * 1.5
        let panelH = halves ? ceil(rh / 2) : rh
        let cw = Int((halves ? rw * 2 + 8 : rw) * s), ch = Int(panelH * s)
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.interpolationQuality = .none
        for half in 0..<(halves ? 2 : 1) {
            ctx.saveGState()
            // Top-left origin, region pixel units, this half's slice.
            let ox = CGFloat(half) * (rw + 8)
            let oy = CGFloat(half) * panelH
            ctx.translateBy(x: ox * s, y: CGFloat(ch))
            ctx.scaleBy(x: s, y: -s)
            ctx.translateBy(x: -region.minX, y: -region.minY - oy)
            ctx.clip(to: CGRect(x: region.minX, y: region.minY + oy, width: rw, height: panelH))
            ctx.saveGState()
            ctx.translateBy(x: region.minX, y: region.minY + rh)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(sub, in: CGRect(x: 0, y: 0, width: rw, height: rh))
            ctx.restoreGState()
            ctx.setLineWidth(0.5)
            ctx.setStrokeColor(CGColor(red: 0, green: 0.7, blue: 0, alpha: 0.5))
            for g in glyphs where !cut.contains(g) {
                ctx.stroke(CGRect(x: g.x0, y: g.y0, width: g.x1 - g.x0 + 1, height: g.y1 - g.y0 + 1))
            }
            // Vertical-mark pieces (left out by the proxy): a magenta cross.
            ctx.setStrokeColor(CGColor(red: 0.9, green: 0, blue: 0.9, alpha: 0.9))
            for g in marks {
                ctx.strokeLineSegments(between: [CGPoint(x: g.x0, y: g.y0), CGPoint(x: g.x1 + 1, y: g.y1 + 1),
                                                 CGPoint(x: g.x1 + 1, y: g.y0), CGPoint(x: g.x0, y: g.y1 + 1)])
            }
            ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
            for g in cut {
                ctx.stroke(CGRect(x: CGFloat(g.x0) - 0.5, y: CGFloat(g.y0) - 0.5, width: CGFloat(g.x1 - g.x0) + 2, height: CGFloat(g.y1 - g.y0) + 2))
            }
            ctx.setStrokeColor(CGColor(red: 0, green: 0.3, blue: 1, alpha: 0.35))
            if let v = vline { ctx.stroke(CGRect(x: CGFloat(v), y: region.minY, width: 0, height: rh)) }
            if let hl = hline { ctx.stroke(CGRect(x: region.minX, y: CGFloat(hl), width: rw, height: 0)) }
            ctx.setStrokeColor(CGColor(red: 0, green: 0.3, blue: 1, alpha: 0.8))
            for r in rects { ctx.stroke(r) }
            ctx.restoreGState()
        }
        if let image = ctx.makeImage() { HillClimb.png(image, to: url) }
    }
}
