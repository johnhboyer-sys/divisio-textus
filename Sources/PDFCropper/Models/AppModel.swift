import Foundation
import PDFKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var document: PDFDocument?
    @Published var sourceURL: URL?
    @Published var pages: [BookPage] = []
    @Published var selectedPageID: BookPage.ID?
    @Published var showsStack = false
    /// The stack on show and each stack's draft crop, kept here so a visit to a
    /// flagged page comes back to the same stack and box.
    @Published var stackKind: PageStack.Kind = .left
    @Published var stackCrops: [PageStack.Kind: CropRect] = [:]
    /// The whole-spread stack's draft split and crops; nil: the stack's usual layout.
    @Published var spreadLayout: SpreadLayout?

    @Published var direction: ReadingDirection = .leftToRight
    /// What auto-detection crops each book page to (see setCropTarget).
    @Published private(set) var cropTarget: CropTarget = .page
    /// The page size typed in for Whole page crops (see setPageSize); nil: measured.
    @Published private(set) var pageSizeOverride: PageSize?
    @Published var exportDPI: Double = 300
    @Published var matchScanResolution = true
    @Published var autoDeskewEnabled = true
    @Published var ocrEnabled = true
    @Published var enhanceMode: EnhanceMode = .color {
        didSet { if enhanceMode != oldValue { clearImageCaches() } }
    }

    @Published var isAnalyzing = false
    @Published var isExporting = false
    @Published var isStraightening = false
    var isBusy: Bool { isAnalyzing || isExporting || isStraightening }
    @Published var statusText = "Open a scanned PDF to begin."
    @Published var exportProgress: Double = 0

    /// Editor magnification; 1 fits the whole page in the window.
    @Published var zoom: Double = 1

    /// The window's undo manager (set by ContentView), so Edit ▸ Undo reverts page edits.
    var undoManager: UndoManager?

    /// Show the exported file in Finder when an export finishes (off in tests).
    var revealExportInFinder = true

    // Preview-image cache keyed by source page index, remembering what the cached
    // composite was built with so any change re-renders. Each entry is a full page
    // at preview DPI, so only the most recently viewed few are kept.
    private struct CachedPreview {
        let left: Double, right: Double, split: Double, isSpread: Bool, dpi: Double
        let image: NSImage
    }
    private var previewCache: [Int: CachedPreview] = [:]
    private var previewOrder: [Int] = []          // least recently used first
    private let previewCacheLimit = 12
    private let previewDPI: Double = 110

    // Stack images keep their geometry so crop edits can reuse the blend.
    private struct CachedStack {
        let geometry: [PageStack.Geometry]
        let image: CGImage
    }
    private var stackCache: [PageStack.Kind: CachedStack] = [:]

    // Thumbnails are small (unstraightened) renders, cheap enough to keep for every page.
    private var thumbnailCache: [Int: NSImage] = [:]
    private var thumbnailOrder: [Int] = []        // least recently used first
    private let thumbnailCacheLimit = 200         // about 130 MB of the largest spreads
    private let thumbnailDPI: Double = 30

    /// The page, and analysis's claim on it, as they were when a drag or slider
    /// edit began (see beginEdit / endEdit).
    private var editSnapshot: (page: BookPage, claim: AnalysisClaim?)?

    // Edits are saved automatically (see ProjectStore) under this PDF's key.
    private var projectKey: String?
    private var autosave: AnyCancellable?
    private let saveQueue = DispatchQueue(label: "Divisio Textus autosave")

    /// Password that unlocked the current PDF, so background copies of it can be
    /// unlocked too. Kept in memory only.
    private var documentPassword: String?

    /// Numbers analysis passes so that a newer pass makes an older one stand down.
    private var analysisRun = 0

    /// Tests only: awaited by an analysis pass once it knows which spreads moved,
    /// before it analyses them again (see splitMoves).
    var beforeReanalysis: (@Sendable () async -> Void)?

    /// Pages whose crops analysis set and nobody has edited since, with what it
    /// found on them. Saved with the edits.
    private var setByAnalysis: [BookPage.ID: AnalysisClaim] = [:]

    /// Set while an export runs; cancelExport() trips it.
    private var exportCancel: CancelFlag?

    init() {
        // Save a moment after the last change, and immediately on quit.
        autosave = Publishers.CombineLatest3($pages, $direction, $pageSizeOverride)
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] pages, direction, _ in self?.saveEdits(pages, direction, wait: false) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveEdits(self.pages, self.direction, wait: true)
            }
        }
    }

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

    /// Export is possible: a PDF is open, nothing else is running, and at least
    /// one page isn't skipped.
    var canExport: Bool { document != nil && !isBusy && outputPageCount > 0 }

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
        guard doc.pageCount > 0 else {
            statusText = "\(url.lastPathComponent) has no pages."
            return
        }
        // Encrypted scans often have an empty open password (they only restrict
        // printing or copying); otherwise ask for it.
        var password: String?
        if doc.isLocked && !doc.unlock(withPassword: "") {
            guard let entered = askPassword(for: url, document: doc) else {
                statusText = "\(url.lastPathComponent) is password-protected and wasn't opened."
                return
            }
            password = entered
        }
        // Save the outgoing PDF's edits now, and wait for it and any save still
        // queued: a pending autosave would otherwise be replaced by the new PDF's
        // pages before it fired, and reopening the same PDF would read the older
        // record.
        saveEdits(pages, direction, wait: true)
        clearImageCaches()
        undoManager?.removeAllActions()
        editSnapshot = nil
        stackKind = .left
        stackCrops = [:]
        spreadLayout = nil
        document = doc
        sourceURL = url
        documentPassword = password
        isAnalyzing = false   // any analysis of the previous PDF is abandoned
        isStraightening = false
        projectKey = ProjectStore.key(for: url)
        // Saves made before keys hashed the whole file are found by the old key,
        // and from then on saved under the new one.
        let restored = projectKey.flatMap(ProjectStore.load) ?? ProjectStore.legacyKey(for: url).flatMap(ProjectStore.load)
        if let saved = restored, saved.pages.map(\.sourceIndex) == Array(0..<doc.pageCount) {
            pages = saved.pages
            direction = saved.direction
            cropTarget = saved.cropTarget ?? .text   // what these edits were made with; a new PDF keeps the current choice
            pageSizeOverride = saved.pageSize
            setByAnalysis = saved.claims ?? [:]
            statusText = "Restored your earlier edits — \(pages.count) source pages → \(outputPageCount) output pages."
        } else {
            pages = (0..<doc.pageCount).map { BookPage(sourceIndex: $0) }
            pageSizeOverride = nil
            setByAnalysis = [:]
            statusText = "Loaded \(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s"). Analyzing…"
        }
        selectedPageID = pages.first?.id
        analyzeAll()
    }

    /// Ask for the password of a protected PDF until it unlocks or the user cancels.
    private func askPassword(for url: URL, document: PDFDocument) -> String? {
        var message = "“\(url.lastPathComponent)” is protected. Enter its password to open it."
        while true {
            let alert = NSAlert()
            alert.messageText = "Password Required"
            alert.informativeText = message
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if document.unlock(withPassword: field.stringValue) { return field.stringValue }
            message = "That password didn't work. Try again."
        }
    }

    /// Open another copy of the PDF for a background job, unlocked like the original.
    nonisolated static func reopen(_ url: URL, password: String?) -> PDFDocument? {
        guard let doc = PDFDocument(url: url) else { return nil }
        if doc.isLocked { _ = doc.unlock(withPassword: password ?? "") }
        return doc.isLocked ? nil : doc
    }

    // MARK: - Previews

    /// The straightened page as the editor shows it. `zoom` picks the detail:
    /// zoomed in, the page renders at 2× or 3× the normal preview resolution so
    /// crop edges can be placed precisely.
    func previewImage(for page: BookPage, zoom: Double = 1) -> NSImage? {
        let dpi = previewDPI * (zoom >= 2.5 ? 3 : zoom >= 1.5 ? 2 : 1)
        // With both sides straight the split line doesn't change the image, so
        // dragging it needn't re-render.
        let straight = abs(page.leftSkew) < 0.01 && abs(page.rightSkew) < 0.01
        if let c = previewCache[page.sourceIndex],
           c.left == page.leftSkew, c.right == page.rightSkew,
           c.split == page.splitX || straight, c.isSpread == page.isSpread, c.dpi == dpi {
            touchPreview(page.sourceIndex)
            return c.image
        }
        guard let doc = document, let pdfPage = doc.page(at: page.sourceIndex),
              let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi) else { return nil }
        let composite = ImageTransform.deskewedComposite(
            cg, splitX: page.splitX,
            leftDegrees: page.leftSkew, rightDegrees: page.rightSkew,
            isSpread: page.isSpread)
        let enhanced = ImageEnhancer.apply(composite, mode: enhanceMode)
        let img = NSImage(cgImage: enhanced, size: NSSize(width: enhanced.width, height: enhanced.height))
        previewCache[page.sourceIndex] = CachedPreview(
            left: page.leftSkew, right: page.rightSkew, split: page.splitX,
            isSpread: page.isSpread, dpi: dpi, image: img)
        touchPreview(page.sourceIndex)
        return img
    }

    /// Background jobs own their PDFDocument and discard results for an old PDF.
    func stackImage(for stack: PageStack, refresh: Bool = false) async -> CGImage? {
        if !refresh, let cached = stackCache[stack.id], cached.geometry == stack.geometry {
            return cached.image
        }
        guard let current = document, let url = sourceURL else { return nil }
        let password = documentPassword
        // The renderer's worker threads aren't tasks, so cancellation reaches them as a flag.
        let cancel = CancelFlag()
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        let job = Task.detached { () -> CGImage? in
            StackRenderer.render(stack, workers: workers, open: { Self.reopen(url, password: password) },
                                 isCancelled: { cancel.isSet })
        }
        let image = await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            cancel.set()
        }
        guard !Task.isCancelled, document === current,
              PageStack.all(pages: pages).first(where: { $0.id == stack.id })?.geometry == stack.geometry,
              let image else { return nil }
        stackCache[stack.id] = CachedStack(geometry: stack.geometry, image: image)
        return image
    }

    func thumbnail(for page: BookPage) -> NSImage? {
        if let t = thumbnailCache[page.sourceIndex] {
            thumbnailOrder.removeAll { $0 == page.sourceIndex }
            thumbnailOrder.append(page.sourceIndex)
            return t
        }
        guard let doc = document, let pdfPage = doc.page(at: page.sourceIndex),
              let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: thumbnailDPI) else { return nil }
        let enhanced = ImageEnhancer.apply(cg, mode: enhanceMode)
        let img = NSImage(cgImage: enhanced, size: NSSize(width: enhanced.width, height: enhanced.height))
        thumbnailCache[page.sourceIndex] = img
        thumbnailOrder.append(page.sourceIndex)
        while thumbnailOrder.count > thumbnailCacheLimit { thumbnailCache[thumbnailOrder.removeFirst()] = nil }
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
        thumbnailOrder.removeAll()
        stackCache.removeAll()
    }

    /// Detect skew for each book page on the raw render, measured inside that
    /// page's own content (with a little room around it), so scanner bands, the
    /// binding shadow and the facing page can't pull the angle.
    nonisolated static func detectSkews(_ cg: CGImage, splitX: Double, isSpread: Bool) -> (left: Double, right: Double) {
        guard let g = GrayBuffer(cgImage: cg) else { return (0, 0) }
        func skew(_ side: Range<Double>) -> Double {
            let found = PageAnalyzer.contentBounds(g, xRange: side)
            guard !found.blank else { return 0 }
            let room = 0.02, c = found.crop
            let x0 = max(side.lowerBound, c.minX - room), x1 = min(side.upperBound, c.maxX + room)
            let y0 = max(0, c.minY - room), y1 = min(1, c.maxY + room)
            guard let content = PDFRenderer.crop(cg, to: CropRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            else { return 0 }
            return DeskewDetector.detect(content, excludeCenterBand: false)
        }
        return isSpread ? (skew(0..<splitX), skew(splitX..<1)) : (skew(0..<1), 0)
    }

    // MARK: - Analysis

    struct Analysis {
        let leftSkew: Double
        let rightSkew: Double
        let result: PageAnalyzer.Result
    }

    /// Classify a rendered page (or use `forced`), find its gutter and each side's
    /// skew, then find the crops on the straightened image so they line up.
    /// `split` keeps a spread's gutter where it is given instead of finding it.
    nonisolated static func analyzePage(_ cg: CGImage, deskew: Bool, as forced: PageClassification? = nil,
                                        target: CropTarget = .text, split: Double? = nil) -> Analysis {
        let r0 = PageAnalyzer.analyze(cgImage: cg, as: forced, split: split)
        let spread = r0.classification == .spread
        let skews = deskew ? detectSkews(cg, splitX: r0.splitX, isSpread: spread) : (left: 0.0, right: 0.0)
        let composite = ImageTransform.deskewedComposite(
            cg, splitX: r0.splitX, leftDegrees: skews.left, rightDegrees: skews.right, isSpread: spread)
        // Keep the gutter found on the scan: the straightened image is cut there,
        // and turning each half tilts a binding shadow so it can't be found again.
        let r1 = PageAnalyzer.analyze(cgImage: composite, as: r0.classification, split: r0.splitX,
                                      target: target, turns: skews)
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
        analysisRun += 1
        let run = analysisRun
        // This pass's pages, whose claims it replaces; older claims stay.
        let passIDs = Set(pages.filter { !$0.analyzed }.map(\.id))
        for id in passIDs { setByAnalysis[id] = nil }
        isAnalyzing = true
        let deskew = autoDeskewEnabled, target = cropTarget
        let password = documentPassword
        Task.detached { [previewDPI] in
            // A separate PDFDocument: PDFKit can't draw one document from two threads,
            // and the main thread keeps rendering previews from `document` meanwhile.
            let doc = Self.reopen(url, password: password)
            for (n, index) in todo.enumerated() {
                // Drain PDFKit's autoreleased drawing objects after every page.
                let analysis = autoreleasepool { () -> Analysis? in
                    guard let pdfPage = doc?.page(at: index),
                          let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { return nil }
                    return Self.analyzePage(cg, deskew: deskew, target: target)
                }
                let stillCurrent = await MainActor.run { () -> Bool in
                    // A different PDF was opened, or a newer pass started: stand down.
                    guard self.document === current, self.analysisRun == run else { return false }
                    // Skip pages the user already edited by hand.
                    if let analysis, let i = self.pages.firstIndex(where: { $0.sourceIndex == index }),
                       !self.pages[i].analyzed {
                        self.apply(analysis, to: i)
                        self.setByAnalysis[self.pages[i].id] = AnalysisClaim(analysis.result)
                    }
                    self.statusText = "Analyzing page \(n + 1) of \(todo.count)…"
                    return true
                }
                if !stillCurrent { return }
            }
            // Spreads whose split must move (see splitMoves) are
            // analysed again at the new split: each half's angle and text depend
            // on where the halves meet.
            // The pages as this last phase starts: it changes only pages still so.
            let (moves, start) = await MainActor.run { () -> ([(id: BookPage.ID, index: Int, split: Double)], [BookPage]) in
                guard self.document === current, self.analysisRun == run else { return ([], []) }
                return (self.splitMoves(self.setByAnalysis.filter { passIDs.contains($0.key) }), self.pages)
            }
            if let hook = await MainActor.run(body: { self.beforeReanalysis }) { await hook() }
            var redone: [BookPage.ID: Analysis] = [:]
            for move in moves {
                autoreleasepool {
                    guard let pdfPage = doc?.page(at: move.index),
                          let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { return }
                    redone[move.id] = Self.analyzePage(cg, deskew: deskew, as: .spread, target: target, split: move.split)
                }
            }
            let results = redone
            await MainActor.run {
                guard self.document === current, self.analysisRun == run else { return }
                // A switch of crop target undone meanwhile: these results are for
                // the other one, and the pages are back as they were. Drop them.
                guard self.cropTarget == target else {
                    self.isAnalyzing = false
                    self.statusText = "Ready — \(self.pages.count) source pages → \(self.outputPageCount) output pages."
                    return
                }
                // Pages edited or undone meanwhile keep what they are now.
                let now = self.pages, claims = self.setByAnalysis
                let changed = Set(zip(now, start).filter { $0.0 != $0.1 }.map(\.0.id))
                for (id, analysis) in results where !changed.contains(id) {
                    guard self.setByAnalysis[id] != nil, let i = self.pages.firstIndex(where: { $0.id == id }) else { continue }
                    self.apply(analysis, to: i)
                    self.setByAnalysis[id] = AnalysisClaim(analysis.result)
                }
                // The book's usual crops are taken as the pass found them, so pages
                // whose split stayed put get exactly what they got before.
                self.evenOutNearlyEmptyPages(self.setByAnalysis.filter { passIDs.contains($0.key) }, usualFrom: now)
                self.placeSheets()
                for (i, page) in now.enumerated() where changed.contains(page.id) {
                    self.pages[i] = page
                    self.setByAnalysis[page.id] = claims[page.id]
                }
                self.isAnalyzing = false
                self.statusText = "Ready — \(self.pages.count) source pages → \(self.outputPageCount) output pages."
            }
        }
    }

    /// A blank page next to the gutter leaves no white gap to find the split by.
    /// The spreads in `sides` (what an analysis pass just set, with which of
    /// their sides it found blank) whose split lies far from the book's usual
    /// one beside a blank page get the usual split instead; they must then be
    /// analysed again there (each half's angle and text depend on it). A book's
    /// gutter can genuinely move from spread to spread, so only those.
    private func splitMoves(_ sides: [BookPage.ID: AnalysisClaim]) -> [(id: BookPage.ID, index: Int, split: Double)] {
        let spreads = pages.indices.filter { pages[$0].classification == .spread }
        guard spreads.count >= 3 else { return [] }
        let usualSplit = spreads.map { pages[$0].splitX }.sorted()[spreads.count / 2]
        return spreads.compactMap { i in
            guard let found = sides[pages[i].id], abs(pages[i].splitX - usualSplit) > 0.06,
                  found.leftBlank || found.rightBlank else { return nil }
            return (pages[i].id, pages[i].sourceIndex, usualSplit)
        }
    }

    /// Nearly empty pages (a part title, a chapter's last few lines) get crops far
    /// smaller than the rest of the book and would export as odd little pages.
    /// Give those the book's usual crop instead, keeping what was found and each
    /// crop on its own side of the split. Only the pages in `sides` (what an
    /// analysis pass just set, with which of their sides it found blank) are
    /// changed, never anything edited by hand. Whole-page crops are the paper,
    /// found whether or not anything is printed on it, and are left alone.
    /// `usualFrom`: the pages the book's usual crops are taken from (default: as they are).
    private func evenOutNearlyEmptyPages(_ sides: [BookPage.ID: AnalysisClaim], usualFrom basis: [BookPage]? = nil) {
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        func usual(_ crops: [CropRect]) -> CropRect? {
            guard crops.count >= 3 else { return nil }
            return CropRect(x: median(crops.map(\.x)), y: median(crops.map(\.y)),
                            width: median(crops.map(\.width)), height: median(crops.map(\.height)))
        }
        func tooSmall(_ crop: CropRect, _ usual: CropRect) -> Bool {
            crop.width < 0.6 * usual.width || crop.height < 0.6 * usual.height
        }
        guard cropTarget == .text else { return }
        let spreads = pages.indices.filter { pages[$0].classification == .spread }
        let singles = pages.indices.filter { pages[$0].classification == .single }
        let candidates = { (indices: [Int]) in indices.filter { sides[self.pages[$0].id] != nil } }
        func blank(_ i: Int, left: Bool) -> Bool {
            guard let found = sides[pages[i].id] else { return false }
            return left ? found.leftBlank : found.rightBlank
        }
        let basis = basis ?? pages
        let basisSpreads = basis.filter { $0.classification == .spread }
        if let u = usual(basisSpreads.map(\.leftCrop)) {
            for i in candidates(spreads) where tooSmall(pages[i].leftCrop, u) || blank(i, left: true) {
                var c = blank(i, left: true) ? u : u.union(pages[i].leftCrop)   // keep what was found
                c.width = min(c.width, pages[i].splitX - c.x)           // stay left of the split
                c.normalize()
                pages[i].leftCrop = c
            }
        }
        if let u = usual(basisSpreads.map(\.rightCrop)) {
            for i in candidates(spreads) where tooSmall(pages[i].rightCrop, u) || blank(i, left: false) {
                var c = blank(i, left: false) ? u : u.union(pages[i].rightCrop)
                if c.x < pages[i].splitX {                               // stay right of the split
                    c.width -= pages[i].splitX - c.x
                    c.x = pages[i].splitX
                }
                c.normalize()
                pages[i].rightCrop = c
            }
        }
        if let u = usual(basis.filter { $0.classification == .single }.map(\.leftCrop)) {
            for i in candidates(singles) where tooSmall(pages[i].leftCrop, u) || blank(i, left: true) {
                pages[i].leftCrop = blank(i, left: true) ? u : u.union(pages[i].leftCrop)
            }
        }
    }

    /// Re-run auto-detection on one page, optionally forcing its type.
    private func reanalyze(_ idx: Int, as forced: PageClassification? = nil) {
        guard let doc = document, let pdfPage = doc.page(at: pages[idx].sourceIndex),
              let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { return }
        var analysis = Self.analyzePage(cg, deskew: autoDeskewEnabled, as: forced, target: cropTarget)
        apply(analysis, to: idx)
        // The same book-wide treatment the full pass gives a blank or nearly
        // empty page, so re-detecting one page gives what opening the book gave:
        // a split that must move, then analysis again at the new one.
        let id = pages[idx].id
        var claim = AnalysisClaim(analysis.result)
        let found = pages
        if let move = splitMoves([id: claim]).first {
            analysis = Self.analyzePage(cg, deskew: autoDeskewEnabled, as: .spread, target: cropTarget, split: move.split)
            apply(analysis, to: idx)
            claim = AnalysisClaim(analysis.result)
        }
        // And the book's page size, as measured on the other pages. (The edit
        // that called this then counts the page as edited by hand.)
        if cropTarget == .page { setByAnalysis[id] = claim }
        evenOutNearlyEmptyPages([id: claim], usualFrom: found)
        if cropTarget == .page { placeSheets(only: [id]) }
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

    /// "Auto-straighten" for every page: re-detect the skew angles, keep the crops,
    /// as one undoable step. Skipped pages are left alone. Runs off the main thread
    /// with its own PDFDocument, like analysis.
    func autoStraightenAllPages() async {
        guard let current = document, let url = sourceURL, !isBusy else { return }
        let todo = pages.filter { $0.classification != .skip }
        guard !todo.isEmpty else { return }
        isStraightening = true
        statusText = "Straightening \(todo.count) pages…"
        let password = documentPassword
        let found = await Task.detached { [previewDPI] () -> [BookPage.ID: (left: Double, right: Double)] in
            guard let doc = Self.reopen(url, password: password) else { return [:] }
            var found: [BookPage.ID: (left: Double, right: Double)] = [:]
            for (n, page) in todo.enumerated() {
                autoreleasepool {
                    guard let pdfPage = doc.page(at: page.sourceIndex),
                          let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { return }
                    found[page.id] = Self.detectSkews(cg, splitX: page.splitX, isSpread: page.isSpread)
                }
                // Another PDF opened meanwhile: stop rather than go on rendering the old one.
                let stillCurrent = await MainActor.run { () -> Bool in
                    guard self.document === current else { return false }
                    if n % 10 == 9 { self.statusText = "Straightening page \(n + 1) of \(todo.count)…" }
                    return true
                }
                if !stillCurrent { return [:] }
            }
            return found
        }.value
        guard document === current else { return }   // another PDF was opened meanwhile
        isStraightening = false
        // A page edited meanwhile keeps the edit, and one waiting for analysis is
        // left to it: the angles were found for the page as it was.
        let asWas = Dictionary(uniqueKeysWithValues: todo.map { ($0.id, $0) })
        var count = 0
        perform("Auto-straighten All Pages") {
            for i in pages.indices {
                guard let s = found[pages[i].id], pages[i] == asWas[pages[i].id] else { continue }
                pages[i].leftSkew = s.left
                pages[i].rightSkew = s.right
                count += 1
            }
        }
        statusText = "Straightened \(count) page\(count == 1 ? "" : "s")."
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

    func applyStackCrop(_ crop: CropRect, to members: [PageStack.Member], in stack: PageStack) {
        var count = 0
        perform("Apply Crop to Stack") {
            for member in members {
                guard let i = pages.firstIndex(where: { $0.id == member.id }),
                      pages[i].classification == member.page.classification else { continue }
                let live = PageStack.Member(page: pages[i], side: member.side)
                let c = live.clampedCrop(crop, usualWidth: stack.usualRegionWidth)
                if member.side == .right { pages[i].rightCrop = c }
                else { pages[i].leftCrop = c }
                count += 1
            }
        }
        statusText = "Applied this crop to \(count) pages in the stack."
    }

    /// The whole-spread stack's Apply: the layout's split and crops, each crop kept
    /// on its own side of the split, on each spread given. The angles stay, as when
    /// the split is dragged in Page view.
    func applySpreadLayout(_ layout: SpreadLayout, to members: [PageStack.Member]) {
        let l = layout.clamped
        var count = 0
        perform("Apply Layout to Spreads") {
            for member in members {
                guard let i = pages.firstIndex(where: { $0.id == member.id }),
                      pages[i].classification == .spread else { continue }
                pages[i].splitX = l.splitX
                pages[i].leftCrop = l.leftCrop
                pages[i].rightCrop = l.rightCrop
                count += 1
            }
        }
        statusText = "Applied this layout to \(count) spread\(count == 1 ? "" : "s")."
    }

    func setClassification(_ c: PageClassification, for id: BookPage.ID) {
        guard let i = pages.firstIndex(where: { $0.id == id }), pages[i].classification != c else { return }
        let old = pages[i].classification
        perform("Change Page Type") {
            // A Single's one crop covers the whole page while a spread's left crop
            // covers only its left half, so switching between them re-detects the
            // crops. Skipping keeps the existing crops, and un-skipping to the type
            // they were made for keeps them too; to another type, it re-detects.
            if c == .skip {
                pages[i].typeBeforeSkip = old
                pages[i].classification = .skip
            } else if old == .skip, pages[i].typeBeforeSkip.map({ $0 == c }) ?? true {
                pages[i].classification = c
                pages[i].typeBeforeSkip = nil
            } else {
                reanalyze(i, as: c)
                pages[i].typeBeforeSkip = nil
            }
        }
    }

    /// Throw away every edit and auto-detect all pages again (undoable).
    func autoDetectAllPages() {
        guard document != nil, !isBusy else { return }
        redetectAllPages()
    }

    /// Undo puts back the pages and their analysis claims as they were,
    /// stopping the pass. Redo detects every page afresh, so it never brings
    /// back a pass left half done.
    private func redetectAllPages() {
        let before = pages, claims = setByAnalysis
        for i in pages.indices { pages[i].analyzed = false }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.analysisRun += 1            // the pass stands down
                model.isAnalyzing = false
                for p in before {
                    if let i = model.pages.firstIndex(where: { $0.id == p.id }) { model.pages[i] = p }
                }
                model.setByAnalysis = claims
                model.undoManager?.registerUndo(withTarget: model) { model in
                    MainActor.assumeIsolated { model.redetectAllPages() }   // redo
                }
                model.undoManager?.setActionName("Auto-detect All Pages")
            }
        }
        undoManager?.setActionName("Auto-detect All Pages")
        analyzeAll()
    }

    /// Crop every page to its text block or to the whole page: switching
    /// re-detects all pages, and undo puts back both the pages and the choice.
    func setCropTarget(_ target: CropTarget) {
        guard target != cropTarget, !isBusy else { return }
        guard document != nil else { cropTarget = target; return }
        switchCropTarget(to: target)
    }

    /// Undo puts back the pages, their analysis claims and the target as they
    /// were (a complete state), stopping any pass the switch started. Redo
    /// switches again, detecting every page afresh, so it never brings back a
    /// pass left half done.
    private func switchCropTarget(to target: CropTarget) {
        let before = pages, old = cropTarget, claims = setByAnalysis
        cropTarget = target
        for i in pages.indices { pages[i].analyzed = false }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.analysisRun += 1            // a pass for the switched target stands down
                model.isAnalyzing = false
                model.cropTarget = old
                for p in before {
                    if let i = model.pages.firstIndex(where: { $0.id == p.id }) { model.pages[i] = p }
                }
                model.setByAnalysis = claims
                model.undoManager?.registerUndo(withTarget: model) { model in
                    MainActor.assumeIsolated { model.switchCropTarget(to: target) }   // redo
                }
                model.undoManager?.setActionName("Crop to \(target.label)")
            }
        }
        undoManager?.setActionName("Crop to \(target.label)")
        analyzeAll()
    }

    // MARK: - Page size (Whole page)

    /// What the inspector shows of the book's page size. Widths and heights are
    /// what was measured (nil: not measured); `measured` of `total` pages gave a
    /// measurement. `disagreement` names stacks whose sizes differ by over 2%.
    struct PageSizeSummary: Equatable {
        var width: Double?
        var height: Double?
        var override: PageSize?
        var measured: Int
        var total: Int
        var disagreement: String?
        /// Each stack's own measurement, for a tooltip.
        var details: [String] = []
    }

    /// nil outside Whole page mode.
    var pageSize: PageSizeSummary? {
        guard cropTarget == .page, document != nil else { return nil }
        let plans = sheetPlans()
        func pooled(_ axis: (SheetPlan) -> [Double], _ measured: (SheetPlan) -> Bool) -> Double? {
            let samples = plans.values.filter(measured).flatMap(axis)
            return samples.isEmpty ? nil : PageStack.median(samples)
        }
        var summary = PageSizeSummary(width: pooled(\.widths, \.widthMeasured), height: pooled(\.heights, \.heightMeasured),
                                      override: pageSizeOverride,
                                      measured: plans.values.reduce(0) { $0 + $1.measuredSides },
                                      total: plans.values.reduce(0) { $0 + $1.sides.count })
        func inches(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
        summary.details = plans.sorted { $0.key.rawValue < $1.key.rawValue }.map { kind, plan in
            "\(kind.label): \(inches(plan.width)) × \(inches(plan.height)) in, widths on \(plan.widths.count), "
                + "heights on \(plan.heights.count) of \(plan.sides.count) pages"
        }
        let own = plans.filter { $0.value.ownSize }
        if !own.isEmpty {
            summary.disagreement = own.sorted { $0.key.rawValue < $1.key.rawValue }.map { kind, plan in
                "\(kind.label): \(inches(plan.width)) × \(inches(plan.height)) in"
            }.joined(separator: "; ")
        }
        return summary
    }

    /// Set the book's page size by hand (nil: back to the measured size). Pages
    /// analysis set get the new size; pages edited by hand keep theirs. One undo step.
    func setPageSize(_ size: PageSize?) {
        guard size != pageSizeOverride, !isBusy, size?.isSensible ?? true else { return }
        let before = pages, old = pageSizeOverride
        pageSizeOverride = size
        placeSheets()
        let changed = pages.indices.filter { before[$0] != pages[$0] }.map { before[$0] }
        registerPageSizeUndo(restoring: changed, size: old)
    }

    /// Undo for setPageSize: puts back the size and the pages, which stay analysis's.
    private func registerPageSizeUndo(restoring saved: [BookPage], size: PageSize?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = saved.compactMap { p in model.pages.first { $0.id == p.id } }
                let currentSize = model.pageSizeOverride
                model.pageSizeOverride = size
                for p in saved {
                    if let i = model.pages.firstIndex(where: { $0.id == p.id }) { model.pages[i] = p }
                }
                model.registerPageSizeUndo(restoring: current, size: currentSize)   // redo
            }
        }
        undoManager.setActionName("Set Page Size")
    }

    /// One book page (a side of a spread, or a single page) as the page size sees it.
    private struct SheetSide {
        let member: PageStack.Member
        let claim: AnalysisClaim
        let inches: CGSize               // the page's displayed size
        var isLeft: Bool { member.side != .right }
        var sheet: PageAnalyzer.Sheet? { isLeft ? claim.leftSheet : claim.rightSheet }
        var found: CropRect? { isLeft ? claim.leftFound : claim.rightFound }
        var text: CropRect? { sheet?.text }
        var split: Double { member.page.splitX }
    }

    /// A stack's page size, margins and usual place, in inches.
    private struct SheetPlan {
        var sides: [SheetSide] = []
        var widths: [Double] = [], heights: [Double] = []
        var marginLeft: [Double] = [], marginRight: [Double] = [], marginTop: [Double] = [], marginBottom: [Double] = []
        var measuredSides = 0
        var width: Double?, height: Double?              // measured
        var ownSize = false                              // differs from the other stacks
        var widthMeasured: Bool { width != nil }
        var heightMeasured: Bool { height != nil }
    }

    /// Measure each stack's sheets: the width edge to edge (for spreads, half the
    /// spread's, on those with both outer edges trusted), the
    /// height edge to edge, and the margins from each trusted edge to the text. A
    /// size counts as measured on at least max(5, 20% of the stack) pages. Stacks
    /// that agree within 2% share their sizes, so the book has one.
    private func sheetPlans() -> [PageStack.Kind: SheetPlan] {
        guard let doc = document else { return [:] }
        var plans: [PageStack.Kind: SheetPlan] = [:]
        for stack in PageStack.groups(pages: pages) {
            var plan = SheetPlan()
            for member in stack.members {
                guard let claim = setByAnalysis[member.id], let page = doc.page(at: member.page.sourceIndex) else { continue }
                let size = PDFRenderer.displaySize(of: page)
                let side = SheetSide(member: member, claim: claim, inches: CGSize(width: size.width / 72, height: size.height / 72))
                plan.sides.append(side)
                guard let s = side.sheet, let t = s.text else { continue }
                let w = side.inches.width, h = side.inches.height
                var gave = false
                switch member.side {
                case .left, .right:
                    // Half the spread's width, outer edge to outer edge: the fold
                    // needn't lie where the split was put.
                    if let a = claim.leftSheet?.minX, let b = claim.rightSheet?.maxX { plan.widths.append((b - a) / 2 * w); gave = true }
                    if member.side == .left, let a = s.minX { plan.marginLeft.append((t.minX - a) * w) }
                    if member.side == .right, let b = s.maxX { plan.marginRight.append((b - t.maxX) * w) }
                case .single, .whole:
                    if let a = s.minX { plan.marginLeft.append((t.minX - a) * w) }
                    if let b = s.maxX { plan.marginRight.append((b - t.maxX) * w) }
                    if let a = s.minX, let b = s.maxX { plan.widths.append((b - a) * w); gave = true }
                }
                if let a = s.minY { plan.marginTop.append((t.minY - a) * h) }
                if let b = s.maxY { plan.marginBottom.append((b - t.maxY) * h) }
                if let a = s.minY, let b = s.maxY { plan.heights.append((b - a) * h); gave = true }
                if gave { plan.measuredSides += 1 }
            }
            let needed = max(5, Int((0.2 * Double(plan.sides.count)).rounded(.up)))
            if plan.widths.count >= needed { plan.width = PageStack.median(plan.widths) }
            if plan.heights.count >= needed { plan.height = PageStack.median(plan.heights) }
            if plan.width == nil && plan.height == nil { plan.measuredSides = 0 }
            plans[stack.id] = plan
        }
        // One size for the book where the stacks agree.
        for axis in [\SheetPlan.width, \SheetPlan.height] {
            let samples = axis == \SheetPlan.width ? \SheetPlan.widths : \SheetPlan.heights
            let measured = plans.filter { $0.value[keyPath: axis] != nil }
            let sizes = measured.values.compactMap { $0[keyPath: axis] }
            guard let lo = sizes.min(), let hi = sizes.max() else { continue }
            if hi <= lo * 1.02 {
                let pooled = PageStack.median(measured.values.flatMap { $0[keyPath: samples] })
                for kind in measured.keys { plans[kind]![keyPath: axis] = pooled }
            } else {
                for kind in measured.keys { plans[kind]!.ownSize = true }
            }
        }
        return plans
    }

    /// Whole page: put a box of the book's page size on each page analysis set
    /// (or only those in `only`), where its sheet is, and crop to that box (within
    /// the paper analysis found, or at a spread's gutter its half) and the text
    /// block, so print is never cut. An axis with no
    /// size (not measured, none typed in) keeps the crop analysis found.
    private func placeSheets(only: Set<BookPage.ID>? = nil) {
        guard cropTarget == .page else { return }
        // What analysis found is kept, so a new size always starts from it. (Only
        // for the pages placed now: others may still await the book-wide steps.)
        for i in pages.indices where only?.contains(pages[i].id) ?? true {
            guard var claim = setByAnalysis[pages[i].id], claim.leftFound == nil else { continue }
            claim.leftFound = pages[i].leftCrop
            claim.rightFound = pages[i].rightCrop
            setByAnalysis[pages[i].id] = claim
        }
        for (_, plan) in sheetPlans() {
            // An axis without a size gets what analysis found, so a size cleared
            // or never measured leaves nothing of an earlier one behind.
            let W = pageSizeOverride?.width ?? plan.width, H = pageSizeOverride?.height ?? plan.height
            let horizontal = W.map { axis(plan, size: $0, vertical: false) }
            let vertical = H.map { axis(plan, size: $0, vertical: true) }
            for side in plan.sides where only?.contains(side.member.id) ?? true {
                guard let i = pages.firstIndex(where: { $0.id == side.member.id }), var crop = side.found else { continue }
                // The box, on the paper analysis found and inside the sheet's
                // trusted edges (a box overhanging them would take in scanner
                // background or the neighbouring leaves; at a spread's gutter,
                // its half instead), and the text block, so
                // print is never cut.
                // All of it inside the page's half: the text was found before
                // analysis may have moved the split (see evenOutNearlyEmptyPages).
                func span(_ box: (Double, Double), _ paper: (Double, Double), _ text: (Double, Double)?,
                          within region: (Double, Double)) -> (Double, Double) {
                    // Slid onto the paper, if it fits there; cut to it, if not.
                    let length = box.1 - box.0
                    var a = max(paper.0, min(box.0, paper.1 - length)), b = min(paper.1, a + length)
                    if let text { a = min(a, text.0); b = max(b, text.1) }
                    a = max(a, region.0); b = min(b, region.1)
                    return (a, max(a, b))
                }
                let region = (side.member.regionMinX, side.member.regionMinX + side.member.regionWidth)
                if let horizontal, let W, let x = horizontal(side) {
                    let w = side.inches.width
                    var paper = (max(crop.minX, side.sheet?.minX ?? 0), min(crop.maxX, side.sheet?.maxX ?? 1))
                    // A spread's page runs on into the fold: an edge found at its
                    // gutter (the paper's or the sheet's) is where the binding's
                    // shade, a crease or the fold's dark line begins. Its half ends it.
                    if side.member.side == .left { paper.1 = region.1 }
                    if side.member.side == .right { paper.0 = region.0 }
                    let s = span((x / w, (x + W) / w), paper, side.text.map { ($0.minX, $0.maxX) }, within: region)
                    crop.x = s.0; crop.width = s.1 - s.0
                }
                if let vertical, let H, let y = vertical(side) {
                    let h = side.inches.height
                    let paper = (max(crop.minY, side.sheet?.minY ?? 0), min(crop.maxY, side.sheet?.maxY ?? 1))
                    let s = span((y / h, (y + H) / h), paper, side.text.map { ($0.minY, $0.maxY) }, within: (0, 1))
                    crop.y = s.0; crop.height = s.1 - s.0
                }
                if side.isLeft { pages[i].leftCrop = crop } else { pages[i].rightCrop = crop }
            }
        }
    }

    /// Where a box `size` inches long starts on each side, along one axis, in
    /// inches from the page's left or top (nil: leave the side's crop alone).
    /// A spread's box runs from its outer edge, if trusted, else that far out
    /// from the text as the usual outer margin, else from the split. Otherwise it
    /// sits on the sheet's trusted edges; failing those, it is set off the text by the usual margins,
    /// from the text's start or its end, whichever puts it nearer the stack's
    /// usual place: a chapter's opening page starts low, its last page stops short.
    private func axis(_ plan: SheetPlan, size S: Double, vertical: Bool) -> (SheetSide) -> Double? {
        func length(_ side: SheetSide) -> Double { vertical ? side.inches.height : side.inches.width }
        func edges(_ side: SheetSide) -> (Double?, Double?) {
            let s = side.sheet, n = length(side)
            return vertical ? (s?.minY.map { $0 * n }, s?.maxY.map { $0 * n }) : (s?.minX.map { $0 * n }, s?.maxX.map { $0 * n })
        }
        func text(_ side: SheetSide) -> (Double, Double)? {
            guard let t = side.text else { return nil }
            let n = length(side)
            return vertical ? (t.minY * n, t.maxY * n) : (t.minX * n, t.maxX * n)
        }
        // Margins: measured where at least three pages show them; else what the
        // usual text block leaves, split evenly.
        let extents = plan.sides.compactMap(text).map { $0.1 - $0.0 }
        let usualText = extents.isEmpty ? S : PageStack.median(extents)
        let samples = vertical ? (plan.marginTop, plan.marginBottom) : (plan.marginLeft, plan.marginRight)
        let measured = (samples.0.count >= 3 ? PageStack.median(samples.0) : nil,
                        samples.1.count >= 3 ? PageStack.median(samples.1) : nil)
        var (before, after) = measured
        switch (before, after) {
        case (nil, nil): before = (S - usualText) / 2; after = before
        case (nil, let a?): before = S - usualText - a
        case (let b?, nil): after = S - usualText - b
        default: break
        }
        func fromEdges(_ side: SheetSide) -> Double? {
            switch edges(side) {
            case let (a?, b?): return abs(b - a - S) <= 0.03 * S ? (a + b) / 2 - S / 2 : nil
            case let (a?, nil): return a
            case let (nil, b?): return b - S
            default: return nil
            }
        }
        func fromText(_ side: SheetSide) -> (Double, Double)? {
            text(side).map { ($0.0 - before!, $0.1 + after! - S) }
        }
        // The usual place: where trusted edges put the box, else the text's start.
        let anchored = plan.sides.compactMap(fromEdges)
        let usual = !anchored.isEmpty ? PageStack.median(anchored)
            : plan.sides.compactMap(fromText).isEmpty ? nil : PageStack.median(plan.sides.compactMap(fromText).map(\.0))
        return { side in
            if !vertical && side.member.side != .single {
                let left = side.member.side == .left, (a, b) = edges(side)
                if left, let a { return a }
                if !left, let b { return b - S }
                if let t = text(side), let m = left ? measured.0 : measured.1 { return left ? t.0 - m : t.1 + m - S }
                return left ? side.split * side.inches.width - S : side.split * side.inches.width
            }
            if let e = fromEdges(side) { return e }
            guard let (a, b) = fromText(side) else { return usual }
            if abs(a - b) <= 0.02 * S { return (a + b) / 2 }
            guard let usual else { return a }
            return abs(a - usual) <= abs(b - usual) ? a : b
        }
    }

    func zoomIn() { zoom = min(8, zoom * 1.25) }
    func zoomOut() { zoom = max(1, zoom / 1.25) }
    func zoomToFit() { zoom = 1 }

    func selectAdjacentPage(_ offset: Int) {
        guard !pages.isEmpty else { return }
        let i = max(0, min(pages.count - 1, (selectedIndex ?? 0) + offset))
        selectedPageID = pages[i].id
    }

    // MARK: - Undo

    /// Make a one-step change undoable. Pages it changes count as hand-edited
    /// (analysis still running won't overwrite them).
    func perform(_ actionName: String, _ change: () -> Void) {
        let before = pages, claims = setByAnalysis
        change()
        finishEdit(before: before, claims: claims, actionName: actionName)
    }

    /// Continuous edits (drags, sliders) of the selected page call beginEdit when
    /// they start and endEdit when they finish, so the whole gesture is one undo
    /// step. Only that page is recorded: analysis results for other pages can land
    /// mid-gesture and must not be swept into the undo.
    func beginEdit() {
        guard editSnapshot == nil, let idx = selectedIndex else { return }
        editSnapshot = (pages[idx], setByAnalysis[pages[idx].id])
        // Claim the page now so analysis still running can't overwrite the gesture.
        pages[idx].analyzed = true
        setByAnalysis[pages[idx].id] = nil
    }

    func endEdit(_ actionName: String) {
        guard let snapshot = editSnapshot else { return }
        editSnapshot = nil
        let before = snapshot.page
        guard let i = pages.firstIndex(where: { $0.id == before.id }) else { return }
        var after = pages[i]
        after.analyzed = before.analyzed
        guard after != before else {
            // Nothing changed: release the claim beginEdit made, so a page that
            // was waiting for analysis still gets analyzed.
            setByAnalysis[before.id] = snapshot.claim
            if !before.analyzed {
                pages[i].analyzed = false
                analyzeAll()
            }
            return
        }
        setByAnalysis[before.id] = nil      // an undo mid-gesture may have put it back
        pages[i].analyzed = true            // and analysis must not overwrite the gesture
        registerUndo(restoring: [before], claims: [before.id: snapshot.claim].compactMapValues { $0 },
                     actionName: actionName)
    }

    private func finishEdit(before: [BookPage], claims: [BookPage.ID: AnalysisClaim], actionName: String) {
        guard before.count == pages.count else { return }
        let changed = pages.indices.filter { before[$0] != pages[$0] }
        guard !changed.isEmpty else { return }
        // A hand-edited page must not be overwritten by analysis still running.
        for i in changed { pages[i].analyzed = true }
        for i in changed { setByAnalysis[pages[i].id] = nil }
        registerUndo(restoring: changed.map { before[$0] }, claims: claims, actionName: actionName)
    }

    /// Undo puts back only the pages the edit changed, so it never reverts
    /// analysis results that arrived after the edit. Their analysis claims come
    /// back with them (`claims`: as they were before the edit), so a page undone
    /// to what analysis set is analysis's again.
    private func registerUndo(restoring saved: [BookPage], claims: [BookPage.ID: AnalysisClaim], actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = saved.compactMap { p in model.pages.first { $0.id == p.id } }
                let ids = Set(saved.map(\.id))
                let currentClaims = model.setByAnalysis.filter { ids.contains($0.key) }
                for p in saved {
                    if let i = model.pages.firstIndex(where: { $0.id == p.id }) { model.pages[i] = p }
                    model.setByAnalysis[p.id] = claims[p.id]
                }
                model.registerUndo(restoring: current, claims: currentClaims, actionName: actionName)  // redo
                // Undoing an edit made to a page still waiting for analysis brings
                // it back unanalysed; start a fresh pass for it.
                if model.pages.contains(where: { !$0.analyzed }) { model.analyzeAll() }
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Export

    func exportPanel() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "book"
        panel.nameFieldStringValue = "\(base)-cropped.pdf"
        panel.directoryURL = sourceURL?.deletingLastPathComponent()   // next to the original
        if panel.runModal() == .OK, let url = panel.url {
            export(to: url)
        }
    }

    func export(to url: URL) {
        guard document != nil, var src = sourceURL else { return }
        // Exporting over the scan replaces it with the output: keep reading the
        // scan from a copy, so a second export still finds the pages edited here.
        if url.standardizedFileURL.resolvingSymlinksInPath() == src.standardizedFileURL.resolvingSymlinksInPath() {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("Divisio Textus source \(UUID().uuidString).pdf")
            do { try FileManager.default.copyItem(at: src, to: copy) } catch {
                statusText = "Export failed: couldn't keep a copy of the scan (\(error.localizedDescription))."
                return
            }
            src = copy
            sourceURL = copy
        }
        let password = documentPassword
        isExporting = true
        exportProgress = 0
        // Vision can take a minute or more to start after a while unused; say so
        // rather than look stuck.
        statusText = ocrEnabled ? "Exporting… Text recognition can take a minute to start." : "Exporting…"
        let pagesSnapshot = pages
        var settings = PDFExporter.Settings(dpi: exportDPI, direction: direction, ocr: ocrEnabled, enhanceMode: enhanceMode)
        settings.matchScanResolution = matchScanResolution
        let cancel = CancelFlag()
        exportCancel = cancel
        let started = Date()

        // A GCD thread rather than a Swift task: OCR blocks while it waits for
        // Vision, and that shouldn't tie up Swift's small shared thread pool.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Own PDFDocument, for the same reason as analyzeAll.
                guard let doc = Self.reopen(src, password: password) else { throw PDFExporter.ExportError.sourceUnreadable }
                let report = try PDFExporter.export(pages: pagesSnapshot,
                                                    from: doc,
                                                    to: url,
                                                    settings: settings,
                                                    isCancelled: { cancel.isSet }) { done, total in
                    let elapsed = Date().timeIntervalSince(started)
                    Task { @MainActor in
                        guard self.isExporting, !cancel.isSet else { return }   // keep the final message
                        self.exportProgress = total > 0 ? Double(done) / Double(total) : 0
                        // Named, since another PDF may be open by now.
                        var text = "Exporting “\(url.lastPathComponent)”: page \(done) of \(total)…"
                        // The first pages include Vision warming up, so wait a little
                        // before estimating.
                        if done >= 2, done < total {
                            let remaining = elapsed / Double(done) * Double(total - done)
                            text += " \(Self.describe(remaining)) left."
                        }
                        self.statusText = text
                    }
                }
                Task { @MainActor in
                    self.isExporting = false
                    self.exportProgress = 1
                    self.statusText = Self.exportMessage(url.lastPathComponent, report)
                    if self.revealExportInFinder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } catch PDFExporter.ExportError.cancelled {
                Task { @MainActor in
                    self.isExporting = false
                    self.exportProgress = 0
                    self.statusText = "Export cancelled."
                }
            } catch {
                Task { @MainActor in
                    self.isExporting = false
                    self.statusText = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelExport() {
        guard isExporting, let exportCancel else { return }
        exportCancel.set()
        statusText = "Cancelling export… (finishing the pages in progress)"
    }

    nonisolated private static func describe(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "Under a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 90 { return "About \(minutes) minute\(minutes == 1 ? "" : "s")" }
        return "About \(minutes / 60) h \(minutes % 60) min"
    }

    private func saveEdits(_ pages: [BookPage], _ direction: ReadingDirection, wait: Bool) {
        guard let key = projectKey, !pages.isEmpty else { return }
        let saved = ProjectStore.Saved(pages: pages, direction: direction, cropTarget: cropTarget,
                                       pageSize: pageSizeOverride, claims: setByAnalysis)
        // A failed save is said, not swallowed: later edits would go unsaved too.
        let save = { [weak self] in
            do { try ProjectStore.save(saved, key: key) } catch {
                Task { @MainActor in self?.statusText = "Couldn't save your edits: \(error.localizedDescription)" }
            }
        }
        if wait { saveQueue.sync(execute: save) } else { saveQueue.async(execute: save) }
    }

    nonisolated private static func exportMessage(_ name: String, _ report: PDFExporter.Report) -> String {
        let failed = report.ocrFailedPages
        guard !failed.isEmpty else { return "Exported \(name)." }
        var list = failed.prefix(10).map(String.init).joined(separator: ", ")
        if failed.count > 10 { list += ", …" }
        return "Exported \(name), but text recognition failed on \(failed.count) of \(report.pageCount) "
            + "pages (\(list)), so those aren't fully searchable. Exporting again usually fixes it."
    }
}


/// A thread-safe flag the export thread polls to see whether to stop.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// What analysis found on a page it set, kept until the page is edited by hand:
/// which sides were blank, and for Whole page crops, what each side shows of its
/// sheet and the crops analysis found before the book's page size was applied.
struct AnalysisClaim: Codable {
    var leftBlank: Bool
    var rightBlank: Bool
    var leftSheet: PageAnalyzer.Sheet?
    var rightSheet: PageAnalyzer.Sheet?
    var leftFound: CropRect?
    var rightFound: CropRect?

    init(_ result: PageAnalyzer.Result) {
        leftBlank = result.leftBlank
        rightBlank = result.rightBlank
        leftSheet = result.leftSheet
        rightSheet = result.rightSheet
    }
}
