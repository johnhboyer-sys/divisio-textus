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
        didSet { if enhanceMode != oldValue { previewCache.removeAll() } }
    }

    @Published var isBusy = false
    @Published var statusText = "Open a scanned PDF to begin."
    @Published var exportProgress: Double = 0

    // Preview-image cache keyed by source page index, remembering the per-side
    // skew and split the cached composite was built with so any change re-renders.
    private var previewCache: [Int: (left: Double, right: Double, split: Double, image: NSImage)] = [:]
    private let previewDPI: Double = 110

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
        previewCache.removeAll()
        document = doc
        sourceURL = url
        pages = (0..<doc.pageCount).map { BookPage(sourceIndex: $0) }
        selectedPageID = pages.first?.id
        statusText = "Loaded \(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s"). Analyzing…"
        analyzeAll()
    }

    // MARK: - Previews

    func previewImage(for page: BookPage) -> NSImage? {
        if let c = previewCache[page.sourceIndex],
           c.left == page.leftSkew, c.right == page.rightSkew, c.split == page.splitX {
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
        previewCache[page.sourceIndex] = (page.leftSkew, page.rightSkew, page.splitX, img)
        return img
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

    func analyzeAll() {
        guard let doc = document else { return }
        isBusy = true
        let snapshot = pages
        let deskew = autoDeskewEnabled
        Task.detached { [previewDPI] in
            var results: [(index: Int, left: Double, right: Double, r: PageAnalyzer.Result)] = []
            for page in snapshot where !page.analyzed {
                guard let pdfPage = doc.page(at: page.sourceIndex),
                      let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { continue }
                // 1) classification + gutter on the raw page
                let r0 = PageAnalyzer.analyze(cgImage: cg)
                let spread = r0.classification == .spread
                // 2) independent skew per book page
                let skews = deskew ? Self.detectSkews(cg, splitX: r0.splitX, isSpread: spread) : (left: 0.0, right: 0.0)
                // 3) re-find crops on the straightened composite so they align
                let composite = ImageTransform.deskewedComposite(
                    cg, splitX: r0.splitX, leftDegrees: skews.left, rightDegrees: skews.right, isSpread: spread)
                var r1 = PageAnalyzer.analyze(cgImage: composite)
                r1.classification = r0.classification
                results.append((page.sourceIndex, skews.left, skews.right, r1))
            }
            let finalResults = results
            await MainActor.run {
                for item in finalResults {
                    if let i = self.pages.firstIndex(where: { $0.sourceIndex == item.index }) {
                        self.pages[i].leftSkew = item.left
                        self.pages[i].rightSkew = item.right
                        self.pages[i].classification = item.r.classification
                        self.pages[i].splitX = item.r.splitX
                        self.pages[i].leftCrop = item.r.leftCrop
                        self.pages[i].rightCrop = item.r.rightCrop
                        self.pages[i].analyzed = true
                    }
                }
                self.isBusy = false
                self.statusText = "Ready — \(self.pages.count) source pages → \(self.outputPageCount) output pages."
            }
        }
    }

    func reanalyzeSelected() {
        guard let idx = selectedIndex, let doc = document else { return }
        guard let pdfPage = doc.page(at: pages[idx].sourceIndex),
              let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { return }
        let r0 = PageAnalyzer.analyze(cgImage: cg)
        let spread = r0.classification == .spread
        let skews = autoDeskewEnabled ? Self.detectSkews(cg, splitX: r0.splitX, isSpread: spread) : (left: 0.0, right: 0.0)
        let composite = ImageTransform.deskewedComposite(
            cg, splitX: r0.splitX, leftDegrees: skews.left, rightDegrees: skews.right, isSpread: spread)
        var r1 = PageAnalyzer.analyze(cgImage: composite)
        r1.classification = r0.classification
        pages[idx].leftSkew = skews.left
        pages[idx].rightSkew = skews.right
        pages[idx].classification = r1.classification
        pages[idx].splitX = r1.splitX
        pages[idx].leftCrop = r1.leftCrop
        pages[idx].rightCrop = r1.rightCrop
    }

    /// Re-detect only the skew angles for the selected page (keeps current crops).
    func autoStraightenSelected() {
        guard let idx = selectedIndex, let doc = document else { return }
        guard let pdfPage = doc.page(at: pages[idx].sourceIndex),
              let cg = PDFRenderer.renderCGImage(page: pdfPage, dpi: previewDPI) else { return }
        let s = Self.detectSkews(cg, splitX: pages[idx].splitX, isSpread: pages[idx].isSpread)
        pages[idx].leftSkew = s.left
        pages[idx].rightSkew = s.right
    }

    // MARK: - Editing helpers

    func updateSelected(_ mutate: (inout BookPage) -> Void) {
        guard let idx = selectedIndex else { return }
        mutate(&pages[idx])
    }

    /// Copy the selected page's crop layout to every other spread (Briss-style
    /// "apply one common crop"). Singles get the left crop applied.
    func applyCropsToAllSpreads() {
        guard let sel = selectedPage else { return }
        for i in pages.indices {
            switch pages[i].classification {
            case .spread:
                pages[i].splitX = sel.splitX
                pages[i].leftCrop = sel.leftCrop
                pages[i].rightCrop = sel.rightCrop
            case .single:
                pages[i].leftCrop = sel.leftCrop
            case .skip:
                break
            }
        }
        statusText = "Applied crop layout to all pages."
    }

    func setClassification(_ c: PageClassification, for id: BookPage.ID) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].classification = c
    }

    // MARK: - Export

    func exportPanel() {
        guard document != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "book"
        panel.nameFieldStringValue = "\(base)-cropped.pdf"
        if panel.runModal() == .OK, let url = panel.url {
            export(to: url)
        }
    }

    func export(to url: URL) {
        guard let doc = document else { return }
        isBusy = true
        exportProgress = 0
        statusText = "Exporting…"
        let pagesSnapshot = pages
        let settings = PDFExporter.Settings(dpi: exportDPI, direction: direction, ocr: ocrEnabled, enhanceMode: enhanceMode)

        Task.detached {
            do {
                try PDFExporter.export(pages: pagesSnapshot,
                                       from: doc,
                                       to: url,
                                       settings: settings) { done, total in
                    Task { @MainActor in
                        self.exportProgress = total > 0 ? Double(done) / Double(total) : 0
                    }
                }
                await MainActor.run {
                    self.isBusy = false
                    self.exportProgress = 1
                    self.statusText = "Exported \(url.lastPathComponent)."
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.statusText = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
