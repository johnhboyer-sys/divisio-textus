import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFCropper

/// Trim: the part of a scan the book is on (John, 2026-10-26: a book shot with its
/// cover open, on black or beside a white cover).
@Suite("Trim", .serialized)
@MainActor
struct TrimTests {

    /// 17 × 11 in scans. The open book (two 5.4 × 7.9 in pages) lies at the
    /// right, its fold 0.7 of the way across; to its left and below it, black
    /// ground (`white`: a white cover, and a light grey one below, as on John's
    /// page 6).
    struct Scan {
        static let media = CGRect(x: 0, y: 0, width: 1224, height: 792)
        static let page = (w: 388.8, h: 568.8)
        static let fold = 856.8                                          // 0.7 across
        var white = false

        /// The book as the scan shows it: the right page runs off its edge, as on John's.
        static var book: CropRect {
            let W = media.width, H = media.height, x0 = (fold - page.w) / W
            return CropRect(x: x0, y: 0, width: min(1, (fold + page.w) / W) - x0, height: page.h / H)
        }

        func write(count: Int) -> URL {
            Fixtures.writePDF("scan-\(UUID().uuidString).pdf", media: Self.media,
                              pages: Array(repeating: { c in self.draw(c) }, count: count))
        }

        private func draw(_ c: CGContext) {
            let W = Self.media.width, H = Self.media.height, (pw, ph) = Self.page, f = Self.fold
            func fill(_ gray: Double, _ x: Double, _ yTop: Double, _ w: Double, _ h: Double) {
                c.setFillColor(CGColor(gray: gray, alpha: 1))
                c.fill(CGRect(x: x, y: H - yTop - h, width: w, height: h))
            }
            fill(white ? 1 : 0.02, 0, 0, W, H)                         // the ground
            if white { fill(0.94, 0, ph, W, H - ph) }                  // the cover below, a little grey
            fill(1, f - pw, 0, 2 * pw, ph)                             // the pages
            if white { fill(0.6, f - pw, 0, 1, ph) }                   // the left page's faint edge
            fill(0.25, f - 1, 0, 2, ph)                                // the fold
            for (x0, x1) in [(f - pw + 50, f - 40), (f + 40, f + pw - 50)] {
                for y in stride(from: 50.0, to: ph - 60, by: 14) { fill(0.1, x0, y, x1 - x0, 6) }
            }
        }
    }

    private func load(_ scan: Scan, count: Int = 4) async -> (AppModel, UndoManager) {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.setCropTarget(.page)
        m.load(url: scan.write(count: count))
        await waitUntilIdle(m)
        return (m, undo)
    }

