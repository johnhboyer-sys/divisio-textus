import Testing
import Foundation
import AppKit
import PDFKit
@testable import PDFCropper

/// Hill-climb score A: how well Auto-detect splits and crops.
///
/// Runs only when HILLCLIMB_DIR is set (see Tools/hillclimb/README.md). Writes
/// results/<label>/split.json (the summary) and split-pages.json (one record per
/// page, so two runs can be diffed). The numbers carry no pass/fail line: the
/// suite measures, and the asserts only check that the measuring ran.
@Suite("HillClimb split", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct HillClimbSplitTests {

    static let syntheticBooks = 6
    static let pagesPerBook = 52
    /// A book bigger than this is sampled (every `sampleStep`-th page).
    static let sampleBytes = 150_000_000
    static let sampleStep = 4

    @Test("Score splits and crops on synthetic pages and real books")
    func score() async {
        HillClimb.prepare()
        let t0 = HillClimb.now()
        var records: [[String: Any]] = []
        // HILLCLIMB_ONLY=synthetic or =real runs half the score, for quick checks while editing.
        let only = HillClimb.env["HILLCLIMB_ONLY"]
        let synthetic = only == "real" ? [:] : await scoreSynthetic(into: &records)
        let tSynth = HillClimb.now()
        let real = only == "synthetic" ? [:] : await scoreReal(into: &records)
        let t1 = HillClimb.now()

        HillClimb.write(["label": HillClimb.label, "synthetic": synthetic, "real": real,
                         "seconds": ["synthetic": HillClimb.r(tSynth - t0, 1), "real": HillClimb.r(t1 - tSynth, 1)]],
                        "split.json")
        HillClimb.write(["label": HillClimb.label, "pages": records], "split-pages.json")
        #expect(only == "real" || (synthetic["pages"] as? Int ?? 0) >= 300)
        #expect(!records.isEmpty)
    }

    // MARK: Synthetic

    private func rectList(_ c: CropRect) -> [Double] {
        [HillClimb.r(c.x, 6), HillClimb.r(c.y, 6), HillClimb.r(c.width, 6), HillClimb.r(c.height, 6)]
    }

    /// A crop as the exporter cuts it, in pixels, grown by `pad` so a rounding step is not a cut.
    private func pixelRect(_ c: CropRect, _ w: Int, _ h: Int, pad: Double = 0) -> CGRect {
        let r = c.normalized().pixelRect(in: CGSize(width: w, height: h)).integral
        return r.insetBy(dx: -pad, dy: -pad)
    }

    /// Scanner bed kept in a crop, at its left and right sides (`rows`: its top and
    /// foot), as shares of the crop's width (height): from each side inward, a light
    /// lead-in of at most 3% (the glass's white frame), then lines at least 80%
    /// darker than half the paper. Zero where no such band starts within the lead-in.
    private func bedShare(_ gray: [UInt8], _ w: Int, _ h: Int, _ r: CGRect, rows: Bool = false) -> [Double] {
        let x0 = max(0, Int(r.minX)), x1 = min(w, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(h, Int(r.maxY))
        guard x1 - x0 > 10, y1 - y0 > 10 else { return [0, 0] }
        var sample: [UInt8] = []
        for y in stride(from: y0, to: y1, by: 4) { for x in stride(from: x0, to: x1, by: 4) { sample.append(gray[y * w + x]) } }
        sample.sort()
        let dark = Int(sample[sample.count * 9 / 10]) / 2
        func band(_ i: Int) -> Bool {
            var d = 0
            if rows {
                for x in x0..<x1 where Int(gray[i * w + x]) < dark { d += 1 }
                return d * 5 >= (x1 - x0) * 4
            }
            for y in y0..<y1 where Int(gray[y * w + i]) < dark { d += 1 }
            return d * 5 >= (y1 - y0) * 4
        }
        let (lo, hi) = rows ? (y0, y1) : (x0, x1)
        let length = hi - lo, leadIn = max(1, length * 3 / 100)
        func side(_ start: Int, _ step: Int) -> Double {
            var i = start, k = 0
            while k <= leadIn && !band(i) { i += step; k += 1 }
            guard k <= leadIn else { return 0 }
            var gap = 0, last = k
            while k < length && gap <= 2 { if band(i) { last = k; gap = 0 } else { gap += 1 }; i += step; k += 1 }
            return HillClimb.r(Double(last + 1) / Double(length), 4)
        }
        return [side(lo, 1), side(hi - 1, -1)]
    }

    private func scoreSynthetic(into records: inout [[String: Any]]) async -> [String: Any] {
        try? FileManager.default.createDirectory(at: HillClimb.synth, withIntermediateDirectories: true)
        struct Row {
            var id: String, tags: [String]
            var cutPx: Int, splitInPrint: Bool
            var splitErr: Double?, classOK: Bool
            var slack: Double?, short: Double?
        }
        var rows: [Row] = []
        for b in 1...Self.syntheticBooks {
            let book = HCSynth.book(b, pages: Self.pagesPerBook)
            let url = HillClimb.synth.appendingPathComponent("synth-\(b).pdf")
            guard HCSynth.writePDF(book, to: url) else { continue }
            // HILLCLIMB_DUMP_SYNTH=<folder>: also save each page as PNG, with its print mask, to look at.
            if let dump = HillClimb.env["HILLCLIMB_DUMP_SYNTH"] {
                let d = URL(fileURLWithPath: dump, isDirectory: true)
                try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                for (i, s) in book.specs.enumerated() where i < 12 {
                    if let img = HCSynth.render(s, .scan) { HillClimb.png(img, to: d.appendingPathComponent("b\(b)-p\(i)-scan.png")) }
                    if let img = HCSynth.render(s, .print(0)) { HillClimb.png(img, to: d.appendingPathComponent("b\(b)-p\(i)-print0.png")) }
                }
            }
            let m = HillClimb.makeModel()
            await HillClimb.load(url, into: m)
            guard m.pages.count == book.specs.count else {
                Issue.record("synthetic book \(b): \(m.pages.count) pages loaded, \(book.specs.count) drawn")
                continue
            }
            for (i, s) in book.specs.enumerated() {
                let page = m.pages[i]
                var record: [String: Any] = [:]
                let row = autoreleasepool { () -> Row in
                    let W = s.W, H = s.H
                    let appSpread = page.classification == .spread
                    let crops = page.outputCrops(direction: .leftToRight)
                    let splitPx = max(1, min(W - 1, Int(page.splitX * Double(W))))
                    var cutPx = 0
                    var splitInPrint = false
                    var slackSum = 0.0, shortSum = 0.0, edges = 0
                    for (k, leaf) in s.leaves.enumerated() {
                        // Where this leaf's print may land: its own crop, on its own side of the split.
                        func allowed(_ x: Int, _ y: Int, _ rects: [CGRect]) -> Bool {
                            let p = CGPoint(x: x, y: y)
                            if !appSpread { return rects[0].contains(p) }
                            if s.isSpread {
                                return k == 0 ? (x < splitPx && rects[0].contains(p)) : (x >= splitPx && rects[1].contains(p))
                            }
                            return (x < splitPx && rects[0].contains(p)) || (x >= splitPx && rects[1].contains(p))
                        }
                        let rects = crops.map { pixelRect($0, W, H, pad: 1) }
                        if !leaf.items.isEmpty, !rects.isEmpty, let mask = HCSynth.render(s, .print(k)) {
                            if appSpread {   // the split line against the print, in the scan's own frame
                                let raw = HillClimb.gray(mask)
                                for y in 0..<H where raw[y * W + splitPx] < 100 { splitInPrint = true; break }
                            }
                            let comp = ImageTransform.deskewedComposite(mask, splitX: page.splitX,
                                leftDegrees: page.leftSkew, rightDegrees: page.rightSkew, isSpread: page.isSpread)
                            let g = HillClimb.gray(comp)
                            for y in 0..<H {
                                let row = y * W
                                for x in 0..<W where g[row + x] < 100 && !allowed(x, y, rects) { cutPx += 1 }
                            }
                        } else if !leaf.items.isEmpty, rects.isEmpty {
                            cutPx += 1_000_000   // a skipped page loses everything
                        }
                        // Slack: the crop against the leaf's paper, once the app has straightened it.
                        if appSpread == s.isSpread, crops.count > k, let pm = HCSynth.render(s, .paper(k)) {
                            let comp = ImageTransform.deskewedComposite(pm, splitX: page.splitX,
                                leftDegrees: page.leftSkew, rightDegrees: page.rightSkew, isSpread: page.isSpread)
                            let g = HillClimb.gray(comp)
                            var x0 = W, x1 = -1, y0 = H, y1 = -1
                            let lo = appSpread ? (k == 0 ? 0 : splitPx) : 0
                            let hi = appSpread ? (k == 0 ? splitPx : W) : W
                            for y in 0..<H {
                                let row = y * W
                                for x in lo..<hi where g[row + x] < 128 {
                                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                                }
                            }
                            if x1 >= x0 {
                                let c = crops[k].normalized().pixelRect(in: CGSize(width: W, height: H))
                                let e = [(Double(x0) - c.minX) / Double(W), (Double(y0) - c.minY) / Double(H),
                                         (c.maxX - Double(x1 + 1)) / Double(W), (c.maxY - Double(y1 + 1)) / Double(H)]
                                for v in e { slackSum += max(0, v); shortSum += max(0, -v); edges += 1 }
                            }
                        }
                    }
                    let err: Double? = appSpread && s.isSpread ? abs(page.splitX - s.foldTruth) * 100 : nil
                    let id = "synth-\(b)-\(i)"
                    record = [
                        "id": id, "book": "synth/synth-\(b).pdf", "page": i, "kind": "synthetic",
                        "cls": page.classification.rawValue, "split": HillClimb.r(page.splitX, 6),
                        "left": rectList(page.leftCrop), "right": appSpread ? rectList(page.rightCrop) : NSNull(),
                        "trim": page.trim.map(rectList) ?? NSNull(),
                        "skew": [HillClimb.r(page.leftSkew, 3), HillClimb.r(page.rightSkew, 3)],
                        "truth": ["spread": s.isSpread, "fold": HillClimb.r(s.foldTruth, 6), "tilt": HillClimb.r(s.tiltDegrees, 3),
                                  "tags": s.tags, "w": s.W, "h": s.H],
                        "cutPx": cutPx, "splitInPrint": splitInPrint,
                        "splitErrPct": err.map { HillClimb.r($0, 4) } ?? NSNull(),
                    ]
                    return Row(id: id, tags: s.tags, cutPx: cutPx, splitInPrint: splitInPrint, splitErr: err,
                               classOK: appSpread == s.isSpread,
                               slack: edges > 0 ? slackSum / Double(edges) * 100 : nil,
                               short: edges > 0 ? shortSum / Double(edges) * 100 : nil)
                }
                records.append(record)
                rows.append(row)
            }
        }

        func summary(_ rs: [Row]) -> [String: Any] {
            let errs = rs.compactMap(\.splitErr)
            let slacks = rs.compactMap(\.slack), shorts = rs.compactMap(\.short)
            return [
                "pages": rs.count,
                "printCut": rs.filter { $0.cutPx > 0 }.count,
                "splitInPrint": rs.filter(\.splitInPrint).count,
                "splitPages": errs.count,
                "meanSplitErrPct": HillClimb.r(HillClimb.mean(errs), 4),
                "p95SplitErrPct": HillClimb.r(HillClimb.percentile(errs, 0.95), 4),
                "classAcc": HillClimb.r(rs.isEmpty ? 0 : Double(rs.filter(\.classOK).count) / Double(rs.count), 4),
                "meanSlackPct": HillClimb.r(HillClimb.mean(slacks), 4),
                "meanShortPct": HillClimb.r(HillClimb.mean(shorts), 4),
            ]
        }
        var out = summary(rows)
        out["printCutPx"] = rows.reduce(0) { $0 + $1.cutPx }
        out["books"] = Self.syntheticBooks
        out["cutPages"] = rows.filter { $0.cutPx > 0 }.map(\.id)
        out["classErrorPages"] = rows.filter { !$0.classOK }.map(\.id)
        var byTag: [String: Any] = [:]
        for tag in Set(rows.flatMap(\.tags)).sorted() {
            byTag[tag] = summary(rows.filter { $0.tags.contains(tag) })
        }
        out["byTag"] = byTag
        return out
    }

    // MARK: Real books

    private func scoreReal(into records: inout [[String: Any]]) async -> [String: Any] {
        var books: [[String: Any]] = []
        var total = (pages: 0, glyphs: 0, split: 0, crop: 0, splitAll: 0, cropAll: 0)
        // HILLCLIMB_BOOKS=Wallace,Riezler scores only books whose names start so.
        let only = HillClimb.env["HILLCLIMB_BOOKS"].map { $0.split(separator: ",").map(String.init) }
        for url in HillClimb.bookURLs() where only.map({ $0.contains { url.lastPathComponent.hasPrefix($0) } }) ?? true {
            let t0 = HillClimb.now()
            let bytes = HillClimb.fileSize(url)
            let step = bytes > Self.sampleBytes ? Self.sampleStep : 1
            var source = url
            if step > 1 {
                guard let copy = HillClimb.sampledCopy(of: url, every: step, named: "sample-\(HillClimb.shortName(url)).pdf")
                else { Issue.record("could not sample \(url.lastPathComponent)"); continue }
                source = copy
            }
            let m = HillClimb.makeModel()
            await HillClimb.load(source, into: m)
            guard let doc = PDFDocument(url: source), doc.pageCount == m.pages.count else {
                Issue.record("\(url.lastPathComponent): model and document disagree on the page count")
                continue
            }
            let tAnalysis = HillClimb.now() - t0
            var counts = (glyphs: 0, split: 0, crop: 0, splitAll: 0, cropAll: 0)
            var classes: [String: Int] = [:]
            for (n, page) in m.pages.enumerated() {
                let original = n * step
                var record: [String: Any] = [
                    "id": "\(HillClimb.shortName(url))-\(original)", "book": "books/\(url.lastPathComponent)",
                    "page": original, "kind": "real", "cls": page.classification.rawValue,
                    "split": HillClimb.r(page.splitX, 6), "left": rectList(page.leftCrop),
                    "right": page.isSpread ? rectList(page.rightCrop) : NSNull(),
                    "trim": page.trim.map(rectList) ?? NSNull(),
                    "skew": [HillClimb.r(page.leftSkew, 3), HillClimb.r(page.rightSkew, 3)],
                ]
                classes[page.classification.rawValue, default: 0] += 1
                autoreleasepool {
                    guard let pdfPage = doc.page(at: n) else { return }
                    let size = PDFRenderer.displaySize(of: pdfPage)
                    let dpi = min(110.0, 1600.0 / Double(max(size.width, size.height)) * 72)
                    guard let raw = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi) else { return }
                    var splitCuts = 0, splitCutsAll = 0
                    let straight = ImageTransform.deskewedComposite(raw, splitX: page.splitX,
                        leftDegrees: page.leftSkew, rightDegrees: page.rightSkew, isSpread: page.isSpread)
                    let w = raw.width, h = raw.height
                    // Counted: glyphs less the pieces of vertical marks (fold crease, fold-shadow speckle).
                    // `...All` keeps the finder's whole list, as runs before split-r3 counted it.
                    let straightGray = HillClimb.gray(straight)
                    let straightAll = HCGlyphDetector.glyphs(straightGray, width: w, height: h)
                    let straightGlyphs = HCGlyphDetector.withoutVerticalMarks(straightAll, gray: straightGray, width: w, height: h)
                    if page.isSpread {
                        let unturned = page.leftSkew == 0 && page.rightSkew == 0
                        let rawGray = unturned ? straightGray : HillClimb.gray(raw)
                        let rawAll = unturned ? straightAll : HCGlyphDetector.glyphs(rawGray, width: w, height: h)
                        let rawGlyphs = unturned
                            ? straightGlyphs : HCGlyphDetector.withoutVerticalMarks(rawAll, gray: rawGray, width: w, height: h)
                        let splitPx = max(1, min(w - 1, Int(page.splitX * Double(w))))
                        splitCuts = HCGlyphDetector.cutBySplit(rawGlyphs, atPixel: splitPx)
                        splitCutsAll = HCGlyphDetector.cutBySplit(rawAll, atPixel: splitPx)
                    }
                    let rects = page.outputCrops(direction: .leftToRight).map { pixelRect($0, w, h) }
                    let cropCuts = HCGlyphDetector.cutByCrops(straightGlyphs, rects)
                    let cropCutsAll = HCGlyphDetector.cutByCrops(straightAll, rects)
                    record["glyphs"] = straightGlyphs.count
                    record["bed"] = rects.map { bedShare(straightGray, w, h, $0) }
                    record["bedV"] = rects.map { bedShare(straightGray, w, h, $0, rows: true) }
                    record["splitCutsGlyphs"] = splitCuts
                    record["cropCutsGlyphs"] = cropCuts
                    record["splitCutsGlyphsAll"] = splitCutsAll
                    record["cropCutsGlyphsAll"] = cropCutsAll
                    counts.glyphs += straightGlyphs.count; counts.split += splitCuts; counts.crop += cropCuts
                    counts.splitAll += splitCutsAll; counts.cropAll += cropCutsAll
                }
                records.append(record)
            }
            // The book's page size as the inspector shows it (Whole page), in inches.
            let size = m.pageSize
            books.append([
                "pageSize": size.map { s -> [String: Any] in
                    ["width": s.width.map { HillClimb.r($0, 3) } ?? NSNull(), "height": s.height.map { HillClimb.r($0, 3) } ?? NSNull(),
                     "measured": s.measured, "total": s.total, "details": s.details,
                     "fitsAll": s.fitsAll.map { [$0.width, $0.height] } ?? NSNull()]
                } ?? NSNull(),
                "name": HillClimb.shortName(url), "file": url.lastPathComponent, "bytes": bytes,
                "pagesInBook": step == 1 ? doc.pageCount : (PDFDocument(url: url)?.pageCount ?? 0),
                "pagesScored": m.pages.count, "sampled": step > 1, "sampleEvery": step,
                "classes": classes, "glyphs": counts.glyphs,
                "splitCutsGlyphs": counts.split, "cropCutsGlyphs": counts.crop,
                "splitCutsGlyphsAll": counts.splitAll, "cropCutsGlyphsAll": counts.cropAll,
                "analysisSeconds": HillClimb.r(tAnalysis, 1),
            ])
            total.pages += m.pages.count; total.glyphs += counts.glyphs
            total.split += counts.split; total.crop += counts.crop
            total.splitAll += counts.splitAll; total.cropAll += counts.cropAll
            if step > 1 { try? FileManager.default.removeItem(at: source) }
        }
        return ["books": books,
                "totals": ["pages": total.pages, "glyphs": total.glyphs,
                           "splitCutsGlyphs": total.split, "cropCutsGlyphs": total.crop,
                           "splitCutsGlyphsAll": total.splitAll, "cropCutsGlyphsAll": total.cropAll]]
    }
}
