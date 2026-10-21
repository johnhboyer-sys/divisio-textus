import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFCropper

/// Whole page: one page size for the whole book, measured on the sheets whose
/// edges can be trusted, and placed on every page without the neighbouring
/// leaves' edges.
@Suite("Book page size", .serialized)
@MainActor
struct PageSizeTests {

    /// A synthetic scanned book: spreads of two 6 × 9 in sheets meeting at a black
    /// fold, on a black scanner bed, 14 × 10 in scans. Beyond each outer edge, a
    /// strip of the neighbouring leaves' edges (grey, with dark lines). The book
    /// moves a little on the scanner from spread to spread.
    struct Book {
        static let media = CGRect(x: 0, y: 0, width: 1008, height: 720)
        static let sheetW = 432.0, sheetH = 648.0
        static let shifts: [(Double, Double)] = [(0, 0), (6, 4), (-5, -6), (3, 8), (-8, 2), (2, -4),
                                                 (5, 6), (-3, -2), (7, 0), (-6, 5), (0, -7), (4, 3)]
        /// Spread 3's right page opens a chapter (text starts low); spread 5's left
        /// page is a chapter's short last page. Those and spread 8 run off the
        /// scan's top and bottom.
        static let opening = 3, short = 5
        let count: Int
        let strips: Bool
        /// A last spread whose fold lies well right of the others and whose right
        /// page is blank: analysis moves its split to the book's usual one.
        var oddLast = false

        func fold(_ i: Int) -> Double { oddLast && i == count - 1 ? 604 : 504 + Self.shifts[i % Self.shifts.count].0 }
        /// The sheet's top, from the top of the scan.
        func top(_ i: Int) -> Double { 36 + Self.shifts[i % Self.shifts.count].1 }

        func write() -> URL {
            let pages: [(CGContext) -> Void] = (0..<count).map { i in { c in self.draw(i, c) } }
            return Fixtures.writePDF("book-\(UUID().uuidString).pdf", media: Self.media, pages: pages)
        }

        private func draw(_ i: Int, _ c: CGContext) {
            let H = Self.media.height
            func fill(_ gray: Double, _ x: Double, _ yTop: Double, _ w: Double, _ h: Double) {
                c.setFillColor(CGColor(gray: gray, alpha: 1))
                c.fill(CGRect(x: x, y: H - yTop - h, width: w, height: h))
            }
            fill(0.04, 0, 0, Self.media.width, H)                       // the bed
            let f = fold(i), t = top(i), w = Self.sheetW, h = Self.sheetH
            if strips {
                // Three leaves beyond each outer edge, a little lower than the sheet.
                for k in 0..<3 {
                    let x = f - w - 15 + Double(k) * 5
                    fill(0.8, x, t + 2, 5, h); fill(0.25, x, t + 2, 1, h)
                    let xr = f + w + Double(k) * 5
                    fill(0.8, xr, t + 2, 5, h); fill(0.25, xr + 4, t + 2, 1, h)
                }
            }
            // The two sheets. On a few spreads (the opening and short pages among
            // them) the paper runs past the scan's top and bottom: no edge there,
            // so the box must be placed from the text.
            if [Self.opening, Self.short, 8].contains(i) { fill(1, f - w, 0, 2 * w, H) }
            else { fill(1, f - w, t, 2 * w, h) }
            fill(0.04, f - 2, t, 4, h)                                  // the fold
            // Text: 0.75 in from the outer edge, 0.6 in from the fold, 0.75 in
            // from the top, 0.85 in from the bottom.
            for (x0, side) in [(f - w + 54, 0), (f + 43, 1)] {
                if oddLast && i == count - 1 && side == 1 { continue }
                var y0 = t + 54, y1 = t + h - 61
                if i == Self.opening && side == 1 { y0 = t + 260 }
                if i == Self.short && side == 0 { y1 = t + 250 }
                var y = y0
                while y + 6 <= y1 {
                    fill(0.1, x0, y, w - 97, 6)
                    y += 14
                }
                fill(0.1, x0, y1 - 6, w - 97, 6)
            }
        }
    }