    private func near(_ a: CropRect?, _ b: CropRect, within d: Double = 0.01) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < d && abs(a.maxX - b.maxX) < d && abs(a.minY - b.minY) < d && abs(a.maxY - b.maxY) < d
    }

    @Test("A book on a wide black ground is trimmed to; an ordinary scan's thin bed strip is not")
    func findsTheBook() throws {
        let doc = try #require(PDFDocument(url: Scan().write(count: 1)))
        let cg = try #require(PDFRenderer.renderCGImage(page: doc.page(at: 0)!, dpi: 50))
        let found = PageAnalyzer.findBook(cg)
        #expect(near(found, Scan.book), "\(String(describing: found)), book \(Scan.book)")
        let flatbed = Fixtures.image(1400, 1000) { c in                 // 2% of bed at each side
            c.setFillColor(CGColor(gray: 0.02, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1400, height: 1000))
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 28, y: 20, width: 1344, height: 960))
        }
        #expect(PageAnalyzer.findBook(flatbed) == nil)
    }

    @Test("Opening such a scan trims it to the book and splits it on the fold, the boxes inside the trim")
    func autoTrim() async throws {
        let (m, _) = await load(Scan())
        for p in m.pages {
            #expect(p.trimByHand == nil && near(p.trim, Scan.book), "page \(p.sourceIndex): \(String(describing: p.trim))")
            #expect(p.classification == .spread)
            #expect(abs(p.splitX - Scan.fold / Scan.media.width) < 0.01, "page \(p.sourceIndex): split \(p.splitX)")
            for c in [p.leftCrop, p.rightCrop] {
                #expect(c.minX >= p.bounds.minX - 1e-9 && c.maxX <= p.bounds.maxX + 1e-9 && c.maxY <= p.bounds.maxY + 1e-9,
                        "page \(p.sourceIndex): \(c) outside \(p.bounds)")
            }
        }
    }

    @Test("Trim by hand: one undo step; the page as analysis left it is detected again inside the trim")
    func trimByHand() async throws {
        let (m, undo) = await load(Scan(white: true))
        let before = m.pages
        #expect(before[0].trim == nil)                                  // nothing dark to find
        m.selectedPageID = m.pages[0].id
        m.beginTrim()
        #expect(m.trimmingPage == m.pages[0].id && m.trimDraft == .full)
        m.trimDraft = Scan.book
        undoable(undo) { m.finishTrim() }
        let p = m.pages[0]
        #expect(m.trimmingPage == nil && p.trimByHand == true && p.trim == Scan.book)
        #expect(abs(p.splitX - Scan.fold / Scan.media.width) < 0.01, "split \(p.splitX)")
        #expect(p.leftCrop.minX >= Scan.book.minX - 1e-9 && p.leftCrop.maxY <= Scan.book.maxY + 1e-9, "\(p.leftCrop)")
        #expect(m.pages[1] == before[1])                                // only this page
        undo.undo()
        #expect(m.pages == before)
    }

    @Test("Cancel leaves the page as it was")
    func cancel() async throws {
        let (m, _) = await load(Scan(white: true), count: 1)
        let before = m.pages
        m.selectedPageID = m.pages[0].id
        m.beginTrim()
        m.trimDraft = Scan.book
        m.cancelTrim()
        #expect(m.trimmingPage == nil && m.pages == before)
    }

    @Test("A page edited by hand keeps its boxes, cut to the trim")
    func handEditedKeepsBoxes() async throws {
        let (m, undo) = await load(Scan(white: true), count: 1)
        let edited = CropRect(x: 0.5, y: 0.1, width: 0.2, height: 0.5)
        undoable(undo) { m.perform("Adjust Crop") { m.pages[0].rightCrop = edited } }
        m.selectedPageID = m.pages[0].id
        m.beginTrim()
        m.trimDraft = CropRect(x: 0.4, y: 0, width: 0.6, height: 0.5)
        undoable(undo) { m.finishTrim() }
        let r = m.pages[0].rightCrop
        #expect(abs(r.minX - edited.minX) < 1e-9 && abs(r.maxX - edited.maxX) < 1e-9 && abs(r.maxY - 0.5) < 1e-9, "\(r)")
    }

    @Test("Remove Trim shows the whole page again, and Auto-detect doesn't trim it back")
    func removeTrim() async throws {
        let (m, undo) = await load(Scan(), count: 1)
        #expect(m.pages[0].trim != nil)
        m.selectedPageID = m.pages[0].id
        undoable(undo) { m.removeTrim() }
        #expect(m.pages[0].trim == nil && m.pages[0].trimByHand == true)
        undoable(undo) { m.reanalyzeSelected() }
        #expect(m.pages[0].trim == nil)
        undo.undo(); undo.undo()
        #expect(near(m.pages[0].trim, Scan.book) && m.pages[0].trimByHand == nil)
    }

    @Test("Trim All Pages (Book tab): every page takes the trim drawn, its boxes and split inside it; Remove All Trims")
    func trimAll() async throws {
        let (m, undo) = await load(Scan(white: true))
        let before = m.pages
        m.selectedPageID = m.pages[1].id
        m.beginTrim(allPages: true)
        m.trimDraft = Scan.book
        undoable(undo) { m.finishTrim() }
        #expect(m.trimmingPage == nil)
        for p in m.pages {
            #expect(p.trim == Scan.book && p.trimByHand == true)
            #expect(p.splitX > Scan.book.minX && p.splitX < Scan.book.maxX)
            for c in [p.leftCrop, p.rightCrop] {
                #expect(c.minX >= Scan.book.minX - 1e-9 && c.maxX <= Scan.book.maxX + 1e-9 && c.maxY <= Scan.book.maxY + 1e-9)
            }
        }
        // Auto-detect then finds the pages inside each trim, which it keeps.
        undoable(undo) { m.autoDetectAllPages() }
        await waitUntilIdle(m)
        for p in m.pages {
            #expect(p.trim == Scan.book && abs(p.splitX - Scan.fold / Scan.media.width) < 0.01, "page \(p.sourceIndex): \(p.splitX)")
        }
        undoable(undo) { m.removeAllTrims() }
        #expect(m.pages.allSatisfy { $0.trim == nil && $0.trimByHand == true })
        undo.undo(); undo.undo(); undo.undo()
        #expect(m.pages == before)
    }

    @Test("A trim being drawn ends with another page or PDF, and Trim All Pages leaves Stack view (Codex review)")
    func trimSessionEnds() async throws {
        let (m, _) = await load(Scan(white: true), count: 2)
        m.selectedPageID = m.pages[0].id
        m.showsStack = true
        m.beginTrim(allPages: true)
        #expect(m.trimmingPage == m.pages[0].id && !m.showsStack)
        m.selectedPageID = m.pages[1].id
        #expect(m.trimmingPage == nil)
        m.selectedPageID = m.pages[0].id
        m.beginTrim()
        m.load(url: Scan().write(count: 1))
        await waitUntilIdle(m)
        #expect(m.trimmingPage == nil)
        let before = m.pages
        m.finishTrim()
        #expect(m.pages == before)
    }

    @Test("A skipped spread is fit to Trim All Pages as the spread it was, and comes back inside the trim (Codex review)")
    func skippedSpreadFits() async throws {
        let (m, undo) = await load(Scan(white: true), count: 2)
        let id = m.pages[0].id
        undoable(undo) { m.setClassification(.skip, for: id) }
        m.selectedPageID = m.pages[1].id
        m.beginTrim(allPages: true)
        m.trimDraft = Scan.book
        undoable(undo) { m.finishTrim() }
        undoable(undo) { m.setClassification(.spread, for: id) }
        let p = m.pages[0]
        #expect(p.splitX > Scan.book.minX && p.splitX < Scan.book.maxX, "split \(p.splitX)")
        for c in [p.leftCrop, p.rightCrop] {
            #expect(c.minX >= Scan.book.minX - 1e-9 && c.maxX <= Scan.book.maxX + 1e-9, "\(c)")
        }
    }

    @Test("Inside a trim, the split, Match Sizes and the size warning stop at the trim's edges")
    func limitsAtTheTrim() async throws {
        let (m, undo) = await load(Scan(), count: 1)
        let b = m.pages[0].bounds
        // A typed size larger than the trim's half: too large, the room being the trim's.
        undoable(undo) { m.setPageSize(PageSize(width: 6, height: 9)) }
        let size = try #require(m.pageSize)
        #expect(size.tooBig > 0)
        let fits = try #require(size.fitsAll)
        let p = m.pages[0], W = Scan.media.width / 72
        #expect(fits.height <= Scan.page.h / 72 + 0.01 && fits.width <= (b.maxX - p.splitX) * W + 0.01, "\(fits)")
        for c in [p.leftCrop, p.rightCrop] {
            #expect(c.minX >= b.minX - 1e-9 && c.maxX <= b.maxX + 1e-9 && c.maxY <= b.maxY + 1e-9, "\(c)")
        }
        undoable(undo) { m.perform("Move Split") { m.moveSplit(at: 0, to: 0.1, locked: false) } }
        #expect(m.pages[0].splitX >= b.minX + 0.05 * b.width - 1e-9, "split \(m.pages[0].splitX), trim \(b)")
        #expect(m.pages[0].leftCrop.minX >= b.minX - 1e-9)
        undoable(undo) { m.perform("Move Split") { m.moveSplit(at: 0, to: 0.95, locked: true) } }
        #expect(m.pages[0].rightCrop.maxX <= b.maxX + 1e-9 && m.pages[0].leftCrop.minX >= b.minX - 1e-9)
        undoable(undo) { m.matchCropSizes(of: m.pages[0].id, rightMatchesLeft: true) }
        #expect(m.pages[0].rightCrop.maxX <= b.maxX + 1e-9 && m.pages[0].leftCrop.minX >= b.minX - 1e-9)
    }

    @Test("A split given outside a page's trim (the book's usual one) is kept inside it, not a crash (Codex review)")
    func givenSplitInsideTrim() throws {
        let doc = try #require(PDFDocument(url: Scan().write(count: 1)))
        let cg = try #require(PDFRenderer.renderCGImage(page: doc.page(at: 0)!, dpi: 50))
        let a = AppModel.analyzePage(cg, deskew: false, as: .spread, target: .page, split: 0.3, trim: Scan.book)
        #expect(a.result.splitX > Scan.book.minX && a.result.splitX < Scan.book.maxX, "split \(a.result.splitX)")
    }

    @Test("Boxes wholly above or below a trim are moved inside it, not left out (Codex review)")
    func boxesMovedInside() {
        let trim = CropRect(x: 0.2, y: 0.6, width: 0.6, height: 0.3)
        let l = SpreadLayout(splitX: 0.5, leftCrop: CropRect(x: 0.25, y: 0.1, width: 0.2, height: 0.3),
                             rightCrop: CropRect(x: 0.55, y: 0.1, width: 0.2, height: 0.3), bounds: trim).clamped
        for c in [l.leftCrop, l.rightCrop] {
            #expect(c.minY >= trim.minY - 1e-9 && c.maxY <= trim.maxY + 1e-9 && c.height > 0.02, "\(c)")
        }
        var page = BookPage(sourceIndex: 0, classification: .single)
        page.trim = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.4)
        let member = PageStack.Member(page: page, side: .single)
        #expect(member.regionWidth == 1 && member.regionMinX == 0 && member.limits == page.trim!)   // drawn as the whole scan
        let c = member.clampedCrop(CropRect(x: 0.3, y: 0.7, width: 0.3, height: 0.2))
        #expect(c.minY >= 0.1 - 1e-9 && c.maxY <= 0.5 + 1e-9 && c.minX >= 0.1 - 1e-9 && c.maxX <= 0.9 + 1e-9, "\(c)")
        // and in the export, a tiny box at the trim's edge that normalizing would grow past it
        page.leftCrop = CropRect(x: 0.888, y: 0.2, width: 0.012, height: 0.2)
        let out = page.outputCrops(direction: .leftToRight)[0]
        #expect(out.maxX <= 0.9 + 1e-9, "\(out)")
        let px = out.normalized().pixelRect(in: CGSize(width: 3000, height: 3000)).integral     // as PDFRenderer.crop cuts it
        #expect(px.maxX <= 2700, "\(px)")
        // An untrimmed page's crops come out exactly as they are.
        var plain = BookPage(sourceIndex: 0)
        plain.leftCrop = CropRect(x: 0.03, y: 0.1, width: 0.04, height: 0.5)
        plain.rightCrop = CropRect(x: 0.53, y: 0.1, width: 0.4, height: 0.5)
        #expect(plain.outputCrops(direction: .leftToRight) == [plain.leftCrop, plain.rightCrop])
    }

    @Test("The stack's picture is redrawn when a trim changes (Codex review)")
    func stackGeometryHasTrim() {
        var page = BookPage(sourceIndex: 0)
        let before = PageStack(id: .left, members: [PageStack.Member(page: page, side: .left)]).geometry
        page.trim = CropRect(x: 0.2, y: 0, width: 0.8, height: 1)
        let after = PageStack(id: .left, members: [PageStack.Member(page: page, side: .left)]).geometry
        #expect(before != after)
    }

    @Test("Every box stays inside its page's trim, trimmed and untrimmed pages mixed, in both crop modes (Codex review)",
          arguments: [CropTarget.page, .text])
    func mixedTrimsStayInside(target: CropTarget) async throws {
        let doc = try #require(PDFDocument(url: Scan().write(count: 3)))
        let white = try #require(PDFDocument(url: Scan(white: true).write(count: 2)))
        for i in 0..<2 { doc.insert(white.page(at: i)!, at: doc.pageCount) }
        let url = Fixtures.url("mixed-\(UUID().uuidString).pdf")
        #expect(doc.write(to: url))
        let m = testModel()
        m.setCropTarget(target)
        m.load(url: url)
        await waitUntilIdle(m)
        #expect(m.pages.filter { $0.trim != nil }.count == 3)
        for p in m.pages {
            for c in p.isSpread ? [p.leftCrop, p.rightCrop] : [p.leftCrop] {
                #expect(c.minX >= p.bounds.minX - 1e-9 && c.maxX <= p.bounds.maxX + 1e-9
                        && c.minY >= p.bounds.minY - 1e-9 && c.maxY <= p.bounds.maxY + 1e-9, "page \(p.sourceIndex): \(c) in \(p.bounds)")
            }
        }
    }

    @Test("A single page's crop applied to all single pages stays inside each one's trim (Codex review)")
    func singleApplyInsideTrims() async throws {
        let media = CGRect(x: 0, y: 0, width: 576, height: 720)
        let url = Fixtures.writePDF("singles-\(UUID().uuidString).pdf", media: media, pages: Array(repeating: { c in
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(media)
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for y in stride(from: 100.0, to: 600, by: 14) { c.fill(CGRect(x: 90, y: y, width: 396, height: 6)) }
        }, count: 2))
        let m = testModel(), undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.load(url: url)
        await waitUntilIdle(m)
        let trim = CropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        m.selectedPageID = m.pages[0].id
        m.beginTrim()
        m.trimDraft = trim
        undoable(undo) { m.finishTrim() }
        m.selectedPageID = m.pages[1].id
        undoable(undo) { m.perform("Adjust Crop") { m.pages[1].leftCrop = CropRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9) } }
        undoable(undo) { m.applySingleCrop(alternate: false) }
        let c = m.pages[0].leftCrop
        #expect(c.minX >= trim.minX - 1e-9 && c.maxX <= trim.maxX + 1e-9 && c.minY >= trim.minY - 1e-9 && c.maxY <= trim.maxY + 1e-9, "\(c)")
    }

    @Test("A box in the trim's terms and back is the same box")
    func relativeRoundTrip() {
        let area = CropRect(x: 0.37, y: 0.05, width: 0.6, height: 0.7), c = CropRect(x: 0.5, y: 0.2, width: 0.3, height: 0.4)
        let back = c.relative(to: area).absolute(in: area)
        #expect(abs(back.x - c.x) < 1e-12 && abs(back.y - c.y) < 1e-12 && abs(back.width - c.width) < 1e-12 && abs(back.height - c.height) < 1e-12)
    }

    @Test("A save from before Trim opens untrimmed")
    func oldSave() throws {
        let page = BookPage(sourceIndex: 0)
        var json = try #require(String(data: JSONEncoder().encode(page), encoding: .utf8))
        #expect(!json.contains("trim"))
        json = json.replacingOccurrences(of: "\"analyzed\":false", with: "\"analyzed\":true")
        let back = try JSONDecoder().decode(BookPage.self, from: Data(json.utf8))
        #expect(back.trim == nil && back.trimByHand == nil && back.bounds == .full)
    }
}
