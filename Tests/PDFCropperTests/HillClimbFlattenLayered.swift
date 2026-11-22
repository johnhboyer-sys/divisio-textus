import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFCropper

/// Flatten pages on a layered scan (Smith-1950), scored on the pages the export makes:
/// the text layer alone (Color or Gray), both layers in black and white (Black and white),
/// and both with Remove shadows. Before is the export's page without the option, after
/// with it; curl, droop and letter width as in `HillClimbFlattenTests`, print safety by
/// its `printCheck` with the model the export used. Writes results/<label>/flatten-layered.json.
///
/// Env: HILLCLIMB_FLATTEN_LAYERED (any value) runs it; HILLCLIMB_FLATTEN_PAGES limits to those
/// source pages (1-based); HILLCLIMB_FLATTEN_VARIANTS=text,bw,rs (default text,bw);
/// HILLCLIMB_FLATTEN_SHOTS=<folder> and HILLCLIMB_FLATTEN_SHOT_IDS=51R,62R write each named
/// side before and after, and for both layers the color layer with the text layer's ink
/// laid over it in red (`-register`), both as warped.
/// HILLCLIMB_FLATTEN_BYTES=bw,color,gray,bw-rs exports the pages in those modes with the
/// option off and on and records each page's image bytes.
@Suite("HillClimb flatten layered", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil
                && ProcessInfo.processInfo.environment["HILLCLIMB_FLATTEN_LAYERED"] != nil))
@MainActor
struct HillClimbFlattenLayered {
    static let variants: [(name: String, both: Bool, rs: Bool)] = [("text", false, false), ("bw", true, false), ("rs", true, true)]

