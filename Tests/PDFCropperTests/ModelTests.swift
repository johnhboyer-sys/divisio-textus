import Testing
import Foundation
import AppKit
import PDFKit
@testable import PDFCropper

/// Editing, undo, analysis and autosave, driven through AppModel the way the UI
/// drives it. Each test opens its own copy of the sample book (1 single page,
/// then 5 spreads, some skewed), so their saved edits never mix.
@Suite("Editing and the app model", .serialized)
@MainActor
struct ModelTests {

    private func loadedSample() async -> (AppModel, UndoManager, URL) {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        let url = Fixtures.sampleBook()
        m.load(url: url)
        await waitUntilIdle(m)
        return (m, undo, url)
    }

    private var firstSpread: Int { 1 }

    @Test("Analysis classifies the sample book")
    func analysis() async {
        let (m, _, _) = await loadedSample()
        #expect(m.pages.count == 6)
        #expect(m.pages.allSatisfy { $0.analyzed })
        #expect(m.pages.map(\.classification) == [.single, .spread, .spread, .spread, .spread, .spread])
        #expect(m.outputPageCount == 11)
    }

    @Test("Match Sizes makes one box the other's size, as one undo step")
    func matchSizes() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread
        undoable(undo) { m.perform("Adjust Crop") {
            m.pages[i].leftCrop = CropRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8)
            m.pages[i].rightCrop = CropRect(x: 0.52, y: 0.12, width: 0.42, height: 0.75)
        } }
        let before = m.pages[i]
        undoable(undo) { m.matchCropSizes(of: before.id, rightMatchesLeft: true) }
        #expect(m.pages[i].leftCrop == before.leftCrop)
        #expect(m.pages[i].rightCrop == CropRect(x: 0.52, y: 0.1, width: 0.4, height: 0.8))
        undo.undo()
        #expect(m.pages[i] == before)
        undoable(undo) { m.matchCropSizes(of: before.id, rightMatchesLeft: false) }
        #expect(m.pages[i].rightCrop == before.rightCrop)
        #expect(abs(m.pages[i].leftCrop.width - 0.42) < 1e-12 && abs(m.pages[i].leftCrop.maxX - 0.45) < 1e-12)
    }

    @Test("The sidebar's stack Match Sizes gives what the page's matchCropSizes gives")
    func sidebarMatchesPageMatch() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread
        setBoxes(m, undo, page: i)
        for rightMatchesLeft in [true, false] {
            var l = SpreadLayout(splitX: m.pages[i].splitX, leftCrop: m.pages[i].leftCrop, rightCrop: m.pages[i].rightCrop)
            l.matchSizes(rightMatchesLeft: rightMatchesLeft)
            undoable(undo) { m.matchCropSizes(of: m.pages[i].id, rightMatchesLeft: rightMatchesLeft) }
            #expect(m.pages[i].leftCrop == l.leftCrop && m.pages[i].rightCrop == l.rightCrop)
            undo.undo()
        }
    }

    /// A drag of one box the way the canvas does it: begin, several moves, end.
    private func drag(_ m: AppModel, page i: Int, side: BookPage.Side, locked: Bool, to steps: [CropRect]) {
        m.selectedPageID = m.pages[i].id
        m.beginEdit()
        for crop in steps { m.setSpreadCrop(crop, on: side, at: i, locked: locked) }
        m.endEdit("Adjust Crop")
    }

    private func setBoxes(_ m: AppModel, _ undo: UndoManager, page i: Int) {
        undoable(undo) { m.perform("Adjust Crop") {
            m.pages[i].leftCrop = CropRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8)
            m.pages[i].rightCrop = CropRect(x: 0.52, y: 0.12, width: 0.42, height: 0.75)
        } }
    }

    @Test("Lock off: dragging one box leaves the other alone")
    func lockOff() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread
        setBoxes(m, undo, page: i)
        let before = m.pages[i]
        let wider = CropRect(x: 0.03, y: 0.1, width: 0.42, height: 0.8)
        undoable(undo) { drag(m, page: i, side: .left, locked: false, to: [wider]) }
        #expect(m.pages[i].leftCrop == wider)
        #expect(m.pages[i].rightCrop == before.rightCrop)
    }

    @Test("Lock on: the other box follows the dragged one, and one undo restores both")
    func lockOn() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread
        setBoxes(m, undo, page: i)
        let before = m.pages[i]
        // The left box's outer edge out by 0.02, in two moves.
        let steps = [CropRect(x: 0.04, y: 0.1, width: 0.41, height: 0.8), CropRect(x: 0.03, y: 0.1, width: 0.42, height: 0.8)]
        undoable(undo) { drag(m, page: i, side: .left, locked: true, to: steps) }
        let left = m.pages[i].leftCrop, right = m.pages[i].rightCrop
        #expect(left == steps[1])
        #expect(abs(right.width - left.width) < 1e-12)
        #expect(right.y == left.y && right.height == left.height)
        #expect(right.x == before.rightCrop.x)                       // the fold edges stay
        #expect(abs(left.maxX - before.leftCrop.maxX) < 1e-12)
        undo.undo()
        #expect(m.pages[i] == before)
    }

    @Test("Lock on: dragging the right box gives the left its size, fold edge fixed")
    func lockOnRight() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread
        setBoxes(m, undo, page: i)
        let before = m.pages[i]
        let moved = CropRect(x: 0.52, y: 0.12, width: 0.45, height: 0.7)
        undoable(undo) { drag(m, page: i, side: .right, locked: true, to: [moved]) }
        let left = m.pages[i].leftCrop
        #expect(m.pages[i].rightCrop == moved)
        #expect(abs(left.maxX - before.leftCrop.maxX) < 1e-12)
        #expect(abs(left.width - 0.45) < 1e-12 && left.y == 0.12 && abs(left.height - 0.7) < 1e-12)
    }

    @Test("Lock on does nothing to a single page")
    func lockSingle() async {
        let (m, undo, _) = await loadedSample()
        let before = m.pages[0]
        #expect(!before.isSpread)
        let crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        undoable(undo) { drag(m, page: 0, side: .left, locked: true, to: [crop]) }
        #expect(m.pages[0].leftCrop == crop)
        #expect(m.pages[0].rightCrop == before.rightCrop)
    }

    @Test("Spread to Single re-detects a whole-page crop; undo and redo")
    func typeChange() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread, before = m.pages[i]
        undoable(undo) { m.setClassification(.single, for: before.id) }
        let single = m.pages[i]
        #expect(single.classification == .single)
        #expect(single.leftCrop.width > before.leftCrop.width + 0.2)
        undo.undo()
        #expect(m.pages[i].classification == .spread && m.pages[i].leftCrop == before.leftCrop)
        undo.redo()
        #expect(m.pages[i].classification == .single && m.pages[i].leftCrop == single.leftCrop)
    }

    @Test("Skipping and un-skipping keeps the crops")
    func skipKeepsCrops() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread, before = m.pages[i]
        undoable(undo) { m.setClassification(.skip, for: before.id) }
        undoable(undo) { m.setClassification(.spread, for: before.id) }
        #expect(m.pages[i].leftCrop == before.leftCrop && m.pages[i].rightCrop == before.rightCrop)
    }

    @Test("Skip on a skipped page brings back the type it had, crops kept; one undo step (John, 2026-10-26)")
    func skipAgainUnskips() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread, before = m.pages[i]
        undoable(undo) { m.toggleSkip(for: before.id) }
        #expect(m.pages[i].classification == .skip)
        undoable(undo) { m.toggleSkip(for: before.id) }
        #expect(m.pages[i].classification == .spread && m.pages[i].leftCrop == before.leftCrop
                && m.pages[i].rightCrop == before.rightCrop && m.pages[i].splitX == before.splitX)
        undo.undo()
        #expect(m.pages[i].classification == .skip)
    }

    @Test("Skip on a skipped page from an older save, its type unknown, detects the page again")
    func skipAgainUnknownType() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread, id = m.pages[i].id
        undoable(undo) { m.perform("Old Save") { m.pages[i].classification = .skip; m.pages[i].typeBeforeSkip = nil } }
        undoable(undo) { m.toggleSkip(for: id) }
        #expect(m.pages[i].classification == .spread)
    }

    @Test("A drag is one undo step and leaves other pages' changes alone")
    func dragUndo() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread, other = i + 1
        let before = m.pages[i].splitX
        m.selectedPageID = m.pages[i].id
        undoable(undo) {
            m.beginEdit()
            for k in 1...5 { m.pages[i].splitX = 0.5 + Double(k) * 0.01 }
            m.pages[other].splitX = 0.33          // as if analysis landed mid-drag
            m.endEdit("Move Split")
        }
        #expect(undo.undoActionName == "Move Split")
        undo.undo()
        #expect(m.pages[i].splitX == before)
        #expect(m.pages[other].splitX == 0.33)
    }

    @Test("A drag claims its page at once; a drag that changes nothing releases it")
    func claimAndRelease() async {
        let (m, _, _) = await loadedSample()
        let i = firstSpread
        m.pages[i].analyzed = false
        m.selectedPageID = m.pages[i].id
        m.beginEdit()
        #expect(m.pages[i].analyzed)               // analysis can't overwrite the gesture

        // Press and release without moving, on a page analysis hasn't reached.
        let fresh = BookPage(sourceIndex: m.pages[i].sourceIndex)
        m.endEdit("Straighten")
        m.pages[i] = fresh
        m.selectedPageID = fresh.id
        m.beginEdit(); m.endEdit("Straighten")
        await waitUntilIdle(m)
        #expect(m.pages[i].leftCrop != fresh.leftCrop)   // it still got analyzed
    }

    @Test("Apply crop to alternate single pages, then to all")
    func alternatePages() async {
        let (m, undo, _) = await loadedSample()
        undoable(undo) { for p in m.pages where p.classification != .single { m.setClassification(.single, for: p.id) } }
        let mark = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        m.selectedPageID = m.pages[1].id
        m.pages[1].leftCrop = mark
        undoable(undo) { m.applySingleCrop(alternate: true) }
        #expect(m.pages.indices.filter { m.pages[$0].leftCrop == mark } == [1, 3, 5])
        undoable(undo) { m.applySingleCrop(alternate: false) }
        #expect(m.pages.allSatisfy { $0.leftCrop == mark })
        undo.undo()
        #expect(m.pages.indices.filter { m.pages[$0].leftCrop == mark } == [1, 3, 5])
    }

    @Test("Up/down page navigation stops at the ends")
    func navigation() async {
        let (m, _, _) = await loadedSample()
        m.selectedPageID = m.pages[0].id
        m.selectAdjacentPage(-1); #expect(m.selectedIndex == 0)
        m.selectAdjacentPage(1); #expect(m.selectedIndex == 1)
        m.selectedPageID = m.pages.last!.id
        m.selectAdjacentPage(1); #expect(m.selectedIndex == m.pages.count - 1)
    }

    @Test("Zoom stays within fit…8x and zoomed previews are sharper")
    func zoom() async throws {
        let (m, _, _) = await loadedSample()
        m.zoomOut(); #expect(m.zoom == 1)
        for _ in 0..<20 { m.zoomIn() }; #expect(m.zoom == 8)
        m.zoomToFit(); #expect(m.zoom == 1)
        let page = m.pages[firstSpread]
        let normal = try #require(m.previewImage(for: page))
        let sharp = try #require(m.previewImage(for: page, zoom: 3))
        #expect(abs(sharp.size.width / normal.size.width - 3) < 0.05)
    }

    @Test("Edits and reading order come back when the PDF is reopened")
    func autosave() async throws {
        let (m, undo, url) = await loadedSample()
        let i = firstSpread
        let edited = CropRect(x: 0.11, y: 0.12, width: 0.3, height: 0.7)
        m.selectedPageID = m.pages[i].id
        undoable(undo) { m.perform("Adjust Crop") { m.pages[i].leftCrop = edited } }
        m.direction = .rightToLeft
        try await Task.sleep(nanoseconds: 1_200_000_000)    // autosave waits for a pause

        let reopened = testModel()
        reopened.load(url: url)
        await waitUntilIdle(reopened)
        #expect(reopened.pages[i].leftCrop == edited)
        #expect(reopened.direction == .rightToLeft)
        #expect(reopened.statusText.hasPrefix("Restored"))
    }

    @Test("An edit made just before opening another PDF is still saved")
    func saveOnSwitch() async throws {
        let (m, undo, url) = await loadedSample()
        let i = firstSpread
        let quick = CropRect(x: 0.2, y: 0.2, width: 0.25, height: 0.5)
        undoable(undo) { m.perform("Adjust Crop") { m.pages[i].leftCrop = quick } }
        m.load(url: Fixtures.sampleBook())                    // switch at once
        await waitUntilIdle(m)
        try await Task.sleep(nanoseconds: 300_000_000)
        let reopened = testModel()
        reopened.load(url: url)
        await waitUntilIdle(reopened)
        #expect(reopened.pages[i].leftCrop == quick)
    }

    @Test("New books crop to the whole page")
    func wholePageByDefault() {
        #expect(AppModel().cropTarget == .page)
    }

    @Test("Auto-detect all pages, undo, redo")
    func redetectAll() async {
        let (m, undo, _) = await loadedSample()
        let i = firstSpread, auto = m.pages[i].leftCrop
        let edited = CropRect(x: 0.11, y: 0.12, width: 0.3, height: 0.7)
        undoable(undo) { m.perform("Adjust Crop") { m.pages[i].leftCrop = edited } }
        undoable(undo) { m.autoDetectAllPages() }
        await waitUntilIdle(m)
        #expect(m.pages[i].leftCrop == auto)
        undo.undo()
        #expect(m.pages[i].leftCrop == edited)
        undo.redo()
        await waitUntilIdle(m)
        #expect(m.pages.allSatisfy { $0.analyzed })
    }

    @Test("Auto-straighten all pages finds every angle again, keeps the crops, one undo")
    func straightenAll() async {
        let (m, undo, _) = await loadedSample()
        let found = m.pages.map { ($0.leftSkew, $0.rightSkew) }
        #expect(found.contains { abs($0.0) > 0.1 || abs($0.1) > 0.1 })   // the sample has skewed spreads
        undoable(undo) { m.perform("Level") { for i in m.pages.indices { m.pages[i].leftSkew = 0; m.pages[i].rightSkew = 0 } } }
        let level = m.pages
        undo.beginUndoGrouping()
        await m.autoStraightenAllPages()
        undo.endUndoGrouping()
        for (i, p) in m.pages.enumerated() {
            #expect(abs(p.leftSkew - found[i].0) < 0.01 && abs(p.rightSkew - found[i].1) < 0.01)
            #expect(p.leftCrop == level[i].leftCrop && p.rightCrop == level[i].rightCrop)
        }
        #expect(!m.isBusy)
        #expect(undo.undoActionName == "Auto-straighten All Pages")
        undo.undo()
        #expect(m.pages == level)
    }

    @Test("Auto-straighten all pages leaves a page edited while it runs as edited")
    func straightenAllKeepsEdits() async {
        let (m, undo, _) = await loadedSample()
        undoable(undo) { m.perform("Level") { for i in m.pages.indices { m.pages[i].leftSkew = 0; m.pages[i].rightSkew = 0 } } }
        let i = firstSpread
        undo.beginUndoGrouping()
        let run = Task { await m.autoStraightenAllPages() }
        await Task.yield()                  // the run is now working off the main thread
        #expect(m.isBusy)
        m.pages[i].splitX += 0.03           // the user moves a split meanwhile…
        m.pages[i + 1].classification = .skip   // …and skips the next page
        let edited = (m.pages[i], m.pages[i + 1])
        await run.value
        undo.endUndoGrouping()
        #expect(m.pages[i] == edited.0 && m.pages[i + 1] == edited.1)
        #expect(m.pages.indices.contains { $0 != i && $0 != i + 1 && (m.pages[$0].leftSkew != 0 || m.pages[$0].rightSkew != 0) })
        #expect(!m.isBusy)
    }

    @Test("Crop to whole page re-detects every page; undo, redo, and reopening keep the choice")
    func cropToWholePage() async throws {
        let (m, undo, url) = await loadedSample()
        let i = firstSpread, text = m.pages[i].leftCrop
        undoable(undo) { m.setCropTarget(.page) }
        await waitUntilIdle(m)
        #expect(m.cropTarget == .page)
        // The sample book's scans are cut at the paper: a whole page is its half,
        // less what straightening it turned out of view.
        let whole = m.pages[i].leftCrop, split = m.pages[i].splitX
        let size = try #require(m.document?.page(at: m.pages[i].sourceIndex)).bounds(for: .cropBox).size
        let turn = abs(sin(m.pages[i].leftSkew * .pi / 180))
        let dx = 0.5 * turn * size.height / size.width + 0.01, dy = 0.5 * turn * split * size.width / size.height + 0.01
        #expect(whole.minX < dx && whole.maxX > split - dx && whole.maxX <= split && whole.minY < dy && whole.maxY > 1 - dy,
                "whole page \(whole), turned \(m.pages[i].leftSkew)°")
        #expect(whole.width > text.width && whole.height > text.height)
        #expect(m.pages[0].leftCrop.width > 0.97, "single page \(m.pages[0].leftCrop)")
        undo.undo()
        #expect(m.cropTarget == .text && m.pages[i].leftCrop == text)
        undo.redo()
        await waitUntilIdle(m)
        #expect(m.cropTarget == .page && m.pages[i].leftCrop == whole)
        try await Task.sleep(nanoseconds: 1_200_000_000)    // autosave waits for a pause

        let reopened = testModel()
        reopened.load(url: url)
        await waitUntilIdle(reopened)
        #expect(reopened.cropTarget == .page && reopened.pages[i].leftCrop == whole)
    }

    @Test("Whole page keeps a blank sheet's own paper, though it is smaller than the book's")
    func wholePageBlankSheet() async {
        let media = CGRect(x: 0, y: 0, width: 600, height: 840)
        func page(blank: Bool) -> (CGContext) -> Void {
            { c in
                if blank {                          // a smaller sheet on a dark scanner bed
                    c.setFillColor(CGColor(gray: 0.05, alpha: 1)); c.fill(media)
                    c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 120, y: 140, width: 360, height: 560))
                } else {                            // text on a scan cut at the paper
                    c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(media)
                    c.setFillColor(CGColor(gray: 0.1, alpha: 1))
                    for i in 0..<30 { c.fill(CGRect(x: 80, y: 100 + i * 21, width: 440, height: 8)) }
                }
            }
        }
        let url = Fixtures.writePDF("sheets-\(UUID().uuidString).pdf", media: media,
                                    pages: [page(blank: false), page(blank: false), page(blank: false), page(blank: true)])
        let m = testModel()
        m.load(url: url)
        await waitUntilIdle(m)
        m.setCropTarget(.page)
        await waitUntilIdle(m)
        let c = m.pages[3].leftCrop
        #expect(abs(c.minX - 0.2) < 0.01 && abs(c.maxX - 0.8) < 0.01 && abs(c.minY - 140.0 / 840) < 0.01 && abs(c.maxY - 700.0 / 840) < 0.01,
                "blank sheet cropped to \(c)")
        #expect(m.pages[0].leftCrop.width > 0.98, "full page cropped to \(m.pages[0].leftCrop)")
    }

    @Test("Password-protected PDFs: locked without it, open with it")
    func passwords() {
        let locked = Fixtures.save(Fixtures.markedPage(), "locked.pdf",
                                   options: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"])
        #expect(AppModel.reopen(locked, password: nil) == nil)
        #expect(AppModel.reopen(locked, password: "wrong") == nil)
        #expect(AppModel.reopen(locked, password: "pw") != nil)
        // Restrictions only (no open password): opens with no prompt.
        let ownerOnly = Fixtures.save(Fixtures.markedPage(), "owner-only.pdf",
                                      options: [.ownerPasswordOption: "owner"])
        #expect(AppModel.reopen(ownerOnly, password: nil) != nil)
    }

    @Test("Files that aren't PDFs are refused cleanly")
    func notAPDF() throws {
        let junk = Fixtures.url("junk.pdf")
        try Data("not a pdf".utf8).write(to: junk)
        let m = testModel()
        m.load(url: junk)
        #expect(m.document == nil)
        #expect(m.statusText.hasPrefix("Could not open"))
    }

    @Test("A drag that ends after an undo of an earlier edit stays the page's own (review finding 10)")
    func dragAfterUndoKeepsClaim() async throws {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        let i = 1
        m.pages[i].analyzed = false                            // a page analysis hasn't reached yet
        undoable(undo) { m.perform("Adjust Crop") { m.pages[i].leftCrop = CropRect(x: 0.1, y: 0.1, width: 0.3, height: 0.7) } }
        m.selectedPageID = m.pages[i].id
        let dragged = CropRect(x: 0.15, y: 0.12, width: 0.25, height: 0.6)
        m.beginEdit()
        undo.undo()                                            // the earlier edit, mid-drag: the page waits for analysis again
        #expect(!m.pages[i].analyzed)
        m.pages[i].leftCrop = dragged
        undoable(undo) { m.endEdit("Adjust Crop") }
        await waitUntilIdle(m)
        #expect(m.pages[i].leftCrop == dragged, "\(m.pages[i].leftCrop)")
    }


    @Test("The same, when the drag ends where it began (review finding 10, re-review)")
    func dragBackToStartAfterUndo() async throws {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        let i = 1
        m.pages[i].analyzed = false
        let edited = CropRect(x: 0.1, y: 0.1, width: 0.3, height: 0.7)
        undoable(undo) { m.perform("Adjust Crop") { m.pages[i].leftCrop = edited } }
        m.selectedPageID = m.pages[i].id
        m.beginEdit()
        undo.undo()
        m.pages[i].leftCrop = edited                                // dragged back to where the drag began
        undoable(undo) { m.endEdit("Adjust Crop") }
        await waitUntilIdle(m)
        #expect(m.pages[i].leftCrop == edited, "\(m.pages[i].leftCrop)")
    }

}
