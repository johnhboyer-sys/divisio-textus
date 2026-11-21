import Testing
import Foundation
import PDFKit
@testable import PDFCropper

/// Draws chosen pages as the exporter makes them, for the owner to judge the
/// black-and-white export by eye. Runs only when BW_SHOW_DIR and HILLCLIMB_DIR are
/// set. For each case it exports the one source page and writes every output page,
/// drawn at the resolution it was made at, as `<case>-<BW_SHOW_TAG>-<k>.png`, and the
/// gray export of the same crop as `<case>-gray-<k>.png`. BW_SHOW_MODE (color, gray or
/// bw; default color) picks the export's color, BW_SHOW_REMOVE=1 turns on Remove shadows.
@Suite("BW show", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["BW_SHOW_DIR"] != nil
                    && ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct BWShowTests {
    /// Case name, book, 1-based source page, whether the book is a plain scan.
    static let cases: [(name: String, book: String, page: Int, plain: Bool)] = [
        ("smith-p1", "Smith-1950", 1, false), ("smith-p2", "Smith-1950", 2, false), ("smith-p76", "Smith-1950", 76, false),
        ("smith-p58", "Smith-1950", 58, false), ("smith-p59", "Smith-1950", 59, false),
        ("smith-p40", "Smith-1950", 40, false),
        ("riezler-p44", "Riezler-1940", 44, true), ("wallace-p20", "Wallace-1992", 20, true),
        ("cherniss-p131", "Cherniss-1935", 131, true),
    ]

    @Test("Draw the cases")
    func draw() async throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["BW_SHOW_DIR"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tag = env["BW_SHOW_TAG"] ?? "after"
        let only = env["BW_SHOW_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        var models: [String: (AppModel, URL)] = [:]
        for c in Self.cases where only?.contains(c.name) ?? true {
            if models[c.book] == nil {
                guard let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == c.book }) else { continue }
                let m = HillClimb.makeModel()
                await HillClimb.load(url, into: m)
                models[c.book] = (m, url)
            }
            guard let (m, url) = models[c.book],
                  let page = m.pages.first(where: { $0.sourceIndex == c.page - 1 }) else { continue }
            let mode: EnhanceMode = env["BW_SHOW_MODE"] == "bw" ? .blackAndWhite
                : env["BW_SHOW_MODE"] == "gray" ? .grayscale : .color
            var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false,
                                                reader: m.ocrReader, packs: m.ocrPacks, enhanceMode: mode)
            settings.removeShadows = env["BW_SHOW_REMOVE"] == "1"
            settings.matchScanResolution = m.matchScanResolution
            let pdf = HillClimb.scratch.appendingPathComponent("\(c.name).pdf")
            let doc = try #require(AppModel.reopen(url, password: nil))
            _ = try PDFExporter.export(pages: [page], from: doc, to: pdf, settings: settings)
            let made = try #require(PDFDocument(url: pdf))
            var dpis: [Double] = []
            for k in 0..<made.pageCount {
                let p = try #require(made.page(at: k))
                let image = try #require(PDFRenderer.drawnContent(p.pageRef!)?.images.first)
                let dpi = Double(image.pixelWidth) / (p.bounds(for: .mediaBox).width / 72)
                dpis.append(dpi)
                let drawn = try #require(PDFRenderer.renderCGImage(page: p, dpi: dpi))
                HillClimb.png(drawn, to: out.appendingPathComponent("\(c.name)-\(tag)-\(k + 1).png"))
            }
            // The gray export of the same crops, at the same resolution: what the page holds.
            var gray = settings
            gray.enhanceMode = .grayscale
            let src = try #require(doc.page(at: page.sourceIndex))
            if let dpi = dpis.first, let rendered = PDFRenderer.renderCGImage(page: src, dpi: dpi),
               let images = PDFExporter.outputImages(of: page, rendered: rendered, settings: gray) {
                for (k, im) in images.enumerated() {
                    HillClimb.png(im, to: out.appendingPathComponent("\(c.name)-gray-\(k + 1).png"))
                }
            }
            print("BWSHOW \(c.name) \(tag) pages=\(made.pageCount) dpi=\(dpis) bytes=\(HillClimb.fileSize(pdf))")
        }
    }
}