    static func smith() -> URL? { HillClimb.bookURLs().first { HillClimb.shortName($0) == "Smith-1950" } }
    static var wanted: Set<Int>? {
        HillClimb.env["HILLCLIMB_FLATTEN_PAGES"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
    }

    @Test("Layered flatten score")
    func score() async throws {
        HillClimb.prepare()
        let url = try #require(Self.smith())
        let m = HillClimb.makeModel()
        await HillClimb.load(url, into: m)
        let doc = try #require(AppModel.reopen(url, password: nil))
        let names = Set((HillClimb.env["HILLCLIMB_FLATTEN_VARIANTS"] ?? "text,bw").split(separator: ",").map(String.init))
        let shots = HillClimb.env["HILLCLIMB_FLATTEN_SHOTS"].map { URL(fileURLWithPath: $0) }
        let shotIDs = Set((HillClimb.env["HILLCLIMB_FLATTEN_SHOT_IDS"] ?? "").split(separator: ",").map { "Smith-1950-\($0)" })
        if let shots { try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }
        var records: [[String: Any]] = []
        var sums: [String: [String: [Double]]] = [:]
        var counts: [String: [String: Int]] = [:]
        for page in m.pages {
            if let wanted = Self.wanted, !wanted.contains(page.sourceIndex + 1) { continue }
            guard let pdfPage = doc.page(at: page.sourceIndex), let layers = LayeredScan.layers(of: pdfPage) else { continue }
            autoreleasepool {
                let dpi = LayeredScan.textDPI(layers)
                let crops = page.outputCrops(direction: m.direction)
                let decoded = layers.patches.compactMap { p in LayeredScan.patchImage(p).map { (p, $0) } }
                guard let text = LayeredScan.straightened(page, pdfPage, dpi: dpi, { ctx, s in
                          LayeredScan.drawText(layers, of: pdfPage, in: ctx, scale: s) }),
                      let both = LayeredScan.straightened(page, pdfPage, dpi: dpi, { ctx, s in
                          LayeredScan.drawPatches(decoded, of: pdfPage, in: ctx, scale: s)
                          LayeredScan.drawText(layers, of: pdfPage, in: ctx, scale: s, over: true) }) else { return }
                for v in Self.variants where names.contains(v.name) {
                    guard let off = LayeredScan.textPages(of: page, pdfPage, layers: layers, direction: m.direction,
                                                          bothLayers: v.both, removeShadows: v.rs) else { continue }
                    let t0 = HillClimb.now()
                    guard let on = LayeredScan.textPages(of: page, pdfPage, layers: layers, direction: m.direction,
                                                         bothLayers: v.both, removeShadows: v.rs, flatten: true) else { continue }
                    let seconds = HillClimb.now() - t0
                    for (k, crop) in crops.enumerated() {
                        var tag = ""
                        let gutter = Flatten.gutterOnRight(crop, of: page)
                        if let g = gutter { tag = g ? "L" : "R" }
                        let id = "Smith-1950-\(page.sourceIndex + 1)\(tag)"
                        guard let a = off[k], let b = on[k],
                              let r = LayeredScan.pixelRect(crop, width: text.width, height: text.height) else {
                            counts[v.name, default: [:]]["picture", default: 0] += 1
                            continue
                        }
                        let model = Flatten.model(gray: text.pixels, width: text.width, height: text.height, region: r,
                                                  gutterOnRight: gutter, guardGray: v.both ? both.pixels : nil)
                        let rep = Flatten.report(Flatten.cut(text.pixels, width: text.width, r.x, r.y, r.w, r.h),
                                                 width: r.w, height: r.h, gutterOnRight: gutter)
                        let cb = HillClimbFlattenTests.curl(a, dpi: dpi, gutterOnRight: gutter)
                        let ca = model == nil ? cb : HillClimbFlattenTests.curl(b, dpi: dpi, gutterOnRight: gutter)
                        let check = model == nil ? (lost: [HCGlyph](), merged: [HCGlyph]())
                            : HillClimbFlattenTests.printCheck(before: a, after: b, glyphsBefore: cb.glyphs,
                                                               glyphsAfter: ca.glyphs, model: model)
                        let unchanged = model == nil && HillClimb.gray(a) == HillClimb.gray(b)
                        counts[v.name, default: [:]][model == nil ? "kept" : "flattened", default: 0] += 1
                        if model == nil && !unchanged { counts[v.name, default: [:]]["changedWithoutModel", default: 0] += 1 }
                        counts[v.name, default: [:]]["lost", default: 0] += check.lost.count
                        counts[v.name, default: [:]]["merged", default: 0] += check.merged.count
                        if cb.lines >= 6 {
                            sums[v.name, default: [:]]["droopBefore", default: []].append(cb.droopPt)
                            sums[v.name, default: [:]]["droopAfter", default: []].append(ca.droopPt)
                            sums[v.name, default: [:]]["curlBefore", default: []].append(cb.meanPt)
                            sums[v.name, default: [:]]["curlAfter", default: []].append(ca.meanPt)
                            if cb.droopPt >= 1 {
                                counts[v.name, default: [:]]["curled", default: 0] += 1
                                if model != nil { counts[v.name, default: [:]]["flattenedCurled", default: 0] += 1 }
                                sums[v.name, default: [:]]["curledDroopBefore", default: []].append(cb.droopPt)
                                sums[v.name, default: [:]]["curledDroopAfter", default: []].append(ca.droopPt)
                            }
                            if model != nil, let x = cb.widthRatio, let y = ca.widthRatio {
                                sums[v.name, default: [:]]["widthBefore", default: []].append(x)
                                sums[v.name, default: [:]]["widthAfter", default: []].append(y)
                            }
                        }
                        sums[v.name, default: [:]]["seconds", default: []].append(seconds / Double(crops.count))
                        records.append(["id": id, "variant": v.name, "outcome": rep.outcome.rawValue, "note": rep.note,
                                        "flattened": model != nil, "lines": cb.lines,
                                        "squash": HillClimb.r(rep.squash, 3), "stretchPx": HillClimb.r(rep.stretchPx, 1),
                                        "droopPt": [HillClimb.r(cb.droopPt, 3), HillClimb.r(ca.droopPt, 3)],
                                        "curlPt": [HillClimb.r(cb.meanPt, 3), HillClimb.r(ca.meanPt, 3)],
                                        "widthRatio": [cb.widthRatio.map { HillClimb.r($0, 3) } ?? 0, ca.widthRatio.map { HillClimb.r($0, 3) } ?? 0],
                                        "lost": check.lost.count, "merged": check.merged.count,
                                        "lostAt": check.lost.prefix(5).map { [$0.x0, $0.y0, $0.x1, $0.y1] }])
                        if let shots, shotIDs.contains(id) {
                            HillClimb.png(a, to: shots.appendingPathComponent("\(id)-\(v.name)-before.png"))
                            HillClimb.png(b, to: shots.appendingPathComponent("\(id)-\(v.name)-after.png"))
                            if v.both, v.name == "bw", let model,
                               let color = LayeredScan.straightened(page, pdfPage, dpi: dpi, { ctx, s in
                                   LayeredScan.drawPatches(decoded, of: pdfPage, in: ctx, scale: s) }),
                               let o = Self.register(text: text.pixels, color: color.pixels, width: text.width, region: r, model: model),
                               let o0 = Self.register(text: text.pixels, color: color.pixels, width: text.width, region: r, model: nil) {
                                HillClimb.png(o0, to: shots.appendingPathComponent("\(id)-register-before.png"))
                                HillClimb.png(o, to: shots.appendingPathComponent("\(id)-register.png"))
                            }
                        }
                    }
                }
            }
        }
        var summary: [String: Any] = ["label": HillClimb.label]
        for (name, s) in sums {
            var row: [String: Any] = counts[name] ?? [:]
            for (k, v) in s { row[k] = HillClimb.r(HillClimb.mean(v), 3) }
            summary[name] = row
        }
        HillClimb.write(summary, "flatten-layered.json")
        HillClimb.write(["pages": records], "flatten-layered-pages.json")
        print("layered summary \(summary)")
    }

    /// The region's color layer alone, gray, with the text layer's ink laid over in red at
    /// half strength; both warped by `model` when given.
    static func register(text: [UInt8], color: [UInt8], width: Int, region r: (x: Int, y: Int, w: Int, h: Int),
                         model: Flatten.Model?) -> CGImage? {
        let t = model.map { Flatten.warped(gray: text, width: width, region: r, model: $0) } ?? Flatten.cut(text, width: width, r.x, r.y, r.w, r.h)
        let b = model.map { Flatten.warped(gray: color, width: width, region: r, model: $0) } ?? Flatten.cut(color, width: width, r.x, r.y, r.w, r.h)
        var rgb = [UInt8](repeating: 255, count: r.w * r.h * 4)
        for i in 0..<(r.w * r.h) {
            let g = b[i]
            if t[i] < 128 {
                rgb[4 * i] = UInt8((Int(g) + 255) / 2); rgb[4 * i + 1] = g / 2; rgb[4 * i + 2] = g / 2
            } else {
                rgb[4 * i] = g; rgb[4 * i + 1] = g; rgb[4 * i + 2] = g
            }
        }
        guard let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
        return CGImage(width: r.w, height: r.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Bytes

    /// Each page's image bytes in a PDF: the encoded length of the images it draws.
    static func pageBytes(_ url: URL) -> [Int] {
        guard let doc = CGPDFDocument(url as CFURL) else { return [] }
        var out: [Int] = []
        for i in 1...max(1, doc.numberOfPages) {
            guard let page = doc.page(at: i), let dict = page.dictionary else { out.append(0); continue }
            var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res,
                  CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { out.append(0); continue }
            var total = 0
            CGPDFDictionaryApplyBlock(xo, { _, obj, _ in
                var s: CGPDFStreamRef?
                if CGPDFObjectGetValue(obj, .stream, &s), let s, let d = CGPDFStreamGetDictionary(s) {
                    var n: CGPDFInteger = 0
                    if CGPDFDictionaryGetInteger(d, "Length", &n) { total += n }
                }
                return true
            }, nil)
            out.append(total)
        }
        return out
    }

    @Test("Layered flatten bytes")
    func bytes() async throws {
        guard let modes = HillClimb.env["HILLCLIMB_FLATTEN_BYTES"] else { return }
        HillClimb.prepare()
        let url = try #require(Self.smith())
        let m = HillClimb.makeModel()
        await HillClimb.load(url, into: m)
        let pages = m.pages.filter { Self.wanted?.contains($0.sourceIndex + 1) ?? true }
        var out: [String: Any] = [:]
        for mode in modes.split(separator: ",").map(String.init) {
            var perMode: [String: Any] = [:]
            var bytes: [[Int]] = []
            for on in [false, true] {
                var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false,
                                                    reader: m.ocrReader, packs: m.ocrPacks,
                                                    enhanceMode: mode.hasPrefix("bw") ? .blackAndWhite : mode.hasPrefix("gray") ? .grayscale : .color)
                settings.matchScanResolution = m.matchScanResolution
                settings.removeShadows = mode.hasSuffix("-rs")
                settings.flattenPages = on
                let file = HillClimb.scratch.appendingPathComponent("layered-bytes-\(mode)-\(on).pdf")
                try? FileManager.default.removeItem(at: file)
                let t0 = HillClimb.now()
                let report: PDFExporter.Report? = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        guard let doc = AppModel.reopen(url, password: nil) else { cont.resume(returning: nil); return }
                        cont.resume(returning: try? PDFExporter.export(pages: pages, from: doc, to: file, settings: settings))
                    }
                }
                #expect(report != nil)
                let b = Self.pageBytes(file)
                bytes.append(b)
                perMode[on ? "on" : "off"] = ["pages": b.count, "bytes": b.reduce(0, +), "fileBytes": HillClimb.fileSize(file),
                                              "seconds": HillClimb.r(HillClimb.now() - t0, 1)]
                try? FileManager.default.removeItem(at: file)
            }
            if bytes.count == 2, bytes[0].count == bytes[1].count {
                let ratios = zip(bytes[0], bytes[1]).map { $0 > 0 ? Double($1) / Double($0) : 1 }
                perMode["perPageRatio"] = ["min": HillClimb.r(ratios.min() ?? 1, 3), "max": HillClimb.r(ratios.max() ?? 1, 3),
                                           "mean": HillClimb.r(HillClimb.mean(ratios), 3),
                                           "over10pct": ratios.filter { $0 > 1.1 }.count,
                                           "worst": ratios.enumerated().sorted { $0.element > $1.element }.prefix(5)
                                               .map { [$0.offset + 1, HillClimb.r($0.element, 3)] as [Any] }]
            }
            out[mode] = perMode
        }
        HillClimb.write(out, "flatten-layered-bytes.json")
        print("layered bytes \(out)")
    }
}
