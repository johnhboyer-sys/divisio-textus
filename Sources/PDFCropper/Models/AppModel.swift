import Foundation
import PDFKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var document: PDFDocument?
    @Published var sourceURL: URL?
    @Published var pages: [BookPage] = []
    @Published var selectedPageID: BookPage.ID?

    @Published var direction: ReadingDirection = .leftToRight
    @Published var exportDPI: Double = 300
    @Published var autoDeskewEnabled = true
    @Published var ocrEnabled = true
    @Published var enhanceMode: EnhanceMode = .color {
        didSet { if enhanceMode != oldValue { clearImageCaches() } }
    }

    @Published var isAnalyzing = false
    @Published var isExporting = false
    var isBusy: Bool { isAnalyzing || isExporting }
    @Published var statusText = "Open a scanned PDF to begin."
    @Published var exportProgress: Double = 0

    /// The window's undo manager (set by ContentView), so Edit ▸ Undo reverts page edits.
    var undoManager: UndoManager?

    // Preview-image cache keyed by source page index, remembering what the cached
    // composite was built with so any change re-renders. Each entry is a full page
    // at preview DPI, so only the most recently viewed few are kept.
    private struct CachedPreview {
        let left: Double, right: Double, split: Double, isSpread: Bool
        let image: NSImage
    }
    private var previewCache: [Int: CachedPreview] = [:]
    private var previewOrder: [Int] = []          // least recently used first
    private let previewCacheLimit = 12
    private let previewDPI: Double = 110

    // Thumbnails are small (unstraightened) renders, cheap enough to keep for every page.
    private var thumbnailCache: [Int: NSImage] = [:]
    private let thumbnailDPI: Double = 30

    /// The page as it was when a drag or slider edit began (see beginEdit / endEdit).
    private var editSnapshot: BookPage?

    var selectedPage: BookPage? {
        guard let id = selectedPageID else { return nil }
        return pages.first { $0.id == id }
    }

    var selectedIndex: Int? {
        guard let id = selectedPageID else { return nil }
        return pages.firstIndex { $0.id == id }
    }

    var outputPageCount: Int {
        pages.reduce(0) { $0 + $1.outputCrops(direction: direction).count }
    }

    // MARK: - Import

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func load(url: URL) {
        guard let doc = PDFDocument(url: url) else {
            statusText = "Could not open \(url.lastPathComponent)."
            return
        }
        clearImageCaches()
        undoManager?.removeAllActions()
        editSnapshot = nil
        document = doc
        sourceURL = url
        isAnalyzing = false   // any analysis of the previous PDF is abandoned
        pages = (0..<doc.pageCount).map { BookPage(sourceIndex: $0) }
        selectedPageID = pages.first?.id
        statusText = "Loaded \(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s"). Analyzing…"
        analyzeAll()
    }

    // MARK: - Previews

    func previewImage(for page: BookPage) -> NSImage? {
        if let c = previewCache[page.sourceIndex],
           c.left == page.leftSkew, c.right == page.rightSkew,
           c.split == page.splitX, c.isSpread == page.isSpread {
            touchPreview(page.sourceIndex)
            return c.image
        }
        guard let doc = document, let pdfPage = doc.page(at: page.sourceIndex),
              let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { return nil }
        let composite = ImageTransform.deskewedComposite(
            cg, splitX: page.splitX,
            leftDegrees: page.leftSkew, rightDegrees: page.rightSkew,
            isSpread: page.isSpread)
        let enhanced = ImageEnhancer.apply(composite, mode: enhanceMode)
        let img = NSImage(cgImage: enhanced, size: NSSize(width: enhanced.width, height: enhanced.height))
        previewCache[page.sourceIndex] = CachedPreview(
            left: page.leftSkew, right: page.rightSkew, split: page.splitX,
            isSpread: page.isSpread, image: img)
        touchPreview(page.sourceIndex)
        return img
    }

    func thumbnail(for page: BookPage) -> NSImage? {
        if let t = thumbnailCache[page.sourceIndex] { return t }
        guard let doc = document, let pdfPage = doc.page(at: page.sourceIndex),
              let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: thumbnailDPI) else { return nil }
        let enhanced = ImageEnhancer.apply(cg, mode: enhanceMode)
        let img = NSImage(cgImage: enhanced, size: NSSize(width: enhanced.width, height: enhanced.height))
        thumbnailCache[page.sourceIndex] = img
        return img
    }

    private func touchPreview(_ index: Int) {
        previewOrder.removeAll { $0 == index }
        previewOrder.append(index)
        while previewOrder.count > previewCacheLimit {
            previewCache[previewOrder.removeFirst()] = nil
        }
    }

    private func clearImageCaches() {
        previewCache.removeAll()
        previewOrder.removeAll()
        thumbnailCache.removeAll()
    }

    /// Detect skew for each book page on the raw render. For a spread, the spine
    /// region is trimmed off each half first (the binding shadow would bias it).
    nonisolated private static func detectSkews(_ cg: CGImage, splitX: Double, isSpread: Bool) -> (left: Double, right: Double) {
        guard isSpread else { return (DeskewDetector.detect(cg), 0) }
        let leftImg = PDFRenderer.crop(cg, to: CropRect(
            x: 0, y: 0, width: max(0.05, splitX - 0.05), height: 1))
        let rightImg = PDFRenderer.crop(cg, to: CropRect(
            x: min(0.95, splitX + 0.05), y: 0, width: max(0.05, 0.95 - splitX), height: 1))
        let l = leftImg.map { DeskewDetector.detect($0, excludeCenterBand: false) } ?? 0
        let r = rightImg.map { DeskewDetector.detect($0, excludeCenterBand: false) } ?? 0
        return (l, r)
    }

    // MARK: - Analysis

    private struct Analysis {
        let leftSkew: Double
        let rightSkew: Double
        let result: PageAnalyzer.Result
    }

    /// Classify a rendered page (or use `forced`), find its gutter and each side's
    /// skew, then find the crops on the straightened image so they line up.
    nonisolated private static func analyzePage(_ cg: CGImage, deskew: Bool,
                                                as forced: PageClassification? = nil) -> Analysis {
        let r0 = PageAnalyzer.analyze(cgImage: cg, as: forced)
        let spread = r0.classification == .spread
        let skews = deskew ? detectSkews(cg, splitX: r0.splitX, isSpread: spread) : (left: 0.0, right: 0.0)
        let composite = ImageTransform.deskewedComposite(
            cg, splitX: r0.splitX, leftDegrees: skews.left, rightDegrees: skews.right, isSpread: spread)
        let r1 = PageAnalyzer.analyze(cgImage: composite, as: r0.classification)
        return Analysis(leftSkew: skews.left, rightSkew: skews.right, result: r1)
    }

    private func apply(_ a: Analysis, to i: Int) {
        pages[i].leftSkew = a.leftSkew
        pages[i].rightSkew = a.rightSkew
        pages[i].classification = a.result.classification
        pages[i].splitX = a.result.splitX
        pages[i].leftCrop = a.result.leftCrop
        pages[i].rightCrop = a.result.rightCrop
        pages[i].analyzed = true
    }

    /// Analyze every page in the background, filling each in as it finishes.
    func analyzeAll() {
        guard let current = document, let url = sourceURL else { return }
        let todo = pages.filter { !$0.analyzed }.map(\.sourceIndex)
        guard !todo.isEmpty else { return }
        isAnalyzing = true
        let deskew = autoDeskewEnabled
        Task.detached { [previewDPI] in
            // A separate PDFDocument: PDFKit can't draw one document from two threads,
            // and the main thread keeps rendering previews from `document` meanwhile.
            let doc = PDFDocument(url: url)
            for (n, index) in todo.enumerated() {
                // Drain PDFKit's autoreleased drawing objects after every page.
                let analysis = autoreleasepool { () -> Analysis? in
                    guard let pdfPage = doc?.page(at: index),
                          let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { return nil }
                    return Self.analyzePage(cg, deskew: deskew)
                }
                let stillCurrent = await MainActor.run { () -> Bool in
                    // A different PDF was opened meanwhile: drop these results.
                    guard self.document === current else { return false }
                    // Skip pages the user already edited by hand.
                    if let analysis, let i = self.pages.firstIndex(where: { $0.sourceIndex == index }),
                       !self.pages[i].analyzed {
                        self.apply(analysis, to: i)
                    }
                    self.statusText = "Analyzing page \(n + 1) of \(todo.count)…"
                    return true
                }
                if !stillCurrent { return }
            }
            await MainActor.run {
                guard self.document === current else { return }
                self.isAnalyzing = false
                self.statusText = "Ready — \(self.pages.count) source pages → \(self.outputPageCount) output pages."
            }
        }
    }

    /// Re-run auto-detection on one page, optionally forcing its type.
    private func reanalyze(_ idx: Int, as forced: PageClassification? = nil) {
        guard let doc = document, let pdfPage = doc.page(at: pages[idx].sourceIndex),
              let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { return }
        apply(Self.analyzePage(cg, deskew: autoDeskewEnabled, as: forced), to: idx)
    }

    func reanalyzeSelected() {
        guard let idx = selectedIndex else { return }
        perform("Auto-detect") { reanalyze(idx) }
    }

    /// Re-detect only the skew angles for the selected page (keeps current crops).
    func autoStraightenSelected() {
        guard let idx = selectedIndex, let doc = document,
              let pdfPage = doc.page(at: pages[idx].sourceIndex),
              let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { return }
        let s = Self.detectSkews(cg, splitX: pages[idx].splitX, isSpread: pages[idx].isSpread)
        perform("Auto-straighten") {
            pages[idx].leftSkew = s.left
            pages[idx].rightSkew = s.right
        }
    }

    // MARK: - Editing helpers

    /// Copy the selected spread's split and crops to every spread (Briss-style
    /// "apply one common crop"). Its left and right crops are already separate
    /// layouts for the left-hand and right-hand book pages.
    func applyLayoutToAllSpreads() {
        guard let sel = selectedPage, sel.classification == .spread else { return }
        perform("Apply Layout to All Spreads") {
            for i in pages.indices where pages[i].classification == .spread {
                pages[i].splitX = sel.splitX
                pages[i].leftCrop = sel.leftCrop
                pages[i].rightCrop = sel.rightCrop
            }
        }
        statusText = "Applied this spread's layout to every spread."
    }

    /// Copy the selected single page's crop to other single pages. With
    /// `alternate`, only every other single page — counted in order among the
    /// single pages — so left-hand and right-hand book pages keep separate crops.
    func applySingleCrop(alternate: Bool) {
        guard let sel = selectedPage, sel.classification == .single else { return }
        let singles = pages.indices.filter { pages[$0].classification == .single }
        guard let selPos = singles.firstIndex(where: { pages[$0].id == sel.id }) else { return }
        perform(alternate ? "Apply Crop to Alternate Pages" : "Apply Crop to All Single Pages") {
            for (pos, i) in singles.enumerated() where !alternate || pos % 2 == selPos % 2 {
                pages[i].leftCrop = sel.leftCrop
            }
        }
        statusText = alternate
            ? "Applied this crop to every other single page (same side of the book)."
            : "Applied this crop to every single page."
    }

    func setClassification(_ c: PageClassification, for id: BookPage.ID) {
        guard let i = pages.firstIndex(where: { $0.id == id }), pages[i].classification != c else { return }
        let old = pages[i].classification
        perform("Change Page Type") {
            // A Single's one crop covers the whole page while a spread's left crop
            // covers only its left half, so switching between them re-detects the
            // crops. Skipping (or un-skipping) keeps the existing crops.
            if old == .skip || c == .skip {
                pages[i].classification = c
            } else {
                reanalyze(i, as: c)
            }
        }
    }

    func selectAdjacentPage(_ offset: Int) {
        guard !pages.isEmpty else { return }
        let i = max(0, min(pages.count - 1, (selectedIndex ?? 0) + offset))
        selectedPageID = pages[i].id
    }

    // MARK: - Undo

    /// Make a one-step change undoable.
    func perform(_ actionName: String, _ change: () -> Void) {
        let before = pages
        change()
        finishEdit(before: before, actionName: actionName)
    }

    /// Continuous edits (drags, sliders) of the selected page call beginEdit when
    /// they start and endEdit when they finish, so the whole gesture is one undo
    /// step. Only that page is recorded: analysis results for other pages can land
    /// mid-gesture and must not be swept into the undo.
    func beginEdit() {
        guard editSnapshot == nil, let idx = selectedIndex else { return }
        editSnapshot = pages[idx]
        // Claim the page now so analysis still running can't overwrite the gesture.
        pages[idx].analyzed = true
    }

    func endEdit(_ actionName: String) {
        guard let before = editSnapshot else { return }
        editSnapshot = nil
        guard let i = pages.firstIndex(where: { $0.id == before.id }) else { return }
        var after = pages[i]
        after.analyzed = before.analyzed
        guard after != before else { return }
        registerUndo(restoring: [before], actionName: actionName)
    }

    private func finishEdit(before: [BookPage], actionName: String) {
        guard before.count == pages.count else { return }
        let changed = pages.indices.filter { before[$0] != pages[$0] }
        guard !changed.isEmpty else { return }
        // A hand-edited page must not be overwritten by analysis still running.
        for i in changed { pages[i].analyzed = true }
        registerUndo(restoring: changed.map { before[$0] }, actionName: actionName)
    }

    /// Undo puts back only the pages the edit changed, so it never reverts
    /// analysis results that arrived after the edit.
    private func registerUndo(restoring saved: [BookPage], actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = saved.compactMap { p in model.pages.first { $0.id == p.id } }
                for p in saved {
                    if let i = model.pages.firstIndex(where: { $0.id == p.id }) { model.pages[i] = p }
                }
                model.registerUndo(restoring: current, actionName: actionName)  // redo
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Export

    func exportPanel() {
        guard document != nil, !isBusy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "book"
        panel.nameFieldStringValue = "\(base)-cropped.pdf"
        if panel.runModal() == .OK, let url = panel.url {
            export(to: url)
        }
    }

    func export(to url: URL) {
        guard document != nil, let src = sourceURL else { return }
        isExporting = true
        exportProgress = 0
        statusText = "Exporting…"
        let pagesSnapshot = pages
        let settings = PDFExporter.Settings(dpi: exportDPI, direction: direction, ocr: ocrEnabled, enhanceMode: enhanceMode)

        // A GCD thread rather than a Swift task: OCR blocks while it waits for
        // Vision, and that shouldn't tie up Swift's small shared thread pool.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Own PDFDocument, for the same reason as analyzeAll.
                guard let doc = PDFDocument(url: src) else { throw PDFExporter.ExportError.sourceUnreadable }
                let report = try PDFExporter.export(pages: pagesSnapshot,
                                                    from: doc,
                                                    to: url,
                                                    settings: settings) { done, total in
                    Task { @MainActor in
                        guard self.isExporting else { return }   // finished already; keep the final message
                        self.exportProgress = total > 0 ? Double(done) / Double(total) : 0
                        self.statusText = "Exporting page \(done) of \(total)…"
                    }
                }
                Task { @MainActor in
                    self.isExporting = false
                    self.exportProgress = 1
                    self.statusText = Self.exportMessage(url.lastPathComponent, report)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                Task { @MainActor in
                    self.isExporting = false
                    self.statusText = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated private static func exportMessage(_ name: String, _ report: PDFExporter.Report) -> String {
        let failed = report.ocrFailedPages
        guard !failed.isEmpty else { return "Exported \(name)." }
        var list = failed.prefix(10).map(String.init).joined(separator: ", ")
        if failed.count > 10 { list += ", …" }
        return "Exported \(name), but text recognition failed on \(failed.count) of \(report.pageCount) "
            + "pages (\(list)), so those aren't searchable. Exporting again usually fixes it."
    }
}
