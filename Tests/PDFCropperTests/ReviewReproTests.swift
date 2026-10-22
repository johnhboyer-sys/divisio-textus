import Testing
import Foundation
import PDFKit
@testable import PDFCropper

/// One test per defect a code review reported. Each asserts the correct behavior,
/// so a failure means the defect is real on the current code.
@Suite("Review findings", .serialized)
@MainActor
struct ReviewReproTests {

    private func loaded() async -> (AppModel, UndoManager, URL) {
        let m = testModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        let url = Fixtures.sampleBook()
        m.load(url: url)
        await waitUntilIdle(m)
        return (m, undo, url)
    }

    private func sizes(_ d: PDFDocument) -> [CGSize] {
        (0..<d.pageCount).map { d.page(at: $0)!.bounds(for: .mediaBox).size }
    }

    @Test("Finding 1: a second export after exporting over the source matches an export before it")
    func exportOverSourceThenAgain() async throws {
        let (m, _, src) = await loaded()
        let baseline = try #require(await exportAndOpen(m, "f1-baseline.pdf"))
        m.export(to: src); await waitUntilIdle(m)
        let second = try #require(await exportAndOpen(m, "f1-second.pdf"))
        #expect(second.pageCount == baseline.pageCount)
        let a = sizes(baseline), b = sizes(second)
        #expect(a.count == b.count && zip(a, b).allSatisfy { abs($0.width - $1.width) < 1 && abs($0.height - $1.height) < 1 })
    }

    @Test("Finding 2: reopening the same PDF at once keeps a crop just edited")
    func reloadKeepsLatestEdit() async throws {
        var lost = 0, lostAfterPause = 0
        let runs = 10
        let edited = CropRect(x: 0.123, y: 0.2, width: 0.3, height: 0.6)
        for pause in [false, true] {
            for _ in 0..<runs {
                let (m, undo, url) = await loaded()
                let i = 1
                undoable(undo) {
                    m.beginEdit(); m.pages[i].leftCrop = edited; m.endEdit("Move Crop")
                }
                if pause { try await Task.sleep(nanoseconds: 1_500_000_000) }   // control: let the save land
                m.load(url: url)
                await waitUntilIdle(m)
                if m.pages[i].leftCrop != edited { if pause { lostAfterPause += 1 } else { lost += 1 } }
            }
        }
        #expect(lostAfterPause == 0, "control: edit lost in \(lostAfterPause) of \(runs) reloads even after a pause")
        #expect(lost == 0, "edit lost in \(lost) of \(runs) immediate reloads")
    }

    @Test("Finding 3: PDFs that differ only after the first 4 MB get different project keys")
    func projectKeyCoversWholeFile() throws {
        _ = Fixtures.directory
        let base = try Data(contentsOf: Fixtures.sampleBook())
        func file(_ name: String, tail: UInt8) throws -> URL {
            var d = base
            d.append(Data(repeating: UInt8(ascii: "x"), count: 5 << 20))
            d.append(tail)
            let u = Fixtures.url(name)
            try d.write(to: u)
            return u
        }
        let a = try file("f3-a.pdf", tail: UInt8(ascii: "A")), b = try file("f3-b.pdf", tail: UInt8(ascii: "B"))
        #expect(PDFDocument(url: a)?.pageCount == PDFDocument(url: b)?.pageCount)
        #expect(try Data(contentsOf: a).count == Data(contentsOf: b).count)
        #expect(ProjectStore.key(for: a) != ProjectStore.key(for: b))
    }

    @Test("Finding 4a: Spread → Skip → Single re-detects a whole-page crop")
    func spreadSkipSingle() async {
        let (direct, directUndo, _) = await loaded()
        let (via, viaUndo, _) = await loaded()
        let i = 1
        let spreadCrop = via.pages[i].leftCrop
        undoable(directUndo) { direct.setClassification(.single, for: direct.pages[i].id) }
        undoable(viaUndo) { via.setClassification(.skip, for: via.pages[i].id) }
        undoable(viaUndo) { via.setClassification(.single, for: via.pages[i].id) }
        #expect(direct.pages[i].leftCrop.width > spreadCrop.width + 0.2)   // the direct path is correct
        #expect(via.pages[i].leftCrop == direct.pages[i].leftCrop)
    }

    @Test("Finding 4b: Single → Skip → Spread re-detects both crops")
    func singleSkipSpread() async {
        let (direct, directUndo, _) = await loaded()
        let (via, viaUndo, _) = await loaded()
        let i = 0
        undoable(directUndo) { direct.setClassification(.spread, for: direct.pages[i].id) }
        undoable(viaUndo) { via.setClassification(.skip, for: via.pages[i].id) }
        undoable(viaUndo) { via.setClassification(.spread, for: via.pages[i].id) }
        #expect(via.pages[i].splitX == direct.pages[i].splitX)
        #expect(via.pages[i].leftCrop == direct.pages[i].leftCrop)
        #expect(via.pages[i].rightCrop == direct.pages[i].rightCrop)
    }

    @Test("Finding 5: Apply puts a drawn box where the blend shows it, whatever each page's split",
          .disabled("Waits on John's decision on how stack boxes are sized (2026-10-22)"))
    func stackApplyMatchesBlend() throws {
        for kind in [PageStack.Kind.left, .right] {
            let pages = [0.45, 0.55].enumerated().map { BookPage(sourceIndex: $0.offset, splitX: $0.element) }
            let stack = try #require(PageStack.groups(pages: pages).first { $0.id == kind })
            let draft = CropRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
            for member in stack.members {
                // The blend scales each side to the same width, so a local x is the same
                // share of every side: it covers pageCrop(draft) on this page.
                let shown = member.pageCrop(draft)
                let applied = member.clampedCrop(draft, usualWidth: stack.usualRegionWidth)
                #expect(abs(applied.minX - shown.minX) < 0.005 && abs(applied.maxX - shown.maxX) < 0.005,
                        "\(kind) split \(member.page.splitX): shown \(shown.minX)…\(shown.maxX), applied \(applied.minX)…\(applied.maxX)")
            }
        }
    }
}
