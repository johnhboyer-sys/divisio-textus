import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import PDFCropper

/// Whole page: the split goes on the fold, and the binding's shading is no
/// text, so every page comes out the book's size; print is never cut.
@Suite("Whole page: the fold and the gutter's shading", .serialized)
@MainActor
struct FoldTests {

    /// Twelve spreads of two 6 × 9 in sheets on a black bed (14 × 10 in scans),
    /// like PageSizeTests.Book without the leaves' strips. Most meet at a black
    /// fold, where the split is found. Two do not:
    /// - `offFold`: no fold line, the left page's text runs to 10 pt from the
    ///   fold and the right page's starts 60 pt from it, so the split is found
    ///   in the middle of that gap, off the fold.
    /// - `shaded`: the same, the fold further right so the right sheet runs off
    ///   the scan (no edge there: the fold can't be found), and the binding's
    ///   shading (see `speckle`) on the right page's inner margin, which lands
    ///   in the left half.
    struct Book {
        static let media = CGRect(x: 0, y: 0, width: 1008, height: 720)
        static let sheetW = 432.0, sheetH = 648.0, top = 36.0
        static let offFold = 2, shaded = 6
        static let shifts: [Double] = [0, 6, -5, 3, -8, 2, 0, -3, 7, -6, 0, 4]

        static func fold(_ i: Int) -> Double { i == shaded ? 590 : 504 + shifts[i] }

        static func write() -> URL {
            let pages: [(CGContext) -> Void] = (0..<12).map { i in { c in draw(i, c) } }
            return Fixtures.writePDF("fold-\(UUID().uuidString).pdf", media: media, pages: pages)
        }

        private static func draw(_ i: Int, _ c: CGContext) {
            let H = media.height
            func fill(_ gray: Double, _ x: Double, _ yTop: Double, _ w: Double, _ h: Double) {
                c.setFillColor(CGColor(gray: gray, alpha: 1))
                c.fill(CGRect(x: x, y: H - yTop - h, width: w, height: h))
            }
            fill(0.04, 0, 0, media.width, H)
            let f = fold(i), w = sheetW, h = sheetH
            fill(1, f - w, top, 2 * w, h)
            let odd = i == offFold || i == shaded
            if !odd { fill(0.04, f - 2, top, 4, h) }
            if i == shaded {
                // The shadow, over most of the page's height.
                speckle(40, from: f, rows: top + 0.1 * h, top + 0.8 * h) { x, y, gray in fill(gray, x, y, 1, 1) }
            }
            for t in text(i) {
                var y = t.minY
                while y + 6 <= t.maxY { fill(0.1, t.minX, y, t.width, 6); y += 14 }
            }
        }

        /// Each page's lines of type, in points from the scan's top left.
        static func text(_ i: Int) -> [CGRect] {
            let f = fold(i), odd = i == offFold || i == shaded
            let rows = (top + 54, top + 54 + 14 * floor((sheetH - 121) / 14) + 6)   // the first line's top, the last's bottom
            return [(f - sheetW + 54, odd ? f - 10 : f - 43), (odd ? f + 60 : f + 43, f + sheetW - 54)].map { x0, x1 in
                CGRect(x: x0, y: rows.0, width: x1 - x0, height: rows.1 - rows.0)
            }
        }
    }

