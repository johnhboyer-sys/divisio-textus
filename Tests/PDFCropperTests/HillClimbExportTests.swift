import Testing
import Foundation
import AppKit
import PDFKit
@testable import PDFCropper

/// Hill-climb score C: how big, how fast and how faithful an export is.
///
/// Runs only when HILLCLIMB_DIR is set (see Tools/hillclimb/README.md). Writes
/// results/<label>/export.json. A fixed set of pages, exported with the settings the
/// app ships (300 DPI unless matching the scan, which it does; JPEG quality 0.7; color;
/// reader Apple), OCR off. Each export runs twice for time. Fidelity compares each
/// exported page, drawn again at the DPI it was made at, with the uncompressed crop
/// the exporter was given (`PDFExporter.outputImages`).
@Suite("HillClimb export", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct HillClimbExportTests {

    /// Book, and how many of its first pages (nil: all).
    static let jobs: [(name: String, pages: Int?)] = [("Smith-1950", 40), ("Riezler-1940", nil), ("Wallace-1992", 30)]
    static let ocrBook = (name: "Smith-1950", pages: 10)

    struct Timed {
        var seconds: Double
        var bytes: Int
        var report: PDFExporter.Report?
    }

    /// Export on a background thread, as the app does, and time the export alone.
    private func timedExport(_ pages: [BookPage], from source: URL, to out: URL,
                             settings: PDFExporter.Settings) async -> Timed {
        try? FileManager.default.removeItem(at: out)
        let t0 = HillClimb.now()
        let report: PDFExporter.Report? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let doc = AppModel.reopen(source, password: nil) else { cont.resume(returning: nil); return }
                cont.resume(returning: try? PDFExporter.export(pages: pages, from: doc, to: out, settings: settings))
            }
        }
        let seconds = HillClimb.now() - t0
        return Timed(seconds: seconds, bytes: HillClimb.fileSize(out), report: report)
    }

    /// The DPI the exporter renders a page at.
    private func exportDPI(_ page: PDFPage, _ settings: PDFExporter.Settings) -> Double {
        PDFExporter.renderDPI(scanDPI: PDFRenderer.scanDPI(of: page), settings: settings)
    }

    /// PSNR in dB over all color channels between two images, compared over their common
    /// top-left area. 100 for identical. `sameSize` is false when the sizes differ.
    private func psnr(_ a: CGImage, _ b: CGImage) -> (db: Double, sameSize: Bool) {
        let w = min(a.width, b.width), h = min(a.height, b.height)
        guard w > 0, h > 0 else { return (0, false) }
        let pa = HillClimb.rgbx(a), pb = HillClimb.rgbx(b)
        var sum = 0.0
        for y in 0..<h {
            var ia = y * a.width * 4, ib = y * b.width * 4
            var row = 0
            for _ in 0..<w {
                for c in 0..<3 {
                    let d = Int(pa[ia + c]) - Int(pb[ib + c])
                    row += d * d
                }
                ia += 4; ib += 4
            }
            sum += Double(row)
        }
        let mse = sum / Double(w * h * 3)
        let db = mse == 0 ? 100 : min(100, 10 * log10(255 * 255 / mse))
        return (db, a.width == b.width && a.height == b.height)
    }

    private struct Fidelity {
        var mean = 0.0, min = 100.0, minPage = 0, count = 0, mismatched = 0
    }

    private func fidelity(of exported: URL, pages: [BookPage], source: URL,
                          settings: PDFExporter.Settings) -> Fidelity? {
        guard let made = PDFDocument(url: exported), let src = PDFDocument(url: source) else { return nil }
        var f = Fidelity()
        var sum = 0.0
        var j = 0
        for page in pages where !page.outputCrops(direction: settings.direction).isEmpty {
            autoreleasepool {
                guard let pdfPage = src.page(at: page.sourceIndex) else { return }
                let dpi = exportDPI(pdfPage, settings)
                guard let rendered = PDFRenderer.renderCGImage(page: pdfPage, dpi: dpi),
                      let truth = PDFExporter.outputImages(of: page, rendered: rendered, settings: settings) else { return }
                for image in truth {
                    defer { j += 1 }
                    guard let out = made.page(at: j), let again = PDFRenderer.renderCGImage(page: out, dpi: dpi) else { continue }
                    let r = psnr(image, again)
                    sum += r.db
                    f.count += 1
                    if !r.sameSize { f.mismatched += 1 }
                    if r.db < f.min { f.min = r.db; f.minPage = j + 1 }
                }
            }
        }
        f.mean = f.count > 0 ? sum / Double(f.count) : 0
        guard j == made.pageCount else { return nil }   // the exported file must hold what was given
        return f
    }

    @Test("Score export size, speed and fidelity")
    func score() async {
        HillClimb.prepare()
        let start = HillClimb.now()
        var books: [[String: Any]] = []
        var totalBytes = 0, totalSeconds = 0.0, psnrSum = 0.0, psnrCount = 0, worst = 100.0
        var ocr: [String: Any] = [:]
        let tmp = HillClimb.scratch

        for job in Self.jobs {
            guard let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == job.name }) else {
                Issue.record("no book named \(job.name) in \(HillClimb.books.path)"); continue
            }
            let m = HillClimb.makeModel()
            await HillClimb.load(url, into: m)
            let pages = Array(m.pages.prefix(job.pages ?? m.pages.count))
            // As the app builds them from its own state; OCR off for the size and speed run.
            var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: false,
                                                reader: m.ocrReader, packs: m.ocrPacks, enhanceMode: m.enhanceMode)
            settings.matchScanResolution = m.matchScanResolution
            let out1 = tmp.appendingPathComponent("\(job.name)-1.pdf"), out2 = tmp.appendingPathComponent("\(job.name)-2.pdf")
            let first = await timedExport(pages, from: url, to: out1, settings: settings)
            let second = await timedExport(pages, from: url, to: out2, settings: settings)
            let fid = fidelity(of: out1, pages: pages, source: url, settings: settings)
            try? FileManager.default.removeItem(at: out1)
            try? FileManager.default.removeItem(at: out2)
            let outputPages = first.report?.pageCount ?? 0
            #expect(first.report != nil && second.report != nil, "\(job.name): export failed")
            #expect(fid != nil, "\(job.name): fidelity could not be measured")
            let minSeconds = min(first.seconds, second.seconds)
            books.append([
                "name": job.name, "sourcePages": pages.count, "outputPages": outputPages,
                "bytes": [first.bytes, second.bytes], "bytesMin": min(first.bytes, second.bytes),
                "seconds": [HillClimb.r(first.seconds, 2), HillClimb.r(second.seconds, 2)],
                "secondsMin": HillClimb.r(minSeconds, 2),
                "meanPSNR": HillClimb.r(fid?.mean ?? 0, 3), "minPagePSNR": HillClimb.r(fid?.min ?? 0, 3),
                "minPagePSNRPage": fid?.minPage ?? 0, "sizeMismatchPages": fid?.mismatched ?? -1,
            ])
            totalBytes += min(first.bytes, second.bytes)
            totalSeconds += minSeconds
            if let fid { psnrSum += fid.mean * Double(fid.count); psnrCount += fid.count; worst = min(worst, fid.min) }
        }

        // OCR on (Apple Vision), for the time alone.
        if let url = HillClimb.bookURLs().first(where: { HillClimb.shortName($0) == Self.ocrBook.name }) {
            let m = HillClimb.makeModel()
            await HillClimb.load(url, into: m)
            let pages = Array(m.pages.prefix(Self.ocrBook.pages))
            var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: true,
                                                reader: .apple, packs: [], enhanceMode: m.enhanceMode)
            settings.matchScanResolution = m.matchScanResolution
            let a = await timedExport(pages, from: url, to: tmp.appendingPathComponent("ocr-1.pdf"), settings: settings)
            let b = await timedExport(pages, from: url, to: tmp.appendingPathComponent("ocr-2.pdf"), settings: settings)
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent("ocr-1.pdf"))
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent("ocr-2.pdf"))
            ocr = [
                "name": Self.ocrBook.name, "sourcePages": pages.count, "outputPages": a.report?.pageCount ?? 0,
                "bytes": [a.bytes, b.bytes],
                "seconds": [HillClimb.r(a.seconds, 2), HillClimb.r(b.seconds, 2)],
                "secondsMin": HillClimb.r(min(a.seconds, b.seconds), 2),
                "ocrFailedPages": [a.report?.ocrFailedPages.count ?? -1, b.report?.ocrFailedPages.count ?? -1],
            ]
            #expect(a.report != nil && b.report != nil, "OCR export failed (Vision can fail inside a sandbox)")
        }

        HillClimb.write([
            "label": HillClimb.label, "books": books, "ocr": ocr,
            "totals": ["bytes": totalBytes, "secondsMin": HillClimb.r(totalSeconds, 2),
                       "meanPSNR": HillClimb.r(psnrCount > 0 ? psnrSum / Double(psnrCount) : 0, 3),
                       "minPagePSNR": HillClimb.r(worst, 3), "pages": psnrCount],
            "wallSeconds": HillClimb.r(HillClimb.now() - start, 1),
        ], "export.json")
        #expect(books.count == Self.jobs.count)
    }
}