    private func load(_ book: Book, target: CropTarget = .page) async -> (AppModel, UndoManager, URL) {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.setCropTarget(target)
        let url = book.write()
        m.load(url: url)
        await waitUntilIdle(m)
        return (m, undo, url)
    }

    /// A crop in points on the scan, top-left origin.
    private func points(_ c: CropRect) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        let W = Book.media.width, H = Book.media.height
        return (c.minX * W, c.minY * H, c.maxX * W, c.maxY * H)
    }

    @Test("A sheet's edge is where the neighbouring leaves begin; the scan's own border is no edge")
    func sheetEdges() throws {
        let book = Book(count: 1, strips: true)
        let doc = try #require(PDFDocument(url: book.write()))
        let cg = try #require(PDFRenderer.renderCGImage(page: doc.page(at: 0)!, dpi: 110))
        let r = PageAnalyzer.analyze(cgImage: cg, target: .page)
        let left = try #require(r.leftSheet), right = try #require(r.rightSheet)
        let W = Book.media.width, H = Book.media.height
        let minX = try #require(left.minX), maxX = try #require(right.maxX)
        #expect(abs(minX * W - (book.fold(0) - Book.sheetW)) < 2, "left edge at \(minX * W) pt")
        #expect(abs(maxX * W - (book.fold(0) + Book.sheetW)) < 2, "right edge at \(maxX * W) pt")
        let top = try #require(left.minY), bottom = try #require(left.maxY)
        #expect(abs(top * H - book.top(0)) < 2 && abs(bottom * H - book.top(0) - Book.sheetH) < 2)
        // The same page cut inside the paper: no edge there.
        let cut = try #require(PDFRenderer.crop(cg, to: CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)))
        let rc = PageAnalyzer.analyze(cgImage: cut, as: .spread, target: .page)
        #expect(rc.leftSheet?.minX == nil && rc.leftSheet?.minY == nil && rc.rightSheet?.maxX == nil,
                "\(String(describing: rc.leftSheet)) \(String(describing: rc.rightSheet)) split \(rc.splitX)")
    }

    @Test("The book's page size is measured, and every page gets it, without the leaves beyond the sheet")
    func oneSize() async throws {
        let book = Book(count: 12, strips: true)
        let (m, _, _) = await load(book)
        let size = try #require(m.pageSize)
        let w = try #require(size.width), h = try #require(size.height)
        #expect(abs(w - 6) < 0.06 && abs(h - 9) < 0.09, "measured \(w) × \(h) in")
        #expect(size.override == nil && size.measured >= 20 && size.total == 24, "\(size)")
        for (i, p) in m.pages.enumerated() {
            for (side, crop) in [("left", p.leftCrop), ("right", p.rightCrop)] {
                let c = points(crop), f = book.fold(i), t = book.top(i)
                // One size: the sheet's, within 1%.
                #expect(abs(c.x1 - c.x0 - Book.sheetW) < 4.4 && abs(c.y1 - c.y0 - Book.sheetH) < 6.5,
                        "spread \(i) \(side): \(c.x1 - c.x0) × \(c.y1 - c.y0) pt")
                // Where the sheet is, the leaves' strips left out, even where the
                // text starts low or stops short.
                #expect(abs(c.y0 - t) < 4, "spread \(i) \(side): top \(c.y0), sheet at \(t)")
                if side == "left" { #expect(c.x0 >= f - Book.sheetW - 3, "spread \(i) left: \(c.x0), sheet at \(f - Book.sheetW)") }
                else { #expect(c.x1 <= f + Book.sheetW + 3, "spread \(i) right: \(c.x1), sheet ends \(f + Book.sheetW)") }
            }
        }
    }

    @Test("A page edited by hand keeps its crop when the page size is set")
    func handEditKept() async throws {
        let (m, undo, _) = await load(Book(count: 12, strips: true))
        let edited = CropRect(x: 0.1, y: 0.1, width: 0.3, height: 0.6)
        undoable(undo) { m.perform("Adjust Crop") { m.pages[2].leftCrop = edited } }
        let before = m.pages
        undoable(undo) { m.setPageSize(PageSize(width: 5.8, height: 8.5)) }
        #expect(m.pages[2] == before[2])
        #expect(m.pages.indices.filter { m.pages[$0] != before[$0] } == m.pages.indices.filter { $0 != 2 })
    }

    @Test("The page size can be set by hand: one undo step, kept with the edits, empty goes back to measured")
    func override() async throws {
        let (m, undo, url) = await load(Book(count: 12, strips: true))
        let measured = m.pages
        undoable(undo) { m.setPageSize(PageSize(width: 5.8, height: 8.5)) }
        #expect(m.pageSize?.override == PageSize(width: 5.8, height: 8.5))
        for p in m.pages {
            for crop in [p.leftCrop, p.rightCrop] {
                let c = points(crop)
                #expect(abs(c.x1 - c.x0 - 417.6) < 1 && abs(c.y1 - c.y0 - 612) < 1, "\(c.x1 - c.x0) × \(c.y1 - c.y0) pt")
            }
        }
        let set = m.pages
        #expect(undo.undoActionName == "Set Page Size")
        undo.undo()
        #expect(m.pages == measured && m.pageSize?.override == nil)
        undo.redo()
        #expect(m.pages == set && m.pageSize?.override != nil)

        try await Task.sleep(nanoseconds: 1_200_000_000)    // autosave waits for a pause
        let reopened = testModel()
        reopened.load(url: url)
        await waitUntilIdle(reopened)
        #expect(reopened.pageSize?.override == PageSize(width: 5.8, height: 8.5))
        #expect(reopened.pages == set)
        reopened.setPageSize(nil)                           // an empty entry
        #expect(reopened.pageSize?.override == nil)
        #expect(zip(reopened.pages, measured).allSatisfy { $0.leftCrop == $1.leftCrop && $0.rightCrop == $1.rightCrop })
    }

    @Test("Too few pages to measure on: the crops are left as found")
    func tooFew() async throws {
        let book = Book(count: 4, strips: true)
        let (m, _, url) = await load(book)
        #expect(m.pageSize?.width == nil && m.pageSize?.height == nil)
        let doc = try #require(PDFDocument(url: url))
        for (i, p) in m.pages.enumerated() {
            let cg = try #require(PDFRenderer.renderCGImage(page: doc.page(at: i)!, dpi: 110))
            let a = AppModel.analyzePage(cg, deskew: true, target: .page)
            #expect(p.leftCrop == a.result.leftCrop && p.rightCrop == a.result.rightCrop)
        }
    }

    @Test("Text block crops are untouched by the page size")
    func textBlockUnchanged() async throws {
        let (m, _, url) = await load(Book(count: 12, strips: true), target: .text)
        #expect(m.pageSize == nil)
        let doc = try #require(PDFDocument(url: url))
        for (i, p) in m.pages.enumerated() where i != Book.short {
            let cg = try #require(PDFRenderer.renderCGImage(page: doc.page(at: i)!, dpi: 110))
            let a = AppModel.analyzePage(cg, deskew: true, target: .text)
            #expect(p.leftCrop == a.result.leftCrop && p.rightCrop == a.result.rightCrop)
        }
    }

    @Test("Every crop stays inside its half, even where analysis moved the split")
    func insideHalves() async throws {
        let (m, _, _) = await load(Book(count: 12, strips: true, oddLast: true))
        let last = try #require(m.pages.last)
        #expect(abs(last.splitX - 0.5) < 0.03, "the blank page's split was moved to the usual one: \(last.splitX)")
        for p in m.pages {
            #expect(p.leftCrop.maxX <= p.splitX + 1e-9 && p.rightCrop.minX >= p.splitX - 1e-9,
                    "page \(p.sourceIndex): split \(p.splitX), left \(p.leftCrop), right \(p.rightCrop)")
        }
    }

    @Test("Undoing a switch of crop target brings back the measurements, so the size still works")
    func cropTargetUndoKeepsClaims() async throws {
        let (m, undo, _) = await load(Book(count: 12, strips: true))
        let measured = m.pages, size = try #require(m.pageSize)
        undoable(undo) { m.setPageSize(PageSize(width: 5.8, height: 8.5)) }
        let set = m.pages
        undoable(undo) { m.setCropTarget(.text) }
        await waitUntilIdle(m)
        undo.undo()
        await waitUntilIdle(m)
        #expect(m.cropTarget == .page && m.pages == set)
        undo.redo()                                          // the switch to text blocks, again
        await waitUntilIdle(m)
        #expect(m.cropTarget == .text)
        undo.undo()
        await waitUntilIdle(m)
        #expect(m.cropTarget == .page && m.pages == set)
        #expect(m.pageSize?.width == size.width && m.pageSize?.measured == size.measured, "\(String(describing: m.pageSize))")
        undoable(undo) { m.setPageSize(nil) }
        #expect(zip(m.pages, measured).allSatisfy { $0.leftCrop == $1.leftCrop && $0.rightCrop == $1.rightCrop })
    }

    @Test("Clearing a typed size puts back what analysis gave, on axes it never measured too")
    func clearUnmeasured() async throws {
        let (m, undo, _) = await load(Book(count: 4, strips: true))
        let found = m.pages
        undoable(undo) { m.setPageSize(PageSize(width: 5.8, height: 8.5)) }
        #expect(m.pages != found)
        undoable(undo) { m.setPageSize(nil) }
        #expect(m.pages == found)
    }

    @Test("A typed page size: two sizes in inches, or nothing", arguments: [
        ("6 x 9", PageSize(width: 6, height: 9)), ("6×9", PageSize(width: 6, height: 9)),
        ("5.5 X 8.25 in", PageSize(width: 5.5, height: 8.25)), ("6 by 9", PageSize(width: 6, height: 9)),
        ("6\" × 9\"", PageSize(width: 6, height: 9)), (" 6 in x 9 in ", PageSize(width: 6, height: 9)),
        ("inf × 9", nil), ("nan x 9", nil), ("1e308 x 9", nil), ("6xgarbagex9", nil), ("6 x 9 cm", nil),
        ("6 x", nil), ("6 x 9 x 2", nil), ("0 x 9", nil), ("-6 x 9", nil), ("0.5 x 9", nil), ("6 x 40", nil),
        ("6,5 x 9", nil), ("", nil)] as [(String, PageSize?)])
    func parseSize(_ input: String, _ expected: PageSize?) {
        #expect(PageSize(parsing: input) == expected, "\(input)")
    }

    @Test("A size that can't be saved is refused")
    func refusesBadSize() async throws {
        let (m, undo, _) = await load(Book(count: 12, strips: true))
        let before = m.pages
        undoable(undo) { m.setPageSize(PageSize(width: .infinity, height: 9)) }
        undoable(undo) { m.setPageSize(PageSize(width: 6, height: 0)) }
        #expect(m.pageSize?.override == nil && m.pages == before)
    }
}

