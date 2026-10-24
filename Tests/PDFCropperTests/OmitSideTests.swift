import Testing
import Foundation
import PDFKit
@testable import PDFCropper

/// Leaving one page of a spread out of the export.
@Suite("Leave out one side of a spread", .serialized)
@MainActor
struct OmitSideTests {

    private let left = CropRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8)
    private let right = CropRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8)

    private func spread(omitting side: BookPage.Side? = nil) -> BookPage {
        var p = BookPage(sourceIndex: 0, classification: .spread, leftCrop: left, rightCrop: right, analyzed: true)
        p.omittedSide = side
        return p
    }

    @Test("Saved edits from before this field decode with nothing left out")
    func oldSavesDecode() throws {
        let data = try JSONEncoder().encode(spread())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["omittedSide"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(BookPage.self, from: old).omittedSide == nil)
        // A real value survives a round trip.
        let back = try JSONDecoder().decode(BookPage.self, from: JSONEncoder().encode(spread(omitting: .right)))
        #expect(back.omittedSide == .right)
    }

    @Test("A spread gives one output page when a side is left out, in either reading direction")
    func outputCrops() {
        for direction in [ReadingDirection.leftToRight, .rightToLeft] {
            #expect(spread(omitting: .left).outputCrops(direction: direction) == [right])
            #expect(spread(omitting: .right).outputCrops(direction: direction) == [left])
        }
        #expect(spread().outputCrops(direction: .leftToRight) == [left, right])
        #expect(spread().outputCrops(direction: .rightToLeft) == [right, left])
    }

    @Test("A single or skipped page ignores it")
    func onlySpreads() {
        var single = spread(omitting: .right); single.classification = .single
        #expect(single.outputCrops(direction: .leftToRight) == [left])
        var skipped = spread(omitting: .right); skipped.classification = .skip
        #expect(skipped.outputCrops(direction: .leftToRight).isEmpty)
    }

    @Test("The output page count follows it, in both directions")
    func outputPageCount() async {
        let m = testModel()
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        #expect(m.outputPageCount == 11)
        m.setOmittedSide(.left, for: m.pages[1].id)
        #expect(m.outputPageCount == 10)
        m.setOmittedSide(.right, for: m.pages[2].id)
        #expect(m.outputPageCount == 9)
        m.direction = .rightToLeft
        #expect(m.outputPageCount == 9)
        m.setOmittedSide(nil, for: m.pages[1].id)
        #expect(m.outputPageCount == 10)
    }

    @Test("Undo and redo, with an action name; the crops and skews stay")
    func undoRedo() async {
        let m = testModel()
        let undo = UndoManager(); undo.groupsByEvent = false; m.undoManager = undo
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        let before = m.pages[1]
        undoable(undo) { m.setOmittedSide(.right, for: before.id) }
        #expect(undo.undoActionName == "Change Pages Exported")
        #expect(m.pages[1].omittedSide == .right)
        #expect(m.pages[1].leftCrop == before.leftCrop && m.pages[1].rightCrop == before.rightCrop)
        #expect(m.pages[1].leftSkew == before.leftSkew && m.pages[1].rightSkew == before.rightSkew)
        undo.undo()
        #expect(m.pages[1].omittedSide == nil)
        undo.redo()
        #expect(m.pages[1].omittedSide == .right)
        // Choosing Both again brings the side back as it was.
        undoable(undo) { m.setOmittedSide(nil, for: before.id) }
        #expect(m.pages[1].omittedSide == nil && m.pages[1].rightCrop == before.rightCrop)
        // The same choice twice is not an edit.
        undo.undo(); undo.undo()                                // back to nothing recorded
        #expect(!undo.canUndo)
        m.setOmittedSide(nil, for: before.id)
        #expect(!undo.canUndo)
    }

    @Test("It changes only on a spread")
    func notOnSingle() async {
        let m = testModel()
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        #expect(m.pages[0].classification == .single)
        m.setOmittedSide(.left, for: m.pages[0].id)
        #expect(m.pages[0].omittedSide == nil && m.outputPageCount == 11)
    }

    @Test("Auto-detect on the page keeps it; Apply layout to all spreads does not copy it")
    func keptByDetectNotCopied() async {
        let m = testModel()
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        m.setOmittedSide(.right, for: m.pages[1].id)
        m.selectedPageID = m.pages[1].id
        m.reanalyzeSelected()
        #expect(m.pages[1].classification == .spread && m.pages[1].omittedSide == .right)
        m.selectedPageID = m.pages[2].id
        m.applyLayoutToAllSpreads()
        #expect(m.pages[1].omittedSide == .right && m.pages[2].omittedSide == nil)
    }

    @Test("Changing the type to Single drops it; Skip and back keeps it")
    func typeChanges() async {
        let m = testModel()
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        let id = m.pages[1].id
        m.setOmittedSide(.left, for: id)
        m.setClassification(.skip, for: id)
        m.setClassification(.spread, for: id)
        #expect(m.pages[1].omittedSide == .left)
        m.setClassification(.single, for: id)
        #expect(m.pages[1].omittedSide == nil)
    }

    @Test("Export leaves the side out: 3 pages from 2 spreads, in reading order")
    func exportOrder() async throws {
        // Two spreads; each book page has its own number of lines (3, 5, 7, 9),
        // so counting an output page's lines says which book page it is.
        let media = CGRect(x: 0, y: 0, width: 1000, height: 650)
        let lines = [[3, 5], [7, 9]]
        let url = Fixtures.writePDF("omit-\(UUID().uuidString).pdf", media: media, pages: lines.map { pair in
            { c in
                c.setFillColor(CGColor(gray: 0.1, alpha: 1))
                for (k, n) in pair.enumerated() {
                    for r in 0..<n { c.fill(CGRect(x: 80 + Double(k) * 480, y: 560 - Double(r) * 40, width: 360, height: 12)) }
                }
            }
        })
        let m = testModel()
        m.load(url: url); await waitUntilIdle(m)
        #expect(m.pages.allSatisfy { $0.classification == .spread })
        func order(_ d: PDFDocument) -> [Int] {
            (0..<d.pageCount).map { i in
                let cg = PDFRenderer.renderCGImage(page: d.page(at: i)!, dpi: 72)!
                let g = GrayBuffer(cgImage: cg, maxDim: max(cg.width, cg.height))!
                var runs = 0, inRun = false
                for y in 0..<g.height {
                    let ink = Double(g.value(g.width / 2, y)) < 128
                    if ink && !inRun { runs += 1 }
                    inRun = ink
                }
                return [3, 5, 7, 9].firstIndex(of: runs) ?? -runs
            }
        }
        m.setOmittedSide(.right, for: m.pages[0].id)          // leaves out the 5-line page
        let ltr = try #require(await exportAndOpen(m, "omit-ltr.pdf"))
        #expect(order(ltr) == [0, 2, 3], "\(order(ltr))")
        m.direction = .rightToLeft
        let rtl = try #require(await exportAndOpen(m, "omit-rtl.pdf"))
        #expect(order(rtl) == [0, 3, 2], "\(order(rtl))")
        m.direction = .leftToRight
        m.setOmittedSide(nil, for: m.pages[0].id)
        m.setOmittedSide(.left, for: m.pages[1].id)           // leaves out the 7-line page
        let other = try #require(await exportAndOpen(m, "omit-other.pdf"))
        #expect(order(other) == [0, 1, 3], "\(order(other))")
    }
}
