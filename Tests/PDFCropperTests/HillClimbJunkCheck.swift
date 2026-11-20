import Testing
import Foundation
import PDFKit
@testable import PDFCropper

/// Hill-climb OCR junk check: exports the first pages of an English book with Apple
/// Vision and Greek ticked, then lists the Greek-script text in the text layer.
/// A page whose print has no Greek should add none.
///
/// Runs only when HILLCLIMB_JUNK is set (and HILLCLIMB_DIR points at the books).
/// Writes results/<label>/junk.json. Run it outside the sandbox: Vision needs it.
///   HILLCLIMB_JUNK=1 HILLCLIMB_DIR=... HILLCLIMB_LABEL=before swift test --filter HillClimbJunkCheck
/// Optional: HILLCLIMB_JUNK_BOOK (default "Smith-1950"), HILLCLIMB_JUNK_PAGES (default 20).
@Suite("HillClimb junk check", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HILLCLIMB_JUNK"] != nil
                && ProcessInfo.processInfo.environment["HILLCLIMB_DIR"] != nil))
@MainActor
struct HillClimbJunkCheck {
    @Test("Greek in the text layer of an English book")
    func junk() async throws {
        HillClimb.prepare()
        let env = ProcessInfo.processInfo.environment
        let name = env["HILLCLIMB_JUNK_BOOK"] ?? "Smith-1950"
        let count = Int(env["HILLCLIMB_JUNK_PAGES"] ?? "") ?? 20
        let url = try #require(HillClimb.bookURLs().first { HillClimb.shortName($0) == name })
        let m = HillClimb.makeModel()
        await HillClimb.load(url, into: m)
        let pages = Array(m.pages.prefix(count))
        var settings = PDFExporter.Settings(dpi: m.exportDPI, direction: m.direction, ocr: true,
                                            reader: .apple, packs: ["grc"], enhanceMode: m.enhanceMode)
        settings.matchScanResolution = m.matchScanResolution
        let out = HillClimb.scratch.appendingPathComponent("junk-\(name).pdf")
        try? FileManager.default.removeItem(at: out)
        let report: PDFExporter.Report? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let doc = AppModel.reopen(url, password: nil) else { cont.resume(returning: nil); return }
                cont.resume(returning: try? PDFExporter.export(pages: pages, from: doc, to: out, settings: settings))
            }
        }
        #expect(report != nil)
        let doc = try #require(PDFDocument(url: out))
        var perPage: [[String: Any]] = []
        var chars = 0, lines = 0
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string ?? ""
            let greek = text.components(separatedBy: .newlines).filter { line in
                line.unicodeScalars.contains { Script.greek.contains($0) && $0.properties.isAlphabetic }
            }
            let n = greek.reduce(0) { $0 + $1.unicodeScalars.filter { Script.greek.contains($0) && $0.properties.isAlphabetic }.count }
            chars += n; lines += greek.count
            perPage.append(["page": i + 1, "greekChars": n, "greekLines": greek, "allLines": text.components(separatedBy: .newlines)])
        }
        print("HCJUNK \(HillClimb.label) \(name) pages=\(doc.pageCount) greekChars=\(chars) greekLines=\(lines)")
        HillClimb.write(["label": HillClimb.label, "book": name, "greekChars": chars, "greekLines": lines, "pages": perPage],
                        "junk.json")
    }
}