@Suite("Saving edits")
struct SaveFailureTests {
    @Test("A save that fails says so instead of failing silently")
    func saveThrows() {
        _ = Fixtures.directory
        let saved = ProjectStore.Saved(pages: [BookPage(sourceIndex: 0)], direction: .leftToRight, cropTarget: .page,
                                       pageSize: PageSize(width: .infinity, height: 9), claims: nil)
        #expect(throws: (any Error).self) { try ProjectStore.save(saved, key: "unencodable-\(UUID().uuidString)") }
    }
}

/// Analysis can move a spread's split after measuring its text (a blank page by
/// the gutter leaves no gap to find it by). Every printed pixel must still be
/// inside a crop, as the page is finally straightened and exported.
@Suite("A moved split never cuts print", .serialized)
@MainActor
struct MovedSplitTests {

    /// Four spreads with a clear gap at the middle, text turned a few degrees.
    /// Then two whose gutter is found far off: a blank left page beside a right
    /// page whose text starts left of the middle, and the mirror of it. Their
    /// text is turned 5°, opposite ways.
    static func book() -> URL {
        let media = CGRect(x: 0, y: 0, width: 1000, height: 700)
        func bars(_ c: CGContext, _ x0: Double, _ x1: Double, degrees: Double) {
            c.saveGState()
            let cx = (x0 + x1) / 2, cy = 350.0
            c.translateBy(x: cx, y: cy); c.rotate(by: degrees * .pi / 180); c.translateBy(x: -cx, y: -cy)
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for k in 0..<28 { c.fill(CGRect(x: x0, y: 100 + Double(k) * 18, width: x1 - x0, height: 7)) }
            c.restoreGState()
        }
        // Left-hand text starting at different places, so the book's usual crop
        // depends on every spread's, the moved ones' too.
        let normal: [(CGContext) -> Void] = [(3.0, 80.0), (-3, 100), (2, 120), (-2, 140)].map { d, x in
            { c in bars(c, x, 440, degrees: d); bars(c, 560, 920, degrees: -d) }
        }
        // A chapter's last page: three lines, so it gets the book's usual crop.
        let short: (CGContext) -> Void = { c in
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for k in 0..<3 { c.fill(CGRect(x: 150, y: 560 + Double(k) * 18, width: 290, height: 7)) }
            bars(c, 560, 920, degrees: 0)
        }
        let blankLeft: (CGContext) -> Void = { c in bars(c, 420, 900, degrees: 5) }
        let blankRight: (CGContext) -> Void = { c in bars(c, 100, 580, degrees: -5) }
        return Fixtures.writePDF("moved-\(UUID().uuidString).pdf", media: media,
                                 pages: normal + [short, blankLeft, blankRight])
    }

