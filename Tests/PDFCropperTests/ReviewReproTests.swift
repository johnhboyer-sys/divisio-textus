import Testing
import Foundation
import CoreGraphics
import PDFKit
import AppKit
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

    // Finding 5 (stack Apply versus the blend) is covered by StackTests.applyMatchesStack
    // and StackTests.trueSizeBlend: John chose a true-size stack (2026-10-22).

    @Test("Scaling a grayscale page for the later OCR readings keeps its pixels")
    func scaledGrayPageIsNotBlack() throws {
        let image = ImageEnhancer.apply(Fixtures.scan(400, 400), mode: .grayscale)
        #expect(image.colorSpace?.model == .monochrome)
        let half = OCRService.scaled(image, by: 0.5)
        #expect(half.width == 200)
        // The scan is white paper with dark marks: mostly bright, like the original.
        let g = try #require(GrayBuffer(cgImage: half))
        let bright = (0..<g.height).reduce(0) { n, y in n + (0..<g.width).filter { g.value($0, y) > 128 }.count }
        #expect(bright * 2 > g.width * g.height)
    }

    @Test("Finding 6: a short centered line below two columns is its own block, after them")
    func centeredLineBelowColumns() {
        // A page number sits in the gutter, under both columns. The columns stop
        // above it, so nothing holds it and it gets no text layer.
        let w = 1700, h = 2200
        let number = CGRect(x: 805, y: 2050, width: 90, height: 12)   // top-left pixels
        let image = Fixtures.image(w, h) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            func fill(_ r: CGRect) {
                c.fill(CGRect(x: r.minX, y: Double(h) - r.maxY, width: r.width, height: r.height))
            }
            for i in 0..<24 {
                let y = 200 + Double(i) * 60
                fill(CGRect(x: 150, y: y, width: 500, height: 18))
                fill(CGRect(x: 1050, y: y, width: 500, height: 18))
            }
            fill(number)
        }
        let blocks = LayoutAnalyzer.columnBlocks(image)
        let point = CGPoint(x: number.midX / Double(w), y: number.midY / Double(h))
        let hit = blocks.firstIndex { $0.contains(point) }
        let columns = blocks.indices.filter { blocks[$0].height > 0.2 }
        #expect(columns.count == 2, "\(blocks)")
        #expect(hit != nil, "no block contains \(point) in \(blocks)")
        if let hit {
            #expect(columns.allSatisfy { $0 < hit }, "block \(hit) is not after the columns \(columns): \(blocks)")
        }
    }

    @Test("Finding 7: a second-pass line already read in parts is not added again")
    func rowNotDoubled() {
        // Pass 1 read the row as two halves; pass 2 read it whole. The whole
        // line's centre falls in the gap, so no pass 1 box holds it.
        let y = 0.50, h = 0.03
        let left = OCRService.Line(text: "left part", box: CGRect(x: 0.10, y: y, width: 0.30, height: h))
        let right = OCRService.Line(text: "right part", box: CGRect(x: 0.50, y: y, width: 0.30, height: h))
        let whole = OCRService.Line(text: "left part right part", box: CGRect(x: 0.10, y: y, width: 0.70, height: h))
        #expect(OCRService.merge([left, right], [whole]).map(\.text).sorted() == ["left part", "right part"])
        // A line over a real gap in pass 1 is still added.
        let dropped = OCRService.Line(text: "the dropped line", box: CGRect(x: 0.55, y: y, width: 0.30, height: h))
        #expect(OCRService.merge([left], [left, dropped]).map(\.text).sorted() == ["left part", "the dropped line"])
    }

    @Test("Finding 8: a word spelled right in any given language passes")
    func spelledRightInAnyLanguage() {
        let available = NSSpellChecker.shared.availableLanguages
        func has(_ code: String) -> Bool {
            let wanted = code.replacingOccurrences(of: "-", with: "_")
            let prefix = String(wanted.prefix(2))
            return available.contains { $0 == wanted || $0 == prefix || $0.hasPrefix(prefix) }
        }
        if has("de-DE") {
            #expect(OCRService.spelledRight("nicht", languages: ["en-US", "de-DE"]))
        }
        #expect(!OCRService.spelledRight("specity", languages: ["en-US"]))
    /// Saved edits for this test only, put back when it ends. Never the real folder.
    private func scratchEdits() throws -> URL {
        _ = Fixtures.directory
        let dir = Fixtures.directory.appendingPathComponent("repro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ProjectStore.directory = dir
        return dir
    }

    private func onePage(_ name: String) -> URL {
        Fixtures.writePDF(name, media: CGRect(x: 0, y: 0, width: 120, height: 120), pages: [{ _ in }])
    }

    @Test("An unreadable save is moved aside, and nil means there was no file")
    func unreadableSaveIsKept() throws {
        _ = Fixtures.directory
        let savedDir = ProjectStore.directory
        defer { ProjectStore.directory = savedDir }
        let dir = try scratchEdits()
        let fm = FileManager.default

        #expect(ProjectStore.load(key: "missing-\(UUID().uuidString)") == nil)

        func put(_ key: String, _ bytes: Data) throws -> URL {
            let url = dir.appendingPathComponent("\(key).json")
            try bytes.write(to: url)
            return url
        }

        let garbage = Data("not json".utf8)
        let garbageKey = "garbage-\(UUID().uuidString)"
        let garbageFile = try put(garbageKey, garbage)
        #expect(ProjectStore.load(key: garbageKey) == nil)
        #expect(!fm.fileExists(atPath: garbageFile.path))
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(garbageKey).unreadable.json")) == garbage)

        let oldVersion = Data(#"{"version":1,"pages":[],"direction":"leftToRight"}"#.utf8)
        let versionKey = "version-\(UUID().uuidString)"
        let versionFile = try put(versionKey, oldVersion)
        #expect(ProjectStore.load(key: versionKey) == nil)
        #expect(!fm.fileExists(atPath: versionFile.path))
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(versionKey).unreadable.json")) == oldVersion)

        let takenKey = "taken-\(UUID().uuidString)"
        let first = Data("first".utf8), second = Data("second".utf8)
        try first.write(to: dir.appendingPathComponent("\(takenKey).unreadable.json"))
        let takenFile = try put(takenKey, second)
        #expect(ProjectStore.load(key: takenKey) == nil)
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(takenKey).unreadable.json")) == first)
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(takenKey).unreadable-2.json")) == second)
        #expect(!fm.fileExists(atPath: takenFile.path))

        let unreadKey = "unread-\(UUID().uuidString)"
        let secret = Data("secret".utf8)
        let unreadFile = try put(unreadKey, secret)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadFile.path)
        #expect(ProjectStore.load(key: unreadKey) == nil)
        let kept = dir.appendingPathComponent("\(unreadKey).unreadable.json")
        #expect(fm.fileExists(atPath: kept.path))
        #expect(!fm.fileExists(atPath: unreadFile.path))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path)
        #expect(try Data(contentsOf: kept) == secret)
    }

    @Test("Opening a PDF whose save can't be read starts fresh and keeps the file")
    func unreadableSaveStartsFresh() async throws {
        _ = Fixtures.directory
        let savedDir = ProjectStore.directory
        defer { ProjectStore.directory = savedDir }
        let dir = try scratchEdits()
        let url = onePage("fresh-\(UUID().uuidString).pdf")
        let key = try #require(ProjectStore.key(for: url))
        let bad = Data("not json".utf8)
        try bad.write(to: dir.appendingPathComponent("\(key).json"))
        let m = testModel()
        m.load(url: url)
        await waitUntilIdle(m)
        let keptName = "\(key).unreadable.json"
        #expect(m.statusText.contains("Couldn't read the saved edits for this PDF, so it starts fresh. They're kept as \(keptName)."))
        #expect(try Data(contentsOf: dir.appendingPathComponent(keptName)) == bad)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(try Data(contentsOf: dir.appendingPathComponent(keptName)) == bad)
        let rewritten = try Data(contentsOf: dir.appendingPathComponent("\(key).json"))
        #expect(rewritten != bad)

        let legacyBad = Data("legacy bad".utf8)
        let url2 = onePage("legacy-fresh-\(UUID().uuidString).pdf")
        let legacy2 = try #require(ProjectStore.legacyKey(for: url2))
        #expect(ProjectStore.key(for: url2) != legacy2)
        try legacyBad.write(to: dir.appendingPathComponent("\(legacy2).json"))
        let m2 = testModel()
        m2.load(url: url2)
        await waitUntilIdle(m2)
        let legacyKept = "\(legacy2).unreadable.json"
        #expect(m2.statusText.contains("Couldn't read the saved edits for this PDF, so it starts fresh. They're kept as \(legacyKept)."))
        #expect(try Data(contentsOf: dir.appendingPathComponent(legacyKept)) == legacyBad)
    }

    @Test("A save that can't be moved aside is not written over")
    func unreadableSaveNotOverwritten() async throws {
        _ = Fixtures.directory
        let savedDir = ProjectStore.directory
        let dir = try scratchEdits()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            ProjectStore.directory = savedDir
        }
        let url = onePage("blocked-\(UUID().uuidString).pdf")
        let key = try #require(ProjectStore.key(for: url))
        let file = dir.appendingPathComponent("\(key).json")
        let bad = Data("keep me".utf8)
        try bad.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let m = testModel()
        m.load(url: url)
        await waitUntilIdle(m)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(m.statusText.contains("edits won't be saved"))
        #expect(try Data(contentsOf: file) == bad)
        m.pages[0].leftCrop = CropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(try Data(contentsOf: file) == bad)
    }

    @Test("Keep Working on a failed save does not open the other PDF or quit")
    func failedSaveAsksBeforeDroppingEdits() async throws {
        _ = Fixtures.directory
        let savedDir = ProjectStore.directory
        defer { ProjectStore.directory = savedDir }
        let dir = try scratchEdits()
        let url = onePage("keep-\(UUID().uuidString).pdf")
        let m = testModel()
        m.confirmFailedSave = { true }
        m.load(url: url)
        await waitUntilIdle(m)
        let crop = CropRect(x: 0.21, y: 0.22, width: 0.33, height: 0.44)
        m.pages[0].leftCrop = crop
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let key = try #require(ProjectStore.key(for: url))
        let file = dir.appendingPathComponent("\(key).json")
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        var asked = 0
        m.confirmFailedSave = { asked += 1; return true }
        let other = onePage("other-\(UUID().uuidString).pdf")
        m.load(url: other)
        #expect(asked == 1)
        #expect(m.sourceURL == url)
        #expect(m.pages[0].leftCrop == crop)

        m.confirmFailedSave = { asked += 1; return false }
        m.load(url: other)
        await waitUntilIdle(m)
        #expect(asked == 2)
        #expect(m.sourceURL == other)

        let again = testModel()
        again.confirmFailedSave = { true }
        again.load(url: url)
        await waitUntilIdle(again)
        again.pages[0].leftCrop = crop
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let againKey = try #require(ProjectStore.key(for: url))
        let againFile = dir.appendingPathComponent("\(againKey).json")
        try? FileManager.default.removeItem(at: againFile)
        try FileManager.default.createDirectory(at: againFile, withIntermediateDirectories: true)
        let delegate = AppDelegate()
        delegate.watch(again)
        let reply = delegate.applicationShouldTerminate(NSApplication.shared)
        #expect(reply == .terminateCancel)
        #expect(again.sourceURL == url)
        again.confirmFailedSave = { false }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test("A bad export file is not treated as finished")
    func incompleteExportIsRejected() throws {
        let good = Fixtures.writePDF("complete-\(UUID().uuidString).pdf",
                                     media: CGRect(x: 0, y: 0, width: 100, height: 100),
                                     pages: [{ _ in }, { _ in }])
        #expect(PDFExporter.isComplete(good, pageCount: 2))
        #expect(!PDFExporter.isComplete(good, pageCount: 1))
        let bad = Fixtures.url("truncated-\(UUID().uuidString).pdf")
        try Data("%PDF-1.3 not a whole file".utf8).write(to: bad)
        #expect(!PDFExporter.isComplete(bad, pageCount: 1))
        #expect(!PDFExporter.isComplete(Fixtures.url("missing-\(UUID().uuidString).pdf"), pageCount: 0))
    }

    @Test("Export stops when the source file changed after it was opened")
    func exportStopsWhenSourceChanges() async throws {
        let src = onePage("swap-src-\(UUID().uuidString).pdf")
        let m = testModel()
        m.load(url: src)
        await waitUntilIdle(m)
        let out = Fixtures.url("swap-out-\(UUID().uuidString).pdf")
        try Data("keep".utf8).write(to: out)
        let replacement = onePage("swap-other-\(UUID().uuidString).pdf")
        try Data(contentsOf: replacement).write(to: src)
        m.export(to: out)
        await waitUntilIdle(m)
        #expect(m.statusText == "\(src.lastPathComponent) changed after it was opened. Open it again to export.")
        #expect(try Data(contentsOf: out) == Data("keep".utf8))
        #expect(!m.isExporting)
    }

    @Test("A page size can use a decimal comma")
    func decimalCommaPageSize() {
        #expect(PageSize.inches("6,5") == 6.5)
        #expect(PageSize(parsing: "6,5 x 9") == PageSize(width: 6.5, height: 9))
        #expect(PageSize(parsing: "6,5 × 9,25") == PageSize(width: 6.5, height: 9.25))
        #expect(PageSize(parsing: "6 x 9") == PageSize(width: 6, height: 9))
        #expect(PageSize(parsing: "6×9") == PageSize(width: 6, height: 9))
        #expect(PageSize(parsing: "5.5 X 8.25 in") == PageSize(width: 5.5, height: 8.25))
        #expect(PageSize(parsing: "6 by 9") == PageSize(width: 6, height: 9))
        #expect(PageSize.inches("6") == 6)
        #expect(PageSize.inches(" 5.45 ") == 5.45)
        #expect(PageSize.inches("6 cm") == nil)
        #expect(PageSize.inches("6..5") == nil)
        #expect(PageSize(parsing: "6 x 9 cm") == nil)
        #expect(PageSize(parsing: "") == nil)
    // Codex review of 2026-10-30 (docs/review-2026-10-30.md), analysis findings.

    /// A 1700×2200 page; `draw` works in pixels from the top left.
    private func page(_ draw: (CGContext, (CGFloat, CGFloat, CGFloat, CGFloat) -> Void) -> Void) -> CGImage {
        Fixtures.image(1700, 2200) { c in
            draw(c) { x, y, w, h in c.fill(CGRect(x: x, y: 2200 - y - h, width: w, height: h)) }
        }
    }

    private func dark(_ c: CGContext, _ gray: CGFloat = 0.05) { c.setFillColor(CGColor(gray: gray, alpha: 1)) }

    /// Lines of text-like bars, 60 px apart.
    private func bars(_ box: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void, x: CGFloat, width: CGFloat, y: CGFloat, lines: Int) {
        for i in 0..<lines { box(x, y + CGFloat(i) * 60, width, 26) }
    }

    @Test("Review item 2: a page-sized plate near the edge stays in both crop modes",
          arguments: [(110, 1980), (44, 1980), (176, 1980), (66, 2068)] as [(CGFloat, CGFloat)])
    func widePlateKept(y: CGFloat, height: CGFloat) {
        let img = page { c, box in dark(c); box(34, y, 1630, height) }
        let text = PageAnalyzer.analyze(cgImage: img, as: .single)
        #expect(text.leftCrop.minX < 0.03 && text.leftCrop.maxX > 0.97, "text x \(text.leftCrop.minX)…\(text.leftCrop.maxX)")
        #expect(text.leftCrop.minY <= y / 2200 + 0.001 && text.leftCrop.maxY >= (y + height) / 2200 - 0.001,
                "text y \(text.leftCrop.minY)…\(text.leftCrop.maxY)")
        let whole = PageAnalyzer.analyze(cgImage: img, as: .single, target: .page)
        #expect(whole.leftCrop.minX < 0.001 && whole.leftCrop.maxX > 0.999, "page x \(whole.leftCrop.minX)…\(whole.leftCrop.maxX)")
        #expect(whole.leftCrop.minY < 0.001 && whole.leftCrop.maxY > 0.999, "page y \(whole.leftCrop.minY)…\(whole.leftCrop.maxY)")
    }

    @Test("Review item 2: a plate beside text stays, by either side of the page", arguments: [false, true])
    func plateBesideTextKept(rightSide: Bool) {
        let img = page { c, box in
            dark(c); box(rightSide ? 1700 - 34 - 620 : 34, 110, 620, 1980)
            bars(box, x: rightSide ? 150 : 760, width: 790, y: 200, lines: 30)
        }
        let text = PageAnalyzer.analyze(cgImage: img, as: .single).leftCrop
        let whole = PageAnalyzer.analyze(cgImage: img, as: .single, target: .page).leftCrop
        if rightSide {
            #expect(text.maxX > 0.97, "text x \(text.minX)…\(text.maxX)")
        } else {
            #expect(text.minX < 0.03, "text x \(text.minX)…\(text.maxX)")
        }
        #expect(whole.minX < 0.001 && whole.maxX > 0.999, "page x \(whole.minX)…\(whole.maxX)")
    }

    @Test("Review item 2: a wide plate near the top stays, in both crop modes")
    func plateNearTopKept() {
        let img = page { c, box in
            dark(c); box(110, 44, 1480, 900)
            bars(box, x: 200, width: 1300, y: 1050, lines: 15)
        }
        let text = PageAnalyzer.analyze(cgImage: img, as: .single).leftCrop
        #expect(text.minY < 0.03, "text y \(text.minY)…\(text.maxY)")
        let whole = PageAnalyzer.analyze(cgImage: img, as: .single, target: .page).leftCrop
        #expect(whole.minY < 0.001, "page y \(whole.minY)…\(whole.maxY)")
    }

    @Test("Review item 2: a real band behind a light strip is still trimmed, on either side",
          arguments: [(0, 2200), (20, 2180), (0, 2185)] as [(CGFloat, CGFloat)])
    func bandBehindStripStillTrimmed(from y0: CGFloat, to y1: CGFloat) {
        for rightSide in [false, true] {
            let img = page { c, box in
                dark(c); box(rightSide ? 1700 - 20 - 300 : 20, y0, 300, y1 - y0)   // a light strip, then the band
                bars(box, x: 500, width: 700, y: 200, lines: 30)
            }
            let text = PageAnalyzer.analyze(cgImage: img, as: .single).leftCrop
            let whole = PageAnalyzer.analyze(cgImage: img, as: .single, target: .page).leftCrop
            if rightSide {
                #expect(text.maxX < 1380.0 / 1700 + 0.002, "text x \(text.minX)…\(text.maxX)")
                #expect(abs(whole.maxX - 1380.0 / 1700) < 0.005, "page x \(whole.minX)…\(whole.maxX)")
            } else {
                #expect(text.minX > 320.0 / 1700 - 0.002, "text x \(text.minX)…\(text.maxX)")
                #expect(abs(whole.minX - 320.0 / 1700) < 0.005, "page x \(whole.minX)…\(whole.maxX)")
            }
        }
    }

    @Test("Review note: a thin page number stays in Crop to Text, above or below the text",
          arguments: [(14, 26, false), (14, 26, true), (14, 40, false), (10, 26, false)] as [(CGFloat, CGFloat, Bool)])
    func thinPageNumberKept(width: CGFloat, height: CGFloat, above: Bool) {
        let numberY: CGFloat = above ? 90 : 2060
        let img = page { c, box in
            dark(c, 0.1)
            bars(box, x: 200, width: 1300, y: 300, lines: 25)
            box(843, numberY, width, height)
        }
        let r = PageAnalyzer.analyze(cgImage: img, as: .single).leftCrop
        if above {
            #expect(r.minY <= numberY / 2200, "y \(r.minY)…\(r.maxY)")
        } else {
            #expect(r.maxY >= (numberY + height) / 2200, "y \(r.minY)…\(r.maxY)")
        }
    }

    @Test("Review note: dust and scratches above or below the text don't widen the crop",
          arguments: [(6, 6), (12, 12), (15, 10), (2, 40), (3, 90)] as [(CGFloat, CGFloat)])
    func dustLeftOut(width: CGFloat, height: CGFloat) {
        let clean = page { c, box in dark(c, 0.1); bars(box, x: 200, width: 1300, y: 300, lines: 25) }
        let specked = page { c, box in
            dark(c, 0.1)
            bars(box, x: 200, width: 1300, y: 300, lines: 25)
            box(843, 2060, width, height); box(600, 90, width, height)
        }
        let a = PageAnalyzer.analyze(cgImage: clean, as: .single).leftCrop
        let b = PageAnalyzer.analyze(cgImage: specked, as: .single).leftCrop
        #expect(a == b, "clean \(a), specked \(b)")
    }

    @Test("Review note: an inverted page keeps all of its region when trimming takes everything",
          arguments: [0.0..<1.0, 0.0..<0.5, 0.5..<1.0])
    func invertedPageKeptWhole(range: Range<Double>) throws {
        let img = page { c, box in
            dark(c, 0.03); box(0, 0, 1700, 2200)
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            for side: CGFloat in [150, 1000] { bars(box, x: side, width: 550, y: 300, lines: 25) }
        }
        let g = try #require(GrayBuffer(cgImage: img))
        let r = PageAnalyzer.contentBounds(g, xRange: range)
        #expect(!r.blank)
        #expect(abs(r.crop.minX - range.lowerBound) < 1e-9 && abs(r.crop.maxX - range.upperBound) < 1e-9, "x \(r.crop.minX)…\(r.crop.maxX)")
        #expect(r.crop.minY == 0 && r.crop.maxY == 1, "y \(r.crop.minY)…\(r.crop.maxY)")
    }
}
