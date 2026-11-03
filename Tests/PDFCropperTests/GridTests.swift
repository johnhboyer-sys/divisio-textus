import Testing
import Foundation
import CoreGraphics
@testable import PDFCropper

/// Grid view: choosing pages, and the sidebar acting on all of them.
@Suite("Grid view", .serialized)
@MainActor
struct GridTests {

    private func load() async -> (AppModel, UndoManager) {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.load(url: Fixtures.sampleBook())
        await waitUntilIdle(m)
        return (m, undo)
    }

    @Test("A value all share shows; differing ones are mixed (nil)")
    func shared() {
        #expect([1.5, 1.5, 1.5].shared == 1.5)
        #expect([1.5, 2.0].shared == nil)
        #expect([Double]().shared == nil)
        let us = Locale(identifier: "en_US")
        let same = CropSizeReadout(left: CGSize(width: 400, height: 600), right: CGSize(width: 400, height: 600), unit: .inches, locale: us)
        let taller = CropSizeReadout(left: CGSize(width: 400, height: 600), right: CGSize(width: 400, height: 636), unit: .inches, locale: us)
        #expect(CropSizeReadout.difference(of: [taller]) == ("Right 0.50 in taller", true))
        #expect(CropSizeReadout.difference(of: [same, same]) == ("Equal", false))
        #expect(CropSizeReadout.difference(of: [taller, taller, taller]) == ("Unequal on all 3", true))
        #expect(CropSizeReadout.difference(of: [same, taller, taller]) == ("Unequal on 2 of 3", true))
    }

    @Test("Click, ⌘-click and ⇧-click choose; the grid starts with the page shown, and keeps a choice that holds it")
    func choosing() async {
        let (m, _) = await load()
        let ids = m.pages.map(\.id)
        m.selectedPageID = ids[1]
        m.viewMode = .grid
        #expect(m.gridSelection == [ids[1]] && m.sidebarTargets == [ids[1]])
        m.chooseInGrid(ids[3], .toggle, order: ids)
        #expect(m.sidebarTargets == [ids[1], ids[3]] && m.selectedPageID == ids[3])
        m.chooseInGrid(ids[5], .range, order: ids)
        #expect(m.sidebarTargets == [ids[3], ids[4], ids[5]] && m.selectedPageID == ids[5])
        m.chooseInGrid(ids[5], .toggle, order: ids)                 // ⌘-click takes one out
        #expect(m.sidebarTargets == [ids[3], ids[4]] && m.selectedPageID == ids[3])
        m.chooseInGrid(ids[2], .plain, order: ids)
        #expect(m.sidebarTargets == [ids[2]])
        // Out to Page view and back on a page of the choice keeps it; another page starts afresh.
        m.chooseInGrid(ids[4], .toggle, order: ids)
        m.viewMode = .page
        m.viewMode = .grid
        #expect(m.sidebarTargets == [ids[2], ids[4]])
        m.openInPageView(ids[0])
        #expect(m.viewMode == .page && m.sidebarTargets == [ids[0]])
        m.viewMode = .grid
        #expect(m.sidebarTargets == [ids[0]])
        // ↓ moves the choice in the grid too.
        m.selectAdjacentPage(1)
        #expect(m.sidebarTargets == [ids[1]])
    }

    @Test("Type, Export and Straighten act on every page chosen, each as one undo step")
    func actsOnAll() async {
        let (m, undo) = await load()
        let chosen = [m.pages[2].id, m.pages[3].id, m.pages[4].id]
        undoable(undo) { m.setOmittedSide(.right, for: chosen) }
        #expect(m.pages[2...4].allSatisfy { $0.omittedSide == .right } && m.pages[5].omittedSide == nil)
        undo.undo()
        #expect(m.pages[2...4].allSatisfy { $0.omittedSide == nil })

        let before = m.pages.map(\.leftSkew)
        undo.beginUndoGrouping()
        m.beginEdit(of: chosen)
        m.setSkew(1.0, side: .left, for: chosen)
        m.setSkew(1.5, side: .left, for: chosen)
        m.endEdit(of: chosen, "Straighten")
        undo.endUndoGrouping()
        #expect(m.pages[2...4].allSatisfy { $0.leftSkew == 1.5 } && m.pages[5].leftSkew == before[5])
        undo.undo()
        #expect(m.pages.map(\.leftSkew) == before)

        undoable(undo) { m.setClassification(.skip, for: chosen) }
        #expect(m.pages[2...4].allSatisfy { $0.classification == .skip })
        undo.undo()
        #expect(m.pages[2...4].allSatisfy { $0.classification == .spread })
    }

