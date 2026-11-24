import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFCropper

/// Erase: boxes blanked with the paper's colour in the export.
@Suite("Erase", .serialized)
struct EraseTests {

    private func grayImage(_ pixels: [UInt8], _ w: Int, _ h: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Row 0 is the top, the same way the eraser reads a bitmap.
    private func grayBytes(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return [] }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let stride = ctx.bytesPerRow
        let src = data.bindMemory(to: UInt8.self, capacity: stride * h)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { out[y * w + x] = src[y * stride + x] }
        }
        return out
    }

    private func mismatches(_ got: [UInt8], _ want: [UInt8], _ w: Int) -> String {
        var bad: [String] = []
        for i in 0..<min(got.count, want.count) where got[i] != want[i] {
            bad.append("(\(i % w),\(i / w)) \(got[i]) want \(want[i])")
            if bad.count == 6 { break }
        }
        return bad.joined(separator: "; ")
    }

    private func rects(_ page: BookPage) -> [CropRect]? { page.erasures?.map(\.rect) }

    @Test("A black stamp on grey paper is filled with the ring's grey; the rest stays")
    func stampBecomesPaper() {
        let w = 128, h = 64, paper: UInt8 = 180
        var src = [UInt8](repeating: paper, count: w * h)
        for y in 16..<32 { for x in 32..<64 { src[y * w + x] = 0 } }   // the stamp
        src[4 * w + 4] = 0                                              // a mark outside the box
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        // The box covers the stamp with room, so the ring is paper, not the stamp.
        page.erasures = [page.erasure(for: CropRect(x: 24.0 / 128, y: 8.0 / 64, width: 48.0 / 128, height: 32.0 / 64))]
        let out = grayBytes(PDFExporter.erased(grayImage(src, w, h), page: page))
        var want = src
        for y in 8..<40 { for x in 24..<72 { want[y * w + x] = paper } }
        #expect(out == want, Comment(rawValue: mismatches(out, want, w)))
    }

    @Test("A box that covers the whole crop, so the ring is empty, is filled white")
    func emptyRingIsWhite() {
        let w = 16, h = 16
        let src = [UInt8](repeating: 40, count: w * h)
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        page.erasures = [page.erasure(for: .full)]
        let out = grayBytes(PDFExporter.erased(grayImage(src, w, h), page: page))
        #expect(out.allSatisfy { $0 == 255 })
    }

    @Test("A box partly inside the crop is clipped to it; one outside the crop changes nothing")
    func clippedToTheCrop() throws {
        // The whole page. The left crop is its left half, 80×40. The box runs from
        // 0.375 to 0.625, so only 0.375...0.5 — and one pixel of grow — meets the crop.
        let w = 160, h = 40, paper: UInt8 = 160
        var src = [UInt8](repeating: paper, count: w * h)
        for y in 10..<20 { for x in 48..<w { src[y * w + x] = 0 } }
        src[2 * w + 2] = 0
        let crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        var bare = BookPage(sourceIndex: 0, classification: .single, leftCrop: crop, analyzed: true)
        let plain = grayBytes(try #require(PDFExporter.outputImages(of: bare, rendered: grayImage(src, w, h), settings: settings())?.first))
        #expect(plain.count == 80 * h && plain[10 * 80 + 60] < 80)
        bare.erasures = [bare.erasure(for: CropRect(x: 0.375, y: 0.25, width: 0.25, height: 0.25))]
        let out = grayBytes(try #require(PDFExporter.outputImages(of: bare, rendered: grayImage(src, w, h), settings: settings())?.first))
        var want = plain
        for y in 9..<21 { for x in 59..<80 { want[y * 80 + x] = plain[0] } }
        #expect(out == want, Comment(rawValue: mismatches(out, want, 80)))
        #expect(out[2 * 80 + 2] < 80 && out[10 * 80 + 48] < 80)

        bare.erasures = [bare.erasure(for: CropRect(x: 0.625, y: 0.25, width: 0.25, height: 0.25))]
        let same = grayBytes(try #require(PDFExporter.outputImages(of: bare, rendered: grayImage(src, w, h), settings: settings())?.first))
        #expect(same == plain, Comment(rawValue: mismatches(same, plain, 80)))
    }

    @Test("An exported page has no dark pixels where a stamp was erased, and keeps a mark that was not")
    func exportBlanksTheStamp() throws {
        let side = 200.0
        let media = CGRect(x: 0, y: 0, width: side, height: side)
        let url = Fixtures.writePDF("erase-src-\(UUID().uuidString).pdf", media: media, pages: [{ c in
            c.setFillColor(CGColor(gray: 0.8, alpha: 1))
            c.fill(media)
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 60, y: side - 60 - 32, width: 32, height: 32))       // stamp, top-left area
            c.fill(CGRect(x: 140, y: side - 140 - 32, width: 32, height: 32))     // left in place
        }])
        let doc = try #require(PDFDocument(url: url))
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        page.erasures = [page.erasure(for: CropRect(x: 0.26, y: 0.26, width: 0.24, height: 0.24))]
        var settings = PDFExporter.Settings()
        settings.ocr = false
        settings.matchScanResolution = false
        settings.dpi = 72
        let outURL = Fixtures.url("erase-out-\(UUID().uuidString).pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: outURL, settings: settings)
        let rendered = try #require(PDFDocument(url: outURL)?.page(at: 0).flatMap { PDFRenderer.renderCGImage(page: $0, dpi: 72) })
        let px = grayBytes(rendered), w = rendered.width, h = rendered.height
        func values(_ box: CropRect) -> [UInt8] {
            let x0 = max(0, Int(box.minX * Double(w))), y0 = max(0, Int(box.minY * Double(h)))
            let x1 = min(w, Int(box.maxX * Double(w))), y1 = min(h, Int(box.maxY * Double(h)))
            var v: [UInt8] = []
            for y in y0..<y1 { for x in x0..<x1 { v.append(px[y * w + x]) } }
            return v
        }
        let stamp = values(CropRect(x: 0.34, y: 0.34, width: 0.08, height: 0.08))
        let kept = values(CropRect(x: 0.74, y: 0.74, width: 0.08, height: 0.08))
        #expect(!stamp.isEmpty && stamp.allSatisfy { $0 > 100 }, "stamp min \(stamp.min() ?? 255)")
        #expect(!kept.isEmpty && kept.contains { $0 < 60 }, "kept min \(kept.min() ?? 255)")
    }

    @Test("The export preview blanks the same place")
    @MainActor
    func previewBlanksTheStamp() throws {
        let side = 200.0
        let media = CGRect(x: 0, y: 0, width: side, height: side)
        let url = Fixtures.writePDF("erase-prev-\(UUID().uuidString).pdf", media: media, pages: [{ c in
            c.setFillColor(CGColor(gray: 0.8, alpha: 1))
            c.fill(media)
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 60, y: side - 60 - 32, width: 32, height: 32))
        }])
        let m = testModel()
        m.document = try #require(PDFDocument(url: url))
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        page.erasures = [page.erasure(for: CropRect(x: 0.26, y: 0.26, width: 0.24, height: 0.24))]
        let image = try #require(m.outputPreview(for: page).first)
        let px = grayBytes(image), w = image.width, h = image.height
        let x0 = Int(0.34 * Double(w)), y0 = Int(0.34 * Double(h))
        let x1 = Int(0.42 * Double(w)), y1 = Int(0.42 * Double(h))
        var dark = 0
        for y in y0..<y1 { for x in x0..<x1 where px[y * w + x] < 100 { dark += 1 } }
        #expect(dark == 0 && x1 > x0, "\(dark) dark pixels in \(w)x\(h)")
    }

    @Test("Add, remove and clear are each one undo; a drag that moves a box is one undo")
    @MainActor
    func undoSteps() {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        let page = BookPage(sourceIndex: 0, classification: .single, analyzed: true)
        m.pages = [page, BookPage(sourceIndex: 1, classification: .single, analyzed: true)]
        m.selectedPageID = page.id
        m.beginErase()

        // Dyadic fractions, so clamping (max edge minus min edge) stays bit-identical.
        let box = CropRect(x: 0.125, y: 0.25, width: 0.25, height: 0.125)
        let box2 = CropRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)
        undoable(undo) { m.addErasure(box) }
        #expect(rects(m.pages[0]) == [box])
        undo.undo()
        #expect(m.pages[0].erasures == nil && !undo.canUndo)

        // Under 0.3% of the page in either direction: not a box, and not an undo.
        // No undo group here: an empty group just after an undo turns canUndo back on.
        m.addErasure(CropRect(x: 0.125, y: 0.125, width: 1.0 / 512, height: 0.25))
        #expect(m.pages[0].erasures == nil && !undo.canUndo)
        // Hung off the page: the part on the page is what is kept.
        let kept = CropRect(x: 0, y: 0, width: 0.1875, height: 0.09375)
        undoable(undo) { m.addErasure(CropRect(x: -0.0625, y: -0.03125, width: 0.25, height: 0.125)) }
        #expect(rects(m.pages[0]) == [kept])
        undo.undo()

        undoable(undo) { m.addErasure(box) }
        undoable(undo) { m.addErasure(box2) }
        #expect(rects(m.pages[0]) == [box, box2])
        m.selectedErasure = 0
        undoable(undo) { m.removeSelectedErasure() }
        #expect(rects(m.pages[0]) == [box2])
        undo.undo()
        #expect(rects(m.pages[0]) == [box, box2])

        undoable(undo) { m.clearErasures() }
        #expect(m.pages[0].erasures == nil)
        undo.undo()
        #expect(rects(m.pages[0]) == [box, box2])

        let moved = CropRect(x: 0.25, y: 0.25, width: 0.25, height: 0.125)
        undoable(undo) {
            m.beginEdit()
            m.setErasure(CropRect(x: 0.15, y: 0.2, width: 0.3, height: 0.15), at: 0)
            m.setErasure(moved, at: 0)
            m.endEdit("Adjust Crop")
        }
        #expect(rects(m.pages[0]) == [moved, box2])
        undo.undo()
        #expect(rects(m.pages[0]) == [box, box2])          // both moves, one step
        undo.undo()
        #expect(rects(m.pages[0]) == [box])                // the second add, not another move
    }

    @Test("Erasing ends when another page is selected or a trim starts, and a skipped page can't")
    @MainActor
    func modeEnds() {
        let m = testModel()
        let first = BookPage(sourceIndex: 0, classification: .single, analyzed: true)
        let second = BookPage(sourceIndex: 1, classification: .single, analyzed: true)
        m.pages = [first, second]
        m.selectedPageID = first.id
        m.beginErase()
        #expect(m.erasingPage == first.id)
        m.selectedPageID = second.id
        #expect(m.erasingPage == nil)

        m.selectedPageID = first.id
        m.beginErase()
        m.beginTrim()
        #expect(m.erasingPage == nil && m.trimmingPage == first.id)

        m.cancelTrim()
        m.pages[0].classification = .skip
        m.beginErase()
        #expect(m.erasingPage == nil)
    }

    @Test("A saved project keeps its erasures, and a page saved without the key decodes with none")
    func savesRoundTrip() throws {
        _ = Fixtures.directory
        var page = BookPage(sourceIndex: 2, classification: .single, leftCrop: .full, analyzed: true)
        let box = CropRect(x: 0.12, y: 0.34, width: 0.2, height: 0.05)
        page.erasures = [page.erasure(for: box)]
        let key = "erase-\(UUID().uuidString)"
        try ProjectStore.save(ProjectStore.Saved(pages: [page], direction: .leftToRight), key: key)
        let loaded = try #require(ProjectStore.load(key: key))
        #expect(loaded.pages.first?.erasures == page.erasures)

        let data = try JSONEncoder().encode(BookPage(sourceIndex: 0))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "erasures")
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(BookPage.self, from: old).erasures == nil)
    }

    private func settings(flatten: Bool = false, mode: EnhanceMode = .color) -> PDFExporter.Settings {
        var s = PDFExporter.Settings()
        s.ocr = false
        s.flattenPages = flatten
        s.matchScanResolution = false
        s.dpi = 72
        s.enhanceMode = mode
        return s
    }

    /// Pixels of `g` (row 0 at the top) darker than `below`.
    private func dark(_ g: [UInt8], _ w: Int, below: UInt8) -> [(x: Int, y: Int)] {
        var out: [(Int, Int)] = []
        for i in g.indices where g[i] < below { out.append((i % w, i / w)) }
        return out
    }

    private func paint(_ g: inout [UInt8], _ w: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ v: UInt8) {
        for y in y0..<y1 { for x in x0..<x1 where x >= 0 && y >= 0 { g[y * w + x] = v } }
    }

    /// Turn `(nx, ny)` about `(px, py)` by `deg` (positive counter-clockwise), in the
    /// pixel frame `deskewedComposite` uses. Placement only: the check is the real turn.
    private func spin(_ nx: Double, _ ny: Double, _ deg: Double, _ px: Double, _ py: Double,
                      _ w: Double, _ h: Double) -> (Double, Double) {
        if abs(deg) <= 0.01 { return (nx, ny) }
        let t = deg * .pi / 180, c = cos(t), s = sin(t)
        let ox = (nx - px) * w, oy = (ny - py) * h
        return (px + (ox * c + oy * s) / w, py + (-ox * s + oy * c) / h)
    }

    @Test("With Flatten pages on, an erased stamp is gone where the warp carries it, and text that slides into its box stays")
    @MainActor
    func flattenErasesTheStamp() throws {
        var leaf = try FlattenTests.liftedLeaf()
        let w = leaf.w, h = leaf.h
        // A stamp by the gutter, high on the page, on a whitened pad so the ring is paper.
        // Flattening lifts the lines here, so the stamp leaves the box it was drawn in.
        let sx0 = w - 150, sy0 = 36, sx1 = sx0 + 48, sy1 = sy0 + 36
        FlattenTests.paint(&leaf.g, w, sx0 - 6, sy0 - 6, sx1 + 6, sy1 + 6, 255)
        var stamped = leaf.g
        FlattenTests.paint(&stamped, w, sx0, sy0, sx1, sy1, 0)
        let region = CGRect(x: 0, y: 0, width: w, height: h)
        let flatClean = try #require(Flatten.pages(FlattenTests.image(leaf.g, w, h), regions: [(region, true)])?.image)
        let flatStamp = try #require(Flatten.pages(FlattenTests.image(stamped, w, h), regions: [(region, true)])?.image)
        let gClean = HillClimb.gray(flatClean), gStamp = HillClimb.gray(flatStamp)
        let moved = (0..<gClean.count).filter { gStamp[$0] < 80 && gClean[$0] > 180 }
        let outside = moved.filter { i in
            let x = i % w, y = i / w
            return x < sx0 || x >= sx1 || y < sy0 || y >= sy1
        }
        #expect(outside.count > 30, "stamp did not leave its box (\(outside.count) of \(moved.count))")
        // A mark just outside the box that the same warp drops inside it. Erasing after the
        // warp paints the box and takes the mark with it.
        let model = try #require(Flatten.model(gray: stamped, width: w, height: h, region: (0, 0, w, h), gutterOnRight: true))
        var from: [(Int, Int)] = []
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: max(0, sx0 - 70), to: min(w, sx1 + 70), by: 2) {
                if x >= sx0 - 2 && x < sx1 + 2 && y >= sy0 - 2 && y < sy1 + 2 { continue }
                let p = model.forward(Double(x), Double(y))
                let ox = Int(p.x.rounded()), oy = Int(p.y.rounded())
                if ox >= sx0 + 2 && ox < sx1 - 2 && oy >= sy0 + 2 && oy < sy1 - 2 { from.append((x, y)) }
            }
        }
        #expect(from.count > 12, "nothing outside the box lands in it (\(from.count))")
        for p in from { FlattenTests.paint(&stamped, w, p.0, p.1, p.0 + 1, p.1 + 1, 0) }
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        page.erasures = [page.erasure(for: CropRect(x: Double(sx0) / Double(w), y: Double(sy0) / Double(h),
                                  width: Double(sx1 - sx0) / Double(w), height: Double(sy1 - sy0) / Double(h)))]
        let rendered = FlattenTests.image(stamped, w, h)
        let made = try #require(PDFExporter.outputImages(of: page, rendered: rendered, settings: settings(flatten: true))?.first)
        #expect(made.width == w && made.height == h)
        let gOut = HillClimb.gray(made)
        let left = outside.filter { gOut[$0] < 100 }
        #expect(left.isEmpty, "\(left.count) stamp pixels survive the flatten")
        let landed = from.map { model.forward(Double($0.0), Double($0.1)) }
        let kept = landed.filter { p in
            let x = min(w - 1, max(0, Int(p.x.rounded()))), y = min(h - 1, max(0, Int(p.y.rounded())))
            return gOut[y * w + x] < 100
        }
        #expect(kept.count * 2 > landed.count, "ink that slid into the box: \(kept.count) of \(landed.count)")
    }

    /// A layered scan whose text layer is `bits` (1 = paper, 0 = ink), `w` × `h` at 300 DPI.
    private func writeLayered(_ name: String, _ bits: [UInt8], _ w: Int, _ h: Int) -> URL {
        let dpi = 300.0
        let pw = Double(w) * 72 / dpi, ph = Double(h) * 72 / dpi
        let jw = max(8, w / 8), jh = max(8, h / 8)
        let jpeg = LayeredFixture.jpeg(jw, jh) { _, _ in (240, 236, 220) }
        var objects: [Data] = []
        func add(_ d: Data) -> Int { objects.append(d); return objects.count }
        func stream(_ dict: String, _ body: Data) -> Data {
            var d = Data("<< \(dict) /Length \(body.count) >>\nstream\n".utf8)
            d.append(body); d.append(Data("\nendstream".utf8))
            return d
        }
        objects.append(Data())
        let tint = add(stream("/Type /XObject /Subtype /Image /Width \(jw) /Height \(jh) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg))
        let mask = add(stream("/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ImageMask true /BitsPerComponent 1", Data(bits)))
        let content = "q \(pw) 0 0 \(ph) 0 0 cm /P0 Do Q\nq 0.08 g \(pw) 0 0 \(ph) 0 0 cm /T Do Q\n"
        let contents = add(stream("", Data(content.utf8)))
        let page = add(Data("<< /Type /Page /Parent 1 0 R /MediaBox [0 0 \(pw) \(ph)] /Resources << /XObject << /P0 \(tint) 0 R /T \(mask) 0 R >> >> /Contents \(contents) 0 R >>".utf8))
        objects[0] = Data("<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>".utf8)
        let catalog = add(Data("<< /Type /Catalog /Pages 1 0 R >>".utf8))
        var file = Data("%PDF-1.4\n%\u{e2}\u{e3}\u{cf}\u{d3}\n".utf8)
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(file.count)
            file.append(Data("\(i + 1) 0 obj\n".utf8)); file.append(o); file.append(Data("\nendobj\n".utf8))
        }
        let xref = file.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root \(catalog) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        file.append(Data(table.utf8))
        let url = Fixtures.url(name)
        try! file.write(to: url)
        return url
    }

    @Test("A layered scan exports without a mark its box covered, including once Flatten pages has moved the mark")
    @MainActor
    func layeredExportDropsTheMark() throws {
        // The curled leaf Flatten straightens, as the text layer of a layered scan, with a
        // stamp on paper by the gutter. Flattening carries the stamp out of the box.
        var leaf = try FlattenTests.liftedLeaf()
        let w = leaf.w, h = leaf.h
        let sx0 = w - 150, sy0 = 36, sx1 = sx0 + 48, sy1 = sy0 + 36
        var clean = leaf.g
        FlattenTests.paint(&clean, w, sx0 - 6, sy0 - 6, sx1 + 6, sy1 + 6, 255)
        var stamped = clean
        FlattenTests.paint(&stamped, w, sx0, sy0, sx1, sy1, 0)
        func sharp(_ g: [UInt8]) -> [UInt8] { g.map { $0 < 140 ? 0 : 255 } }
        let scan = sharp(stamped), bare = sharp(clean)
        let region = CGRect(x: 0, y: 0, width: w, height: h)
        let flatScan = Flatten.pages(FlattenTests.image(scan, w, h), regions: [(region, true)])?.image
        let flatBare = Flatten.pages(FlattenTests.image(bare, w, h), regions: [(region, true)])?.image
        let why = Flatten.report(scan, width: w, height: h, gutterOnRight: true)
        #expect(flatScan != nil && flatBare != nil, "\(why.outcome) \(why.note)")
        guard let flatScan, let flatBare else { return }
        let gScan = HillClimb.gray(flatScan), gBare = HillClimb.gray(flatBare)
        let moved = (0..<gScan.count).filter { gScan[$0] < 80 && gBare[$0] > 180 }
        let outside = moved.filter { i in
            let x = i % w, y = i / w
            return x < sx0 || x >= sx1 || y < sy0 || y >= sy1
        }
        #expect(outside.count > 20, "mark did not leave its box (\(outside.count))")
        let box = CropRect(x: Double(sx0) / Double(w), y: Double(sy0) / Double(h),
                           width: Double(sx1 - sx0) / Double(w), height: Double(sy1 - sy0) / Double(h))
        let rowBytes = (w + 7) / 8
        var bits = [UInt8](repeating: 0xFF, count: rowBytes * h)
        for y in 0..<h { for x in 0..<w where scan[y * w + x] == 0 {
            bits[y * rowBytes + x / 8] &= ~UInt8(0x80 >> (x % 8))
        } }
        let url = writeLayered("erase-layered-\(UUID().uuidString).pdf", bits, w, h)
        let doc = try #require(PDFDocument(url: url))
        #expect(LayeredScan.layers(of: doc.page(at: 0)!) != nil)
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        page.erasures = [page.erasure(for: box)]
        var set = settings(flatten: true)
        set.dpi = 300
        let outURL = Fixtures.url("erase-layered-out-\(UUID().uuidString).pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: outURL, settings: set)
        let made = try #require(PDFDocument(url: outURL)?.page(at: 0))
        let again = HillClimb.gray(try #require(PDFRenderer.renderCGImage(page: made, dpi: 300)))
        #expect(again.count == w * h, "\(again.count)")
        let left = outside.filter { again[$0] < 128 }
        #expect(left.count * 4 < outside.count, "\(left.count) of \(outside.count) mark pixels remain")
    }

    @Test("A box drawn over a mark still blanks it after that side is skewed 1°, and the paper it used to cover stays")
    @MainActor
    func skewKeepsTheMarkBlank() throws {
        let w = 1600, h = 360, paper: UInt8 = 220
        let ax = 20, ay = 20, n = 9
        var stamp = [UInt8](repeating: paper, count: w * h)
        paint(&stamp, w, ax, ay, ax + n, ay + n, 0)
        let turned = ImageTransform.deskewedComposite(grayImage(stamp, w, h), splitX: 0.5,
                                                     leftDegrees: 1, rightDegrees: 0, isSpread: false)
        let moved = dark(grayBytes(turned), w, below: 40)
        let movedOut = moved.filter { $0.x < ax || $0.x >= ax + n || $0.y < ay || $0.y >= ay + n }
        #expect(movedOut.count >= 4, "the mark barely moved (\(moved.count) dark, \(movedOut.count) outside)")
        // A second mark that the 1° turn drops into the box as it was drawn.
        let cx = (Double(ax) + Double(n) / 2) / Double(w), cy = (Double(ay) + Double(n) / 2) / Double(h)
        let back = spin(cx, cy, -1, 0.5, 0.5, Double(w), Double(h))
        let bx = Int((back.0 * Double(w) - Double(n) / 2).rounded()), by = Int((back.1 * Double(h) - Double(n) / 2).rounded())
        var witness = [UInt8](repeating: paper, count: w * h)
        paint(&witness, w, bx, by, bx + n, by + n, 0)
        let landed = ImageTransform.deskewedComposite(grayImage(witness, w, h), splitX: 0.5,
                                                      leftDegrees: 1, rightDegrees: 0, isSpread: false)
        let wit = dark(grayBytes(landed), w, below: 40)
        let clear = wit.allSatisfy { p in moved.allSatisfy { max(abs(p.x - $0.x), abs(p.y - $0.y)) > 3 } }
        let inOld = wit.allSatisfy { $0.x >= ax && $0.x < ax + n && $0.y >= ay && $0.y < ay + n }
        #expect(!wit.isEmpty && inOld && clear, "witness \(wit.count) inOld \(inOld) clear \(clear) at \(bx),\(by)")
        var both = stamp
        for i in witness.indices where witness[i] == 0 { both[i] = 0 }
        let m = testModel()
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        m.pages = [page]
        m.selectedPageID = m.pages[0].id
        m.beginErase()
        m.addErasure(CropRect(x: Double(ax) / Double(w), y: Double(ay) / Double(h),
                              width: Double(n) / Double(w), height: Double(n) / Double(h)))
        m.pages[0].leftSkew = 1
        page = m.pages[0]
        let out = try #require(PDFExporter.outputImages(of: page, rendered: grayImage(both, w, h), settings: settings())?.first)
        #expect(out.width == w && out.height == h)
        let g = grayBytes(out)
        #expect(moved.allSatisfy { g[$0.y * w + $0.x] > 160 }, "mark still dark")
        #expect(wit.allSatisfy { g[$0.y * w + $0.x] < 80 }, "the paper the box used to cover was blanked")
    }

    @Test("A box on a spread still blanks its mark after the split moves, and the paper it used to cover stays")
    @MainActor
    func splitKeepsTheMarkBlank() throws {
        let w = 800, h = 400, paper: UInt8 = 220
        let ax = 40, ay = 60, n = 8
        let left: Double = 12, right: Double = -5
        var stamp = [UInt8](repeating: paper, count: w * h)
        paint(&stamp, w, ax, ay, ax + n, ay + n, 0)
        func deskew(_ px: [UInt8], _ split: Double) -> CGImage {
            ImageTransform.deskewedComposite(grayImage(px, w, h), splitX: split,
                                            leftDegrees: left, rightDegrees: right, isSpread: true)
        }
        let shown = deskew(stamp, 0.5)
        let there = dark(grayBytes(shown), w, below: 40)
        let bx0 = there.map(\.x).min()!, by0 = there.map(\.y).min()!
        let bx1 = there.map(\.x).max()! + 1, by1 = there.map(\.y).max()! + 1
        let now = dark(grayBytes(deskew(stamp, 0.30)), w, below: 40)
        let leftBehind = now.filter { $0.x < bx0 || $0.x >= bx1 || $0.y < by0 || $0.y >= by1 }
        #expect(leftBehind.count >= 4, "split did not move the mark (\(leftBehind.count) of \(now.count))")
        // Witness: lands in the box as drawn, and clear of where the mark goes.
        let splitPx = Double(max(1, min(w - 1, Int(0.30 * Double(w)))))
        let midX = (Double(bx0 + bx1) / 2) / Double(w), midY = (Double(by0 + by1) / 2) / Double(h)
        let pivot = (splitPx / 2) / Double(w)
        let raw = spin(midX, midY, -left, pivot, 0.5, Double(w), Double(h))
        let wx = Int((raw.0 * Double(w) - Double(n) / 2).rounded()), wy = Int((raw.1 * Double(h) - Double(n) / 2).rounded())
        var witness = [UInt8](repeating: paper, count: w * h)
        paint(&witness, w, wx, wy, wx + n, wy + n, 0)
        let wit = dark(grayBytes(deskew(witness, 0.30)), w, below: 40)
        let inOld = wit.allSatisfy { $0.x >= bx0 && $0.x < bx1 && $0.y >= by0 && $0.y < by1 }
        let clear = wit.allSatisfy { p in now.allSatisfy { max(abs(p.x - $0.x), abs(p.y - $0.y)) > 3 } }
        #expect(!wit.isEmpty && inOld && clear, "witness \(wit.count) inOld \(inOld) clear \(clear) at \(wx),\(wy)")
        var both = stamp
        for i in witness.indices where witness[i] == 0 { both[i] = 0 }
        let m = testModel()
        var page = BookPage(sourceIndex: 0, classification: .spread, splitX: 0.5,
                            leftCrop: .full, rightCrop: CropRect(x: 0.5, y: 0, width: 0.5, height: 1),
                            leftSkew: left, rightSkew: right, analyzed: true)
        m.pages = [page]
        m.selectedPageID = m.pages[0].id
        m.beginErase()
        m.addErasure(CropRect(x: Double(bx0) / Double(w), y: Double(by0) / Double(h),
                              width: Double(bx1 - bx0) / Double(w), height: Double(by1 - by0) / Double(h)))
        m.pages[0].splitX = 0.30
        let out = try #require(PDFExporter.outputImages(of: m.pages[0], rendered: grayImage(both, w, h), settings: settings())?.first)
        #expect(out.width == w && out.height == h)
        let g = grayBytes(out)
        #expect(now.allSatisfy { g[$0.y * w + $0.x] > 160 }, "mark still dark")
        #expect(wit.allSatisfy { g[$0.y * w + $0.x] < 80 }, "the paper the box used to cover was blanked")
    }

    @Test("A box exactly over a mark at a fractional crop edge leaves no dark pixel")
    func fractionalCropEdgeLeavesNoSliver() throws {
        let w = 100, h = 40, paper: UInt8 = 180
        var src = [UInt8](repeating: paper, count: w * h)
        for x in 20..<30 { src[10 * w + x] = 0 }
        src[10 * w + 19] = 0
        src[10 * w + 30] = 0
        // The crop starts at 19.6, so cutting on whole pixels takes in column 19 and, at the
        // far side, column 30. The box is exactly the mark, columns 20..<30.
        var page = BookPage(sourceIndex: 0, classification: .single,
                            leftCrop: CropRect(x: 19.6 / 100, y: 0, width: 40.0 / 100, height: 1), analyzed: true)
        page.erasures = [page.erasure(for: CropRect(x: 20.0 / 100, y: 10.0 / 40, width: 10.0 / 100, height: 1.0 / 40))]
        let out = try #require(PDFExporter.outputImages(of: page, rendered: grayImage(src, w, h), settings: settings())?.first)
        let g = grayBytes(out)
        let dark = g.indices.filter { g[$0] < 80 }
        #expect(dark.isEmpty, "dark at \(dark.prefix(6).map { ($0 % out.width, $0 / out.width) })")
    }

    @Test("A ring that is half black and half white is filled white, not a gray between them")
    func bitonalRingFillsWhite() {
        let w = 20, h = 20
        var src = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 10..<w { src[y * w + x] = 255 } }
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        // Columns 3..<10 of the ring are black and 10..<17 white: 66 and 66.
        page.erasures = [page.erasure(for: CropRect(x: 6.0 / 20, y: 6.0 / 20, width: 8.0 / 20, height: 8.0 / 20))]
        let out = grayBytes(PDFExporter.erased(grayImage(src, w, h), page: page))
        #expect(out[10 * w + 8] == 255, "filled \(out[10 * w + 8])")
        #expect(out[10 * w + 12] == 255, "filled \(out[10 * w + 12])")
    }

    @Test("An exported black-and-white page with that ring still encodes 1 bit, and the blank is white")
    func bitonalExportStaysOneBit() throws {
        // White paper, and a solid black block filling exactly half the box's ring, so the
        // fill is the gray between black and white unless the bitonal rule picks white.
        // The block is thick enough that black and white keeps it.
        let w = 120, h = 90
        var src = [UInt8](repeating: 255, count: w * h)
        let x0 = 46, y0 = 32, x1 = 74, y1 = 58
        var ring: [(Int, Int)] = []
        for y in (y0 - 3)..<(y1 + 3) {
            for x in (x0 - 3)..<(x1 + 3) {
                if x >= x0 && x < x1 && y >= y0 && y < y1 { continue }
                ring.append((x, y))
            }
        }
        #expect(ring.count % 2 == 0)
        for p in ring.prefix(ring.count / 2) { src[p.1 * w + p.0] = 0 }
        let image = grayImage(src, w, h)
        let media = CGRect(x: 0, y: 0, width: Double(w), height: Double(h))
        let url = Fixtures.writePDF("erase-bits-\(UUID().uuidString).pdf", media: media, pages: [{ c in
            c.draw(image, in: media)
        }])
        let doc = try #require(PDFDocument(url: url))
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        page.erasures = [page.erasure(for: CropRect(x: Double(x0) / Double(w), y: Double(y0) / Double(h),
                                  width: Double(x1 - x0) / Double(w), height: Double(y1 - y0) / Double(h)))]
        let set = settings(mode: .blackAndWhite)
        let outURL = Fixtures.url("erase-bits-out-\(UUID().uuidString).pdf")
        _ = try PDFExporter.export(pages: [page], from: doc, to: outURL, settings: set)
        let depths = imageDepths(outURL)
        #expect(depths == [1], "\(depths)")
        let made = try #require(PDFDocument(url: outURL)?.page(at: 0))
        let again = grayBytes(try #require(PDFRenderer.renderCGImage(page: made, dpi: 72)))
        #expect(again.count == w * h)
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        #expect(again[cy * w + cx] > 200, "blank \(again[cy * w + cx])")
    }

    /// Bits per component of each image the page draws.
    private func imageDepths(_ url: URL) -> [Int] {
        guard let doc = CGPDFDocument(url as CFURL), let p = doc.page(at: 1), let dict = p.dictionary else { return [] }
        var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res,
              CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return [] }
        var depths: [Int] = []
        CGPDFDictionaryApplyBlock(xo, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) {
                var bpc: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(d, "BitsPerComponent", &bpc)
                depths.append(bpc)
            }
            return true
        }, nil)
        return depths
    }

    @Test("Undo restores the boxes and clears a selection that pointed at the old list")
    @MainActor
    func undoClearsTheSelection() {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        let page = BookPage(sourceIndex: 0, classification: .single, analyzed: true)
        m.pages = [page]
        m.selectedPageID = page.id
        m.beginErase()
        let a = CropRect(x: 0.10, y: 0.10, width: 0.20, height: 0.20)
        let b = CropRect(x: 0.40, y: 0.10, width: 0.20, height: 0.20)
        let c = CropRect(x: 0.70, y: 0.10, width: 0.20, height: 0.20)
        undoable(undo) { m.addErasure(a) }
        undoable(undo) { m.addErasure(b) }
        undoable(undo) { m.addErasure(c) }
        m.selectedErasure = 0
        undoable(undo) { m.removeSelectedErasure() }
        #expect(m.pages[0].erasures?.count == 2)
        m.selectedErasure = 1
        undo.undo()
        #expect(m.selectedErasure == nil)
        #expect(m.pages[0].erasures?.count == 3)
    }

    @Test("Erase from the grid opens the page, and Done returns to the grid")
    @MainActor
    func eraseFromGridShowsThePage() {
        let m = testModel()
        let page = BookPage(sourceIndex: 0, classification: .single, analyzed: true)
        m.pages = [page]
        m.selectedPageID = page.id
        m.viewMode = .grid
        m.beginErase()
        #expect(m.viewMode == .page && m.erasingPage == page.id)
        m.finishErase()
        #expect(m.viewMode == .grid && m.erasingPage == nil)
    }

    @Test("A box's centre follows the straightening it was drawn on")
    func centreFollowsThePage() {
        let w = 200, h = 120
        // Pixel (30, 20), the centre. 8° about the page's centre lands at (25.11, 30.13).
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        let rect = CropRect(x: (30 - 4) / Double(w), y: (20 - 3) / Double(h),
                            width: 8 / Double(w), height: 6 / Double(h))
        page.erasures = [page.erasure(for: rect)]
        #expect(page.erasureRects(width: w, height: h) == [rect])
        page.leftSkew = 8
        let moved = page.erasureRects(width: w, height: h)[0]
        let cx = (moved.x + moved.width / 2) * Double(w), cy = (moved.y + moved.height / 2) * Double(h)
        #expect(abs(cx - 25.11) < 0.2 && abs(cy - 30.13) < 0.2, "\(cx), \(cy)")

        // Left half 90 px wide, 12° about that half's centre: (30, 20) lands at (22.01, 23.99).
        var spread = BookPage(sourceIndex: 0, classification: .spread, splitX: 90.0 / 200,
                              leftCrop: .full, analyzed: true)
        spread.erasures = [spread.erasure(for: rect)]
        spread.leftSkew = 12
        let half = spread.erasureRects(width: w, height: h)[0]
        let hx = (half.x + half.width / 2) * Double(w), hy = (half.y + half.height / 2) * Double(h)
        #expect(abs(hx - 22.01) < 0.2 && abs(hy - 23.99) < 0.2, "\(hx), \(hy)")

        // Stored on the turned page, the same centre comes back when the skew is cleared.
        var back = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, leftSkew: 8, analyzed: true)
        back.erasures = [Erasure(rect: moved, splitX: back.splitX, leftSkew: 8, rightSkew: 0, spread: false)]
        back.leftSkew = 0
        let home = back.erasureRects(width: w, height: h)[0]
        let ux = (home.x + home.width / 2) * Double(w), uy = (home.y + home.height / 2) * Double(h)
        #expect(abs(ux - 30) < 0.2 && abs(uy - 20) < 0.2, "\(ux), \(uy)")
    }

    @Test("A save that stored erasures as plain rects decodes them in that page's frame")
    func oldErasureArrayDecodesInThePageFrame() throws {
        var page = BookPage(sourceIndex: 3, classification: .spread, splitX: 0.42,
                            leftSkew: 1.5, rightSkew: -2, analyzed: true)
        let data = try JSONEncoder().encode(page)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["erasures"] = [["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.15]]
        let old = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(BookPage.self, from: old)
        let box = try #require(back.erasures?.first)
        #expect(box.rect == CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.15))
        #expect(box.splitX == 0.42 && box.leftSkew == 1.5 && box.rightSkew == -2 && box.spread)
    }
}
