import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFCropper

/// DITHER_PROBE=Book,Book (with HILLCLIMB_DIR): every Black and white output page of each book
/// made as `HillClimbShadowTests.pairs` makes it; prints the ink `BlackAndWhite.clearDither`
/// takes off each page (`DITHERPAGE`: all of it, and what lies over 0.5 inch from the crop's
/// sides), the book's totals and the five pages losing most over 0.5 inch in (`DITHERBOOK`),
/// and the time Black and white takes, with and without Remove shadows (`DITHERTIME`).
/// Pages are tagged o<output page>-p<source page>[L|R]. DITHER_PNG=<folder> with DITHER_PAGES=k,...
/// (output page, 1-based), or DITHER_MIN_INNER=n (pages losing n px or more over 0.5 inch in), draws those pages there: `<Book>-<tag>.bw.png`, `-bw-on.png`, and `-diff.png` (ink kept black, ink cleared red).
/// FINDING4=Book,Book runs `ShadowRemoval.teeth(..., within: 2)` on every output page, layered
/// or not, drawn as Color draws it (`TEETHFOUND`), and lists the groups of `pictureCells` (solid)
/// that reach the teeth's zone and are 0.4 inch each way (`VETOED`, page box in pixels);
/// FINDING4_PNG=<folder> draws each such page there with the group's box.
@Suite("Dither probe", .serialized,
       .enabled(if: (ProcessInfo.processInfo.environment["DITHER_PROBE"] != nil
                     || ProcessInfo.processInfo.environment["FINDING4"] != nil)
                    && ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct HillClimbDitherProbe {
    @Test("Measure clearDither")
    func probe() async throws {
        let env = ProcessInfo.processInfo.environment
        let minInner = Int(env["DITHER_MIN_INNER"] ?? "") ?? Int.max
        let minRestored = Int(env["DITHER_MIN_RESTORED"] ?? "") ?? Int.max
        let show = Set((env["DITHER_PAGES"] ?? "").split(separator: ",").compactMap { Int($0) })
        for name in (env["DITHER_PROBE"] ?? "").split(separator: ",").map(String.init) {
            guard let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == name }) else { continue }
            let m = HillClimb.makeModel()
            await HillClimb.load(url, into: m)
            let doc = try #require(AppModel.reopen(url, password: nil))
            var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false, enhanceMode: .blackAndWhite)
            settings.matchScanResolution = m.matchScanResolution
            var rows: [(tag: String, inner: Int)] = []
            var total = 0, totalInner = 0, layered = 0, inkTime = 0.0, ditherTime = 0.0, made = 0
            for page in m.pages {
                let d = autoreleasepool { doc.page(at: page.sourceIndex).map { HillClimbShadowTests.drawn(page, $0, settings: settings) } }
                guard let d else { continue }
                if !d.made.isEmpty { layered += 1; continue }
                let n = page.sourceIndex + 1
                let prepared = d.images.map { BlackAndWhite.prepare($0, dpi: d.dpi) }
                var fine: [BlackAndWhite.Prepared]?
                if let f = d.fine {
                    let p = f.map { BlackAndWhite.prepare($0, dpi: d.fineDPI) }
                    if !p.contains(where: \.picture) { fine = p }
                }
                for k in d.images.indices {
                    made += 1
                    let o = made
                    let (p, dpi) = fine.map { ($0[k], d.fineDPI) } ?? (prepared[k], d.dpi)
                    guard !p.picture else { continue }
                    let w = p.width, h = p.height
                    let tone = BlackAndWhite.holdsTones(p.gray, width: w, height: h)
                    // The ink `BlackAndWhite.ink` hands `clearDither` (its sharp-nil start).
                    let clean = BlackAndWhite.cleanLevel(p.paper)
                    var pre = [UInt8](repeating: 255, count: w * h)
                    for i in 0..<(w * h) {
                        let b = Int(p.paper[i]), g = Int(p.gray[i])
                        if g < 128, b >= clean { pre[i] = 0 } else if tone, g < b - max(20, b * 12 / 100) { pre[i] = 0 }
                    }
                    var was = pre
                    Self.oldClearDither(&was, w, h, dpi: dpi)
                    var post = pre
                    let t0 = HillClimb.now()
                    BlackAndWhite.clearDither(&post, w, h, dpi: dpi)
                    ditherTime += HillClimb.now() - t0
                    let margin = Int((0.5 * dpi).rounded())
                    var all = 0, inner = 0, restored = 0, restoredInner = 0, added = 0
                    for y in 0..<h { for x in 0..<w where pre[y * w + x] == 0 {
                        let i = y * w + x
                        if was[i] != 0, post[i] == 0 {
                            restored += 1
                            if x >= margin, x < w - margin, y >= margin, y < h - margin { restoredInner += 1 }
                        }
                        if was[i] == 0, post[i] != 0 { added += 1 }
                    } }
                    for y in 0..<h { for x in 0..<w where pre[y * w + x] == 0 && post[y * w + x] != 0 {
                        all += 1
                        if x >= margin, x < w - margin, y >= margin, y < h - margin { inner += 1 }
                    } }
                    let tag = "o\(o)-p\(n)" + (d.images.count > 1 ? (k == 0 ? "L" : "R") : "")
                    total += all; totalInner += inner
                    rows.append((tag, inner))
                    print("DITHERPAGE \(name) \(tag) all \(all) inner \(inner) restored \(restored) restoredInner \(restoredInner) added \(added)")
                    let t1 = HillClimb.now()
                    let off = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: tone, width: w, height: h, dpi: dpi, paper: p.paper)
                    let on = BlackAndWhite.ink(gray: p.gray, sharp: nil, tone: tone, width: w, height: h, dpi: dpi,
                                               removeShadows: true, paper: p.paper)
                    inkTime += HillClimb.now() - t1
                    if let dir = env["DITHER_PNG"], show.contains(o) || inner >= minInner || restored >= minRestored {
                        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        let base = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(tag)")
                        if let im = BlackAndWhite.image(off, width: w, height: h) { HillClimb.png(im, to: base.appendingPathExtension("bw.png")) }
                        if let im = BlackAndWhite.image(on, width: w, height: h) { HillClimb.png(im, to: base.appendingPathExtension("bw-on.png")) }
                        var rgba = [UInt8](repeating: 255, count: w * h * 4)
                        // Black kept by both, red cleared by both, blue kept now (cleared by
                        // a58c0a4), green cleared now only.
                        for i in 0..<(w * h) where pre[i] == 0 {
                            let c: (UInt8, UInt8, UInt8) = post[i] == 0 ? (was[i] == 0 ? (0, 0, 0) : (0, 0, 255))
                                                                       : (was[i] == 0 ? (0, 200, 0) : (255, 0, 0))
                            rgba[4 * i] = c.0; rgba[4 * i + 1] = c.1; rgba[4 * i + 2] = c.2
                        }
                        let cs = CGColorSpaceCreateDeviceRGB()
                        if let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w, space: cs,
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let im = ctx.makeImage() {
                            HillClimb.png(im, to: base.appendingPathExtension("diff.png"))
                        }
                    }
                }
            }
            let worst = rows.sorted { $0.inner > $1.inner }.prefix(5).map { "\($0.tag) \($0.inner)" }
            print("DITHERBOOK \(name) pages \(rows.count) layered \(layered) all \(total) inner \(totalInner) worst \(worst)")
            print("DITHERTIME \(name) ink \(HillClimb.r(inkTime, 2)) s clearDither \(HillClimb.r(ditherTime, 2)) s")
        }
    }


    @Test("Finding 4: teeth within 2 inches")
    func finding4() async throws {
        let env = ProcessInfo.processInfo.environment
        for name in (env["FINDING4"] ?? "").split(separator: ",").map(String.init) {
            guard let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == name }) else { continue }
            let m = HillClimb.makeModel()
            await HillClimb.load(url, into: m)
            let doc = try #require(AppModel.reopen(url, password: nil))
            var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false, enhanceMode: .color)
            settings.matchScanResolution = m.matchScanResolution
            var found = 0, pages = 0, made = 0
            for page in m.pages {
                autoreleasepool {
                    guard let pdfPage = doc.page(at: page.sourceIndex) else { return }
                    let dpi = settings.matchScanResolution
                        ? PDFRenderer.scanDPI(of: pdfPage).map { min(600, max(150, $0)) } ?? settings.dpi : settings.dpi
                    guard let r = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi),
                          let images = PDFExporter.outputImages(of: page, rendered: r, settings: settings) else { return }
                    for (k, image) in images.enumerated() {
                        made += 1; pages += 1
                        let p = BlackAndWhite.prepare(image, dpi: dpi)
                        let comb = ShadowRemoval.teeth(p.gray, p.width, p.height, dpi: dpi,
                                                       paper: BlackAndWhite.cleanLevel(p.paper) + 20, within: 2)
                        guard comb.found else { continue }
                        found += 1
                        let tag = "o\(made)-p\(page.sourceIndex + 1)" + (images.count > 1 ? (k == 0 ? "L" : "R") : "")
                        print("TEETHFOUND \(name) \(tag) picture \(p.picture)")
                        for box in Self.vetoed(p, comb, dpi: dpi) {
                            print("VETOED \(name) \(tag) \(box)")
                            if let dir = env["FINDING4_PNG"] {
                                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                                HillClimb.png(image, to: URL(fileURLWithPath: dir)
                                    .appendingPathComponent("\(name)-\(tag)-\(box.0)-\(box.1)-\(box.2)-\(box.3).png"))
                            }
                        }
                    }
                }
            }
            print("FINDING4 \(name) pages \(pages) teeth found \(found)")
        }
    }

    /// The groups `BlackAndWhite.pictureCells` (solid) passes over for reaching the teeth's
    /// zone that are 0.4 inch or more each way: (x0, y0, x1, y1) in the page's pixels.
    static func vetoed(_ p: BlackAndWhite.Prepared, _ comb: ShadowRemoval.Teeth, dpi: Double) -> [(Int, Int, Int, Int)] {
        let w = p.width, h = p.height, paper = p.paper
        let step = max(1, Int((dpi / 50).rounded()))
        let sw = (w + step - 1) / step, sh = (h + step - 1) / step
        var small = [UInt8](repeating: 255, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw { small[y * sw + x] = paper[(y * step) * w + x * step] } }
        let usual = BlackAndWhite.cleanLevel(small) + 20
        let thin = max(1, Int((0.06 * dpi / Double(step)).rounded()))
        let pw = sw + 2 * thin, ph = sh + 2 * thin
        var padded = [UInt8](repeating: 255, count: pw * ph)
        for y in 0..<sh { for x in 0..<sw where Int(small[y * sw + x]) * 5 <= usual * 4 { padded[(y + thin) * pw + x + thin] = 0 } }
        let opened = LayeredScan.minFilter(LayeredScan.maxFilter(padded, pw, ph, radius: thin), pw, ph, radius: thin)
        var mark = [Bool](repeating: false, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw { mark[y * sw + x] = opened[(y + thin) * pw + x + thin] == 0 } }
        var zone = [UInt8](repeating: 255, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw where comb.zone[(y * step) * w + x * step] { zone[y * sw + x] = 0 } }
        let byComb = LayeredScan.minFilter(zone, sw, sh, radius: max(1, Int((0.04 * dpi / Double(step)).rounded()))).map { $0 == 0 }
        let span = Int((0.4 * dpi / Double(step)).rounded())
        var out: [(Int, Int, Int, Int)] = []
        for start in mark.indices where mark[start] {
            mark[start] = false
            var stack = [start], touches = false
            var minX = sw, maxX = 0, minY = sh, maxY = 0
            while let k = stack.popLast() {
                let x = k % sw, y = k / sw
                if byComb[k] { touches = true }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < sw, ny < sh, mark[ny * sw + nx] else { continue }
                    mark[ny * sw + nx] = false
                    stack.append(ny * sw + nx)
                }
            }
            if touches, maxX - minX >= span, maxY - minY >= span {
                out.append((minX * step, minY * step, min(w, (maxX + 1) * step), min(h, (maxY + 1) * step)))
            }
        }
        return out
    }

    /// a58c0a4's `clearDither`, to compare with.
    static func oldClearDither(_ out: inout [UInt8], _ w: Int, _ h: Int, dpi: Double) {
        let cell = max(2, Int((0.05 * dpi).rounded()))
        let cw = (w + cell - 1) / cell, ch = (h + cell - 1) / cell
        let minGlyph = max(4, Int((0.012 * dpi * 0.012 * dpi).rounded()))   // a full stop
        let cc = ShadowRemoval.Components(out, w, h)
        var specks = [Int](repeating: 0, count: cw * ch)
        for b in cc.blobs where b.count < minGlyph { specks[(b.minY / cell) * cw + b.minX / cell] += 1 }
        let dense = specks.map { $0 >= 4 ? UInt8(0) : 255 }
        guard dense.contains(0) else { return }
        var field = LayeredScan.maxFilter(LayeredScan.minFilter(dense, cw, ch, radius: 1), cw, ch, radius: 1).map { $0 == 0 }
        let edge = max(1, Int((0.25 * dpi / Double(cell)).rounded()))
        let least = Int((0.25 * dpi * dpi / Double(cell * cell)).rounded())
        var shadow = [Bool](repeating: false, count: cw * ch)
        for start in field.indices where field[start] {
            field[start] = false
            var stack = [start], group: [Int] = [], side = false
            while let k = stack.popLast() {
                group.append(k)
                let x = k % cw, y = k / cw
                if x < edge || y < edge || x >= cw - edge || y >= ch - edge { side = true }
                for ny in max(0, y - 1)...min(ch - 1, y + 1) {
                    for nx in max(0, x - 1)...min(cw - 1, x + 1) where field[ny * cw + nx] {
                        field[ny * cw + nx] = false
                        stack.append(ny * cw + nx)
                    }
                }
            }
            if side, group.count >= least { for k in group { shadow[k] = true } }
        }
        // Where the shadow fades, its dots thin out: the field reaches on through cells
        // holding a speck within two cells of it.
        var stack = shadow.indices.filter { shadow[$0] }
        while let k = stack.popLast() {
            let x = k % cw, y = k / cw
            for ny in max(0, y - 2)...min(ch - 1, y + 2) {
                for nx in max(0, x - 2)...min(cw - 1, x + 2) where !shadow[ny * cw + nx] && specks[ny * cw + nx] > 0 {
                    shadow[ny * cw + nx] = true
                    stack.append(ny * cw + nx)
                }
            }
        }
        for (k, b) in cc.blobs.enumerated() where shadow[(b.minY / cell) * cw + b.minX / cell] {
            if b.count >= minGlyph {
                let solid = cc.count(k, where: { i in
                    i % w < w - 1 && i / w < h - 1 && out[i + 1] == 0 && out[i + w] == 0 && out[i + w + 1] == 0
                })
                guard solid == 0 else { continue }
            }
            cc.clear(k, in: &out)
        }
    }
}