    /// Every line of type is inside its page's crop.
    private func textKept(_ m: AppModel) {
        let W = Book.media.width, H = Book.media.height
        for (i, p) in m.pages.enumerated() {
            for (t, c) in zip(Book.text(i), [p.leftCrop, p.rightCrop]) {
                #expect(c.minX * W <= t.minX + 0.5 && c.maxX * W >= t.maxX - 0.5 && c.minY * H <= t.minY + 0.5 && c.maxY * H >= t.maxY - 0.5,
                        "spread \(i): type at \(t), crop \(c.minX * W)...\(c.maxX * W) × \(c.minY * H)...\(c.maxY * H) pt")
            }
        }
    }

    private func load() async -> (AppModel, URL) {
        let m = testModel()
        m.setCropTarget(.page)
        let url = Book.write()
        m.load(url: url)
        await waitUntilIdle(m)
        return (m, url)
    }

    @Test("A split found off the fold goes onto it, and both pages get the book's size")
    func splitOnFold() async throws {
        let (m, _) = await load()
        let W = Book.media.width
        let p = m.pages[Book.offFold], f = Book.fold(Book.offFold)
        #expect(abs(p.splitX * W - f) < 2, "split at \(p.splitX * W) pt, fold at \(f)")
        for (side, crop) in [("left", p.leftCrop), ("right", p.rightCrop)] {
            #expect(abs(crop.width * W - Book.sheetW) < 4.4, "\(side): \(crop.width * W) pt wide")
        }
        textKept(m)
    }

    @Test("The shadow on the facing page's margin is no text: the crop stops at the fold")
    func shadeLeftOut() async throws {
        let (m, _) = await load()
        let W = Book.media.width
        let p = m.pages[Book.shaded], f = Book.fold(Book.shaded)
        #expect(p.splitX * W > f + 25, "the split is still found off the fold: \(p.splitX * W) pt")
        #expect(p.leftCrop.maxX * W < f + 4, "left crop ends at \(p.leftCrop.maxX * W) pt, the fold at \(f)")
        #expect(abs(p.leftCrop.width * W - Book.sheetW) < 4.4, "left: \(p.leftCrop.width * W) pt wide")
        textKept(m)
    }

    @Test("While a spread waits to move onto the fold: a hand edit wins, undo drops the move, redo makes it")
    func editsAndUndo() async throws {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.load(url: Book.write())
        await waitUntilIdle(m)
        let before = m.pages, W = Book.media.width, f = Book.fold(Book.offFold)
        func held() async throws -> UndoDuringAnalysisTests.Gate {
            let gate = UndoDuringAnalysisTests.Gate()
            m.beforeReanalysis = { await gate.wait() }
            undoable(undo) { m.setCropTarget(.page) }
            while !gate.isWaiting { try await Task.sleep(nanoseconds: 10_000_000) }
            return gate
        }
        // Undo while the pass waits: its results are dropped, the pages are back.
        var gate = try await held()
        undo.undo()
        gate.release()
        await waitUntilIdle(m)
        #expect(m.cropTarget == .text && m.pages == before)
        // Redo detects afresh: the split goes onto the fold.
        undo.redo()
        await waitUntilIdle(m)
        #expect(m.cropTarget == .page && abs(m.pages[Book.offFold].splitX * W - f) < 2)
        undo.undo()
        await waitUntilIdle(m)
        // A hand edit made while the pass waits is kept, split and all.
        gate = try await held()
        let mark = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.5)
        undoable(undo) { m.perform("Adjust Crop") { m.pages[Book.offFold].leftCrop = mark } }
        gate.release()
        await waitUntilIdle(m)
        m.beforeReanalysis = nil
        #expect(m.pages[Book.offFold].leftCrop == mark && m.pages[Book.offFold].splitX == before[Book.offFold].splitX)
    }

    // MARK: - Print by the gutter

    /// The binding's shading as a scan shows it: pale grey, speckled darker
    /// (the scanner's dithering), the specks thinning out over `width` units
    /// from the fold at `from`, rightwards. `dot` draws one unit square.
    nonisolated static func speckle(_ width: Int, from: Double, rows top: Double, _ bottom: Double, dot: (Double, Double, Double) -> Void) {
        var seed: UInt64 = 12345
        for k in 0..<width {
            for y in stride(from: top, to: bottom, by: 1) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let dark = Double(seed >> 33) / Double(UInt64(1) << 31) < 0.3 * (1 - Double(k) / Double(width))
                dot(from + Double(k), y, dark ? 0.55 : 0.92)
            }
        }
    }

    /// Draws on a 1040 × 800 spread image (top-left coordinates), mirrored
    /// about the middle for a left-hand page; type always reads the right way.
    struct Pen {
        let c: CGContext, mirrored: Bool
        func fill(_ gray: Double, _ x: Double, _ yTop: Double, _ w: Double, _ h: Double) {
            c.setFillColor(CGColor(gray: gray, alpha: 1))
            c.fill(CGRect(x: mirrored ? 1040 - x - w : x, y: 800 - yTop - h, width: w, height: h))
        }
        /// A line of type whose top is near `yTop`, starting at `x` (ending there, mirrored).
        func text(_ s: String, x: Double, yTop: Double, size: Double, gray: Double = 0, bold: Bool = false) {
            let font = CTFontCreateWithName((bold ? "Times-Bold" : "Times-Roman") as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            c.textPosition = CGPoint(x: mirrored ? 1040 - x - width : x, y: 800 - yTop - size)
            CTLineDraw(line, c)
        }
    }

    /// A right-hand page (the right half of the spread image, split at the
    /// middle) with lines of type from x = 600, what the scan shows at the fold
    /// (`ground`; by default the binding's shading, see `speckle`, over 50 px),
    /// and whatever print `extra` draws near the gutter;
    /// `print` is that print alone, so its pixels are known.
    static func page(mirrored: Bool, ground: @escaping (Pen) -> Void = shadow,
                     extra: @escaping (Pen) -> Void) -> (image: CGImage, print: CGImage) {
        let image = Fixtures.image(1040, 800, gray: true) { c in
            let pen = Pen(c: c, mirrored: mirrored)
            ground(pen)
            for k in 0..<30 { pen.text("the substance of which is matter and form", x: 600, yTop: 90 + Double(k) * 21, size: 15) }
            extra(pen)
        }
        let print = Fixtures.image(1040, 800, gray: true) { c in extra(Pen(c: c, mirrored: mirrored)) }
        return (image, print)
    }

    nonisolated static func shadow(_ pen: Pen) {
        speckle(50, from: 520, rows: 0, 800) { x, y, gray in pen.fill(gray, x, y, 1, 1) }
    }

    /// The text block analysis gives the page (Whole page), and how many print
    /// pixels lie between it and the gutter. (Only the gutter side is in
    /// question here: the text block's other edges are the Text block detector's.)
    static func leftOut(_ case_: (image: CGImage, print: CGImage), mirrored: Bool) -> (text: CropRect, outside: Int) {
        let r = PageAnalyzer.analyze(cgImage: case_.image, as: .spread, split: 0.5, target: .page)
        let text = (mirrored ? r.leftSheet?.text : r.rightSheet?.text) ?? .full
        let g = GrayBuffer(cgImage: case_.print, maxDim: 1040)!
        var outside = 0
        for y in 0..<g.height {
            for x in 0..<g.width where g.value(x, y) < 200 {
                let nx = (Double(x) + 0.5) / Double(g.width)
                if mirrored ? nx > text.maxX : nx < text.minX { outside += 1 }
            }
        }
        return (text, outside)
    }

    @Test("The binding's shadow beside the text is left out of the text block", arguments: [false, true])
    func shadowLeftOut(_ mirrored: Bool) {
        let (text, _) = Self.leftOut(Self.page(mirrored: mirrored) { _ in }, mirrored: mirrored)
        // The type starts 80 px from the fold; the shadow's specks thin out to
        // none by 50 px. Most of it is left out (a few of its last specks can
        // pass for print, and keep a little of it in).
        if mirrored { #expect(text.maxX * 1040 < 480, "text block ends at \(text.maxX * 1040) px") }
        else { #expect(text.minX * 1040 > 560, "text block starts at \(text.minX * 1040) px") }
    }

    /// Print in or beside the shadow, as books have it.
    nonisolated(unsafe) static let printByTheGutter: [(String, (Pen) -> Void)] = [
        ("Bekker numbers in the shadow", { pen in
            for (k, s) in ["1094a", "5", "10", "15", "20", "1094b"].enumerated() { pen.text(s, x: 527, yTop: 110 + Double(k) * 105, size: 13) }
        }),
        ("numbers beside a vertical rule", { pen in
            pen.fill(0, 530, 60, 2, 680)
            for (k, s) in ["5", "10", "15", "20", "25"].enumerated() { pen.text(s, x: 538, yTop: 130 + Double(k) * 126, size: 13) }
        }),
        ("a heading running into the shadow", { pen in pen.text("CHAPTER ONE", x: 524, yTop: 40, size: 26, bold: true) }),
        ("a small pale folio by the shadow", { pen in pen.text("140", x: 574, yTop: 690, size: 11, gray: 0.3) }),
        ("a line of type set out into the shadow", { pen in pen.text("matter is the substrate", x: 522, yTop: 384, size: 15) }),
    ]

    @Test("Print in or beside the gutter's shadow stays in the text block",
          arguments: printByTheGutter.indices, [false, true])
    func printKept(_ index: Int, _ mirrored: Bool) {
        let (name, extra) = Self.printByTheGutter[index]
        let (text, outside) = Self.leftOut(Self.page(mirrored: mirrored, extra: extra), mirrored: mirrored)
        let found = PageAnalyzer.analyze(cgImage: Self.page(mirrored: mirrored, extra: extra).image, as: .spread, split: 0.5, target: .text)
        #expect(outside == 0, "\(name)\(mirrored ? ", left-hand page" : ""): \(outside) print pixels outside \(text); text block as found \(mirrored ? found.leftCrop : found.rightCrop)")
    }

    @Test("Type running to the fold on a tight scan stays in the text block", arguments: [false, true])
    func tightScan(_ mirrored: Bool) {
        let tight = Self.page(mirrored: mirrored, ground: { pen in pen.fill(0.05, 516, 0, 8, 800) }) { pen in   // a black fold
            for k in 0..<30 { pen.text("ing the substance of which is", x: 525, yTop: 90 + Double(k) * 21, size: 15) }
        }
        let (text, outside) = Self.leftOut(tight, mirrored: mirrored)
        #expect(outside == 0, "\(outside) print pixels outside \(text)")
    }
}