    @Test("Every printed pixel of the final, straightened spread is inside its half's crop", arguments: [CropTarget.text, .page])
    func printKept(_ target: CropTarget) async throws {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.setCropTarget(target)
        let url = Self.book()
        // The pages as the pass found them, before moved spreads are analysed again.
        let found = Box<[BookPage]>([])
        m.beforeReanalysis = { await MainActor.run { found.value = m.pages } }
        m.load(url: url)
        await waitUntilIdle(m)
        m.beforeReanalysis = nil
        let doc = try #require(PDFDocument(url: url))
        #expect(m.pages.suffix(2).allSatisfy { abs($0.splitX - 0.5) < 0.03 }, "\(m.pages.map(\.splitX))")   // both moved
        #expect(found.value.count == m.pages.count)
        // Pages whose split stayed put get exactly what they would have got had
        // nothing moved: even-out (text blocks) from the crops as found.
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        func usual(_ crops: [CropRect]) -> CropRect {
            CropRect(x: median(crops.map(\.x)), y: median(crops.map(\.y)),
                     width: median(crops.map(\.width)), height: median(crops.map(\.height)))
        }
        let uL = usual(found.value.map(\.leftCrop)), uR = usual(found.value.map(\.rightCrop))
        func small(_ c: CropRect, _ u: CropRect) -> Bool { c.width < 0.6 * u.width || c.height < 0.6 * u.height }
        var evened = 0
        for (p, f) in zip(m.pages, found.value) where p.splitX == f.splitX {
            var left = f.leftCrop, right = f.rightCrop
            if target == .text && small(left, uL) {
                left = uL.union(left); left.width = min(left.width, f.splitX - left.x); left.normalize(); evened += 1
            }
            if target == .text && small(right, uR) {
                right = uR.union(right)
                if right.x < f.splitX { right.width -= f.splitX - right.x; right.x = f.splitX }
                right.normalize(); evened += 1
            }
            #expect(p.leftCrop == left && p.rightCrop == right && p.leftSkew == f.leftSkew && p.rightSkew == f.rightSkew,
                    "page \(p.sourceIndex) changed: \(p.leftCrop) \(p.rightCrop), expected \(left) \(right)")
        }
        #expect(target == .page || evened == 1)              // the short page
        try Self.checkPrint(m, doc)
        if target == .page {                    // a size re-places every page from its text
            undoable(undo) { m.setPageSize(PageSize(width: 5, height: 7)) }
            try Self.checkPrint(m, doc)
        }
        // Re-detecting one of them alone gives the same treatment.
        m.selectedPageID = m.pages[4].id
        undoable(undo) { m.reanalyzeSelected() }
        try Self.checkPrint(m, doc)
    }

    /// Straighten each page as export does, at its final split and angles, and
    /// look for dark pixels outside the crop of the half they are in.
    static func checkPrint(_ m: AppModel, _ doc: PDFDocument) throws {
        for p in m.pages {
            #expect(p.leftCrop.maxX <= p.splitX + 1e-9 && p.rightCrop.minX >= p.splitX - 1e-9)
            let cg = try #require(PDFRenderer.renderCGImage(page: doc.page(at: p.sourceIndex)!, dpi: 110))
            let out = ImageTransform.deskewedComposite(cg, splitX: p.splitX, leftDegrees: p.leftSkew,
                                                       rightDegrees: p.rightSkew, isSpread: p.isSpread)
            let g = try #require(GrayBuffer(cgImage: out, maxDim: max(out.width, out.height)))
            var outside = [0, 0]
            for y in 0..<g.height {
                for x in 0..<g.width where g.value(x, y) < 100 {
                    let nx = (Double(x) + 0.5) / Double(g.width), ny = (Double(y) + 0.5) / Double(g.height)
                    let left = nx < p.splitX, c = left ? p.leftCrop : p.rightCrop
                    if nx < c.minX || nx > c.maxX || ny < c.minY || ny > c.maxY { outside[left ? 0 : 1] += 1 }
                }
            }
            #expect(outside == [0, 0], "page \(p.sourceIndex) split \(p.splitX) skews \(p.leftSkew) \(p.rightSkew): \(outside) dark pixels outside (left, right); crops \(p.leftCrop) \(p.rightCrop)")
        }
    }
}

