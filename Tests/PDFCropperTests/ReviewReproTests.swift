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

    @Test("Finding 1: exporting over the scan is refused, so the scan and later exports stay right")
    func exportOverSourceThenAgain() async throws {
        let (m, _, src) = await loaded()
        let before = try Data(contentsOf: src)
        let baseline = try #require(await exportAndOpen(m, "f1-baseline.pdf"))
        m.export(to: src); await waitUntilIdle(m)
        #expect(try Data(contentsOf: src) == before)               // the scan is untouched
        #expect(m.sourceURL == src)
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

    @Test("Finding 4 (re-review): a page skipped before types were remembered still re-detects")
    func olderSkippedPage() async {
        let (direct, directUndo, _) = await loaded()
        let (via, viaUndo, _) = await loaded()
        let i = 1
        undoable(directUndo) { direct.setClassification(.single, for: direct.pages[i].id) }
        via.pages[i].classification = .skip                         // as an older save left it:
        via.pages[i].typeBeforeSkip = nil                           // a spread's crops, no type kept
        undoable(viaUndo) { via.setClassification(.single, for: via.pages[i].id) }
        #expect(via.pages[i].leftCrop == direct.pages[i].leftCrop)
    }

    @Test("Finding 3 (re-review): an older save moves to the new key once and can't reach another PDF")
    func legacySaveMovesOnce() async throws {
        _ = Fixtures.directory
        let (m, _, url) = await loaded()
        let legacy = try #require(ProjectStore.legacyKey(for: url)), key = try #require(ProjectStore.key(for: url))
        m.pages[1].leftCrop = CropRect(x: 0.11, y: 0.1, width: 0.3, height: 0.7)
        try ProjectStore.save(ProjectStore.Saved(pages: m.pages, direction: m.direction, cropTarget: m.cropTarget),
                              key: legacy)                          // a save made before whole-file keys
        try? FileManager.default.removeItem(at: ProjectStore.directory!.appendingPathComponent("\(key).json"))
        let n = testModel()
        n.load(url: url); await waitUntilIdle(n)
        #expect(n.pages[1].leftCrop == m.pages[1].leftCrop)         // restored
        #expect(ProjectStore.load(key: legacy) == nil)              // and no longer there for another PDF
        #expect(ProjectStore.load(key: key) != nil)
    }

    @Test("Finding 4 (round 3): an older skipped page with a widened crop still re-detects")
    func olderSkippedPageWidenedCrop() async {
        let (direct, directUndo, _) = await loaded()
        let (via, viaUndo, _) = await loaded()
        let i = 1
        undoable(directUndo) { direct.setClassification(.single, for: direct.pages[i].id) }
        via.pages[i].classification = .skip
        via.pages[i].typeBeforeSkip = nil
        via.pages[i].leftCrop = CropRect(x: 0.05, y: 0.1, width: 0.55, height: 0.8)   // dragged past the split
        undoable(viaUndo) { via.setClassification(.single, for: via.pages[i].id) }
        #expect(via.pages[i].leftCrop == direct.pages[i].leftCrop)
    }

    @Test("Finding 3 (round 3): an older save stays if it can't be saved under the new key")
    func legacySaveKeptWhenNewSaveFails() async throws {
        _ = Fixtures.directory
        let (m, _, url) = await loaded()
        let legacy = try #require(ProjectStore.legacyKey(for: url)), key = try #require(ProjectStore.key(for: url))
        try ProjectStore.save(ProjectStore.Saved(pages: m.pages, direction: m.direction, cropTarget: m.cropTarget), key: legacy)
        let newFile = ProjectStore.directory!.appendingPathComponent("\(key).json")
        try? FileManager.default.removeItem(at: newFile)
        try FileManager.default.createDirectory(at: newFile, withIntermediateDirectories: true)   // a save there fails
        defer { try? FileManager.default.removeItem(at: newFile) }
        let n = testModel()
        n.load(url: url); await waitUntilIdle(n)
        #expect(ProjectStore.load(key: legacy) != nil)
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