    @Test("Trim from the grid draws on the last page clicked, trims every page chosen, and goes back to the grid")
    func trimsAll() async {
        let (m, undo) = await load()
        let ids = m.pages.map(\.id)
        m.selectedPageID = ids[2]
        m.viewMode = .grid
        m.chooseInGrid(ids[4], .toggle, order: ids)
        m.beginTrim(selection: m.sidebarTargets)
        #expect(m.viewMode == .page && m.trimmingPage == ids[4])
        let trim = CropRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        m.trimDraft = trim
        undoable(undo) { m.finishTrim() }
        #expect(m.viewMode == .grid && m.sidebarTargets == [ids[2], ids[4]])
        #expect(m.pages[2].trim == trim && m.pages[4].trim == trim && m.pages[3].trim == nil)
        undo.undo()
        #expect(m.pages[2].trim == nil && m.pages[4].trim == nil)
        // Cancel goes back too, and trims nothing.
        m.beginTrim(selection: m.sidebarTargets)
        m.cancelTrim()
        #expect(m.viewMode == .grid && m.pages.allSatisfy { $0.trim == nil })
    }

    @Test("Needs a look: the grid's arrows and the sidebar keep to the pages it shows (Codex review)")
    func filtered() {
        let m = testModel()
        // Pages 1 and 3's left crops are wider than the rest of their stack's.
        m.pages = (0..<5).map { i in
            var page = BookPage(sourceIndex: i, splitX: 0.5, analyzed: true)
            page.leftCrop = CropRect(x: 0.05, y: 0.1, width: i == 1 || i == 3 ? 0.40 : 0.30, height: 0.8)
            page.rightCrop = CropRect(x: 0.55, y: 0.1, width: 0.3, height: 0.8)
            return page
        }
        let ids = m.pages.map(\.id)
        #expect(Set(m.flaggedSides.keys) == [ids[1], ids[3]])
        m.selectedPageID = ids[0]
        m.viewMode = .grid
        m.chooseInGrid(ids[1], .toggle, order: ids)
        m.showsOnlyFlagged = true
        #expect(m.gridPages.map(\.id) == [ids[1], ids[3]])
        #expect(m.sidebarTargets == [ids[1]])                       // page 0 is hidden, so left alone
        m.selectAdjacentPage(1)
        #expect(m.selectedPageID == ids[3] && m.sidebarTargets == [ids[3]])
        m.selectAdjacentPage(1)
        #expect(m.selectedPageID == ids[3])
        m.selectAdjacentPage(-1)
        #expect(m.selectedPageID == ids[1])
    }

    @Test("Opening another PDF starts the grid afresh on its first page (Codex review)")
    func reload() async {
        let (m, _) = await load()
        let ids = m.pages.map(\.id)
        m.viewMode = .grid
        m.chooseInGrid(ids[2], .plain, order: ids)
        m.chooseInGrid(ids[4], .toggle, order: ids)
        let other = Fixtures.writePDF("grid-reload.pdf", media: CGRect(x: 0, y: 0, width: 400, height: 600),
                                      pages: [{ _ in }, { _ in }])
        m.load(url: other)
        await waitUntilIdle(m)
        #expect(m.viewMode == .grid && m.pages.count == 2)
        #expect(m.gridSelection == [m.pages[0].id] && m.sidebarTargets == [m.pages[0].id])
    }
}