/// Undoing a change of crop target while a pass is analysing moved spreads again
/// must stop that pass: its results are for the target undone.
@Suite("Undo during analysis", .serialized)
@MainActor
struct UndoDuringAnalysisTests {

    /// Holds a pass at the hook until released (once; later passes go straight on).
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var reached = false, released = false
        func wait() async {
            await withCheckedContinuation { c in
                lock.lock()
                if released { lock.unlock(); c.resume(); return }
                reached = true; waiting = c
                lock.unlock()
            }
        }
        var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return reached }
        func release() { lock.lock(); released = true; let c = waiting; waiting = nil; lock.unlock(); c?.resume() }
    }

    @Test("Undoing a switch of crop target mid-pass drops that pass's results", arguments: [CropTarget.text, .page])
    func undoMidPass(_ start: CropTarget) async throws {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.setCropTarget(start)
        m.load(url: MovedSplitTests.book())
        await waitUntilIdle(m)
        let before = m.pages
        let gate = Gate()
        m.beforeReanalysis = { await gate.wait() }
        undoable(undo) { m.setCropTarget(start == .text ? .page : .text) }
        while !gate.isWaiting { try await Task.sleep(nanoseconds: 10_000_000) }   // the pass waits to redo moved spreads
        undo.undo()
        gate.release()
        await waitUntilIdle(m)
        m.beforeReanalysis = nil
        #expect(m.cropTarget == start && !m.isBusy)
        for (p, q) in zip(m.pages, before) {
            #expect(p == q, "page \(p.sourceIndex): \(p.leftCrop) \(p.rightCrop), was \(q.leftCrop) \(q.rightCrop)")
        }
    }

    /// A loaded book, an undo manager, and a pass (a switch of crop target)
    /// held just before it analyses moved spreads again.
    private func heldSwitch(from start: CropTarget) async throws -> (AppModel, UndoManager, Gate, URL) {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.setCropTarget(start)
        let url = MovedSplitTests.book()
        m.load(url: url)
        await waitUntilIdle(m)
        let gate = Gate()
        m.beforeReanalysis = { await gate.wait() }
        undoable(undo) { m.setCropTarget(start == .text ? .page : .text) }
        while !gate.isWaiting { try await Task.sleep(nanoseconds: 10_000_000) }
        return (m, undo, gate, url)
    }

    @Test("Edits made while a pass finishes are kept, through unrelated undos during and after it")
    func editsWin() async throws {
        let (m, undo, gate, _) = try await heldSwitch(from: .text)
        let mark = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.5)
        undoable(undo) { m.perform("Adjust Crop") { m.pages[5].leftCrop = mark } }       // a moved spread
        m.selectedPageID = m.pages[1].id                                                 // a drag
        undoable(undo) { m.beginEdit(); m.pages[1].rightCrop = mark; m.endEdit("Adjust Crop") }
        undoable(undo) { m.perform("Adjust Crop") { m.pages[2].leftCrop = mark } }       // unrelated, then undone
        undo.undo()
        gate.release()
        await waitUntilIdle(m)
        m.beforeReanalysis = nil
        #expect(m.pages[5].leftCrop == mark && m.pages[1].rightCrop == mark && m.pages[2].leftCrop != mark)
        undoable(undo) { m.perform("Adjust Crop") { m.pages[3].leftCrop = mark } }       // and after it
        undo.undo()
        await waitUntilIdle(m)
        #expect(m.pages[5].leftCrop == mark && m.pages[1].rightCrop == mark && !m.isBusy)
    }

    @Test("Undo then redo of a crop-target switch mid-pass gives a complete pass", arguments: [CropTarget.text, .page])
    func undoRedoMidPass(_ start: CropTarget) async throws {
        let (m, undo, gate, url) = try await heldSwitch(from: start)
        undo.undo()
        gate.release()
        await waitUntilIdle(m)
        undo.redo()
        await waitUntilIdle(m)
        m.beforeReanalysis = nil
        let other: CropTarget = start == .text ? .page : .text
        // A fresh pass in the switched mode, for comparison.
        let fresh = testModel()
        fresh.setCropTarget(other)
        var data = try Data(contentsOf: url)
        data.append(Data("\n%copy\n".utf8))                 // its own saved-edits key
        let copy = Fixtures.url("copy-\(UUID().uuidString).pdf")
        try data.write(to: copy)
        fresh.load(url: copy)
        await waitUntilIdle(fresh)
        #expect(m.cropTarget == other && !m.isBusy)
        for (p, q) in zip(m.pages, fresh.pages) {
            #expect(p.splitX == q.splitX && p.leftSkew == q.leftSkew && p.rightSkew == q.rightSkew
                    && p.leftCrop == q.leftCrop && p.rightCrop == q.rightCrop && p.classification == q.classification,
                    "page \(p.sourceIndex): split \(p.splitX) vs \(q.splitX), \(p.leftCrop) \(p.rightCrop) vs \(q.leftCrop) \(q.rightCrop)")
        }
    }
}

/// A value a test hook can fill in.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
