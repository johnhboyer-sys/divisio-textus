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

    @Test("A black stamp on grey paper is filled with the ring's grey; the rest stays")
    func stampBecomesPaper() {
        let w = 128, h = 64, paper: UInt8 = 180
        var src = [UInt8](repeating: paper, count: w * h)
        for y in 16..<32 { for x in 32..<64 { src[y * w + x] = 0 } }   // the stamp
        src[4 * w + 4] = 0                                              // a mark outside the box
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        // The box covers the stamp with room, so the ring is paper, not the stamp.
        page.erasures = [CropRect(x: 24.0 / 128, y: 8.0 / 64, width: 48.0 / 128, height: 32.0 / 64)]
        let out = grayBytes(PDFExporter.erased(grayImage(src, w, h), page: page, crop: .full))
        var want = src
        for y in 8..<40 { for x in 24..<72 { want[y * w + x] = paper } }
        #expect(out == want, Comment(rawValue: mismatches(out, want, w)))
    }

    @Test("A box that covers the whole crop, so the ring is empty, is filled white")
    func emptyRingIsWhite() {
        let w = 16, h = 16
        let src = [UInt8](repeating: 40, count: w * h)
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: .full, analyzed: true)
        page.erasures = [.full]
        let out = grayBytes(PDFExporter.erased(grayImage(src, w, h), page: page, crop: .full))
        #expect(out.allSatisfy { $0 == 255 })
    }

    @Test("A box partly inside the crop is clipped to it; one outside the crop changes nothing")
    func clippedToTheCrop() {
        let w = 80, h = 40, paper: UInt8 = 160
        var src = [UInt8](repeating: paper, count: w * h)
        for y in 10..<20 {
            for x in 48..<80 { src[y * w + x] = 0 }                    // straddles the erasure's left edge
        }
        src[2 * w + 2] = 0
        let image = grayImage(src, w, h)
        // This image is the left half of the page. The box runs from 0.375 to 0.625, so
        // only 0.375...0.5 of the page — pixels 60..<80 — is on this crop.
        let crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: crop, analyzed: true)
        page.erasures = [CropRect(x: 0.375, y: 0.25, width: 0.25, height: 0.25)]
        let out = grayBytes(PDFExporter.erased(image, page: page, crop: crop))
        var want = src
        for y in 10..<20 { for x in 60..<80 { want[y * w + x] = paper } }
        #expect(out == want, Comment(rawValue: mismatches(out, want, w)))

        page.erasures = [CropRect(x: 0.625, y: 0.25, width: 0.25, height: 0.25)]   // the other half
        let same = grayBytes(PDFExporter.erased(image, page: page, crop: crop))
        #expect(same == grayBytes(image), Comment(rawValue: mismatches(same, grayBytes(image), w)))
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
        page.erasures = [CropRect(x: 0.26, y: 0.26, width: 0.24, height: 0.24)]
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
        page.erasures = [CropRect(x: 0.26, y: 0.26, width: 0.24, height: 0.24)]
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
        #expect(m.pages[0].erasures == [box])
        undo.undo()
        #expect(m.pages[0].erasures == nil && !undo.canUndo)

        // Under 0.3% of the page in either direction: not a box, and not an undo.
        // No undo group here: an empty group just after an undo turns canUndo back on.
        m.addErasure(CropRect(x: 0.125, y: 0.125, width: 1.0 / 512, height: 0.25))
        #expect(m.pages[0].erasures == nil && !undo.canUndo)
        // Hung off the page: the part on the page is what is kept.
        let kept = CropRect(x: 0, y: 0, width: 0.1875, height: 0.09375)
        undoable(undo) { m.addErasure(CropRect(x: -0.0625, y: -0.03125, width: 0.25, height: 0.125)) }
        #expect(m.pages[0].erasures == [kept])
        undo.undo()

        undoable(undo) { m.addErasure(box) }
        undoable(undo) { m.addErasure(box2) }
        #expect(m.pages[0].erasures == [box, box2])
        m.selectedErasure = 0
        undoable(undo) { m.removeSelectedErasure() }
        #expect(m.pages[0].erasures == [box2])
        undo.undo()
        #expect(m.pages[0].erasures == [box, box2])

        undoable(undo) { m.clearErasures() }
        #expect(m.pages[0].erasures == nil)
        undo.undo()
        #expect(m.pages[0].erasures == [box, box2])

        let moved = CropRect(x: 0.25, y: 0.25, width: 0.25, height: 0.125)
        undoable(undo) {
            m.beginEdit()
            m.setErasure(CropRect(x: 0.15, y: 0.2, width: 0.3, height: 0.15), at: 0)
            m.setErasure(moved, at: 0)
            m.endEdit("Adjust Crop")
        }
        #expect(m.pages[0].erasures == [moved, box2])
        undo.undo()
        #expect(m.pages[0].erasures == [box, box2])          // both moves, one step
        undo.undo()
        #expect(m.pages[0].erasures == [box])                // the second add, not another move
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
        page.erasures = [box]
        let key = "erase-\(UUID().uuidString)"
        try ProjectStore.save(ProjectStore.Saved(pages: [page], direction: .leftToRight), key: key)
        let loaded = try #require(ProjectStore.load(key: key))
        #expect(loaded.pages.first?.erasures == [box])

        let data = try JSONEncoder().encode(BookPage(sourceIndex: 0))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "erasures")
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(BookPage.self, from: old).erasures == nil)
    }
}
