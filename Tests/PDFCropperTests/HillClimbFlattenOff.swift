import Testing
import Foundation
import PDFKit
@testable import PDFCropper

/// With Flatten pages off, an export must be byte for byte what it was before the option
/// existed. This suite uses only what that older code has, so the same file runs on both:
/// it exports Smith-1950 pages 1-40, Riezler-1940 and Wallace-1992 with the settings the
/// app ships (OCR off) to results/<label>/off/<book>.pdf. Compare two labels' files with
/// the dates the PDF writer stamps left out. Runs when HILLCLIMB_FLATTEN_OFF is set.
@Suite("HillClimb flatten off", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil
                && ProcessInfo.processInfo.environment["HILLCLIMB_FLATTEN_OFF"] != nil))
@MainActor
struct HillClimbFlattenOff {
    static let jobs: [(name: String, pages: Int?)] = [("Smith-1950", 40), ("Riezler-1940", nil), ("Wallace-1992", nil)]

    @Test("Export with the option off")
    func exportOff() async throws {
        HillClimb.prepare()
        let dir = HillClimb.results.appendingPathComponent("off", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for job in Self.jobs {
            let url = try #require(HillClimb.bookURLs().first { HillClimb.shortName($0) == job.name })
            let m = HillClimb.makeModel()
            await HillClimb.load(url, into: m)
            let pages = Array(m.pages.prefix(job.pages ?? m.pages.count))
            var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false,
                                                reader: m.ocrReader, packs: m.ocrPacks, enhanceMode: m.enhanceMode)
            settings.matchScanResolution = m.matchScanResolution
            let out = dir.appendingPathComponent("\(job.name).pdf")
            try? FileManager.default.removeItem(at: out)
            let report: PDFExporter.Report? = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let doc = AppModel.reopen(url, password: nil) else { cont.resume(returning: nil); return }
                    cont.resume(returning: try? PDFExporter.export(pages: pages, from: doc, to: out, settings: settings))
                }
            }
            #expect(report != nil, "\(job.name): export failed")
        }
    }
}
