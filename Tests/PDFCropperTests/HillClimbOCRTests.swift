import Testing
import Foundation
import PDFKit
import CoreGraphics
import ImageIO
@testable import PDFCropper

/// OCR accuracy harness (a hill climb). It runs only when HILLCLIMB_DIR is set, and
/// writes $HILLCLIMB_DIR/results/$HILLCLIMB_LABEL/ocr.json. See Tools/hillclimb/ocr/README.md.
enum HCEnv {
    static let dir: String? = {
        let v = ProcessInfo.processInfo.environment["HILLCLIMB_DIR"]
        return v?.isEmpty == false ? v : nil
    }()
    static var label: String {
        let v = ProcessInfo.processInfo.environment["HILLCLIMB_LABEL"]
        return v?.isEmpty == false ? v! : "current"
    }
    static func flag(_ name: String) -> Bool { ProcessInfo.processInfo.environment[name] == "1" }
    /// The repository root, from this file's place in it.
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

@Suite("HillClimbOCR", .serialized, .enabled(if: HCEnv.dir != nil))
struct HillClimbOCRTests {

    struct Page {
        var spec: HCPageSpec
        var rendered: HCRendered
        var scan: CGImage
        var truth: String { rendered.truth.joined(separator: "\n") }
    }

    /// Jobs: reader, packs it needs, and the tesseract folder when it reads.
    struct Job {
        var name: String
        var reader: OCRReader
        var packs: [String]
        var note: String
    }

    // MARK: - Pages

    static func makePages() -> [Page] {
        let specs = HCPages.all()
        var out = [Page?](repeating: nil, count: specs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: specs.count) { i in
            let rendered = HCTypeset.render(specs[i])
            let scan = HCScan.degrade(rendered, look: HCPages.look(specs[i].number)).image
            lock.withLock { out[i] = Page(spec: specs[i], rendered: rendered, scan: scan) }
        }
        return out.compactMap { $0 }
    }

    /// One PDF holding each image at its page size, as a scanner's PDF would.
    static func writePDF(_ images: [(CGImage, CGSize)], to url: URL) {
        var first = CGRect(origin: .zero, size: images[0].1)
        let ctx = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &first, nil)!
        for (image, size) in images {
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    // MARK: - Tesseract

    /// Folders that may hold language packs, read only. The app's own pack folder in
    /// Application Support is not one of them.
    static func tessdataCandidates() -> [URL] {
        var folders: [URL] = []
        if let env = ProcessInfo.processInfo.environment["HILLCLIMB_TESSDATA"], !env.isEmpty {
            folders += env.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        folders += ["/opt/homebrew/share/tessdata", "/usr/local/share/tessdata",
                    "/Applications/Divisio Textus.app/Contents/Resources/tessdata"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        // The repository's own Tesseract build, in this checkout or the one a worktree sits in.
        var up = HCEnv.repo
        for _ in 0..<6 {
            folders.append(up.appendingPathComponent(".build-tesseract/out/tessdata", isDirectory: true))
            up = up.deletingLastPathComponent()
        }
        return folders
    }

    /// A temporary folder of links to the packs found, so Tesseract reads from one place.
    static func tessdataFolder(in work: URL) -> (URL, Set<String>) {
        let folder = work.appendingPathComponent("tessdata", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var have = Set<String>()
        for code in ["eng", "grc", "lat", "deu"] {
            for dir in tessdataCandidates() {
                let file = dir.appendingPathComponent("\(code).traineddata")
                if FileManager.default.isReadableFile(atPath: file.path),
                   (try? FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("\(code).traineddata"),
                                                                withDestinationURL: file)) != nil {
                    have.insert(code); break
                }
            }
        }
        return (folder, have)
    }

    static func tesseractVersion(_ exe: URL) -> String {
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return "unknown" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "unknown"
    }

    // MARK: - Scoring a run

    static func rounded(_ x: Double?) -> Any {
        guard let x else { return NSNull() }
        return (x * 100_000).rounded() / 100_000
    }

    static func summary(_ pages: [HCScore.Page]) -> [String: Any] {
        func sum(_ key: KeyPath<HCScore.Page, HCScore.Part>) -> HCScore.Part {
            pages.reduce(HCScore.Part()) { $0 + $1[keyPath: key] }
        }
        let chunks = pages.reduce(0) { $0 + $1.chunks }
        let found = pages.reduce(0) { $0 + $1.found }
        let inOrder = pages.reduce(0) { $0 + $1.inOrder }
        return [
            "cer": rounded(sum(\.char).rate), "wer": rounded(sum(\.word).rate),
            "greekCER": rounded(sum(\.greek).rate), "latinCER": rounded(sum(\.latin).rate),
            "order": rounded(found > 0 ? Double(inOrder) / Double(found) : nil),
            "chunkRecall": rounded(chunks > 0 ? Double(found) / Double(chunks) : nil),
        ]
    }

    /// Exports `pdf` with `settings`, reads the text back from the written PDF and
    /// scores each page.
    static func run(_ job: Job, settings: PDFExporter.Settings, source: PDFDocument, pages: [Page],
                    work: URL) -> [String: Any] {
        let book = pages.indices.map { BookPage(sourceIndex: $0, classification: .single, leftCrop: .full, analyzed: true) }
        let out = work.appendingPathComponent("\(job.name).pdf")
        var result: [String: Any] = ["name": job.name, "reader": job.reader.rawValue, "packs": job.packs, "note": job.note]
        let start = Date()
        let report: PDFExporter.Report
        do {
            report = try PDFExporter.export(pages: book, from: source, to: out, settings: settings)
        } catch {
            result["status"] = "error"; result["reason"] = "\(error)"
            Issue.record("\(job.name): export failed: \(error)")
            return result
        }
        let seconds = Date().timeIntervalSince(start)
        guard let doc = PDFDocument(url: out), doc.pageCount == pages.count else {
            result["status"] = "error"; result["reason"] = "output PDF unreadable"
            Issue.record("\(job.name): output PDF unreadable")
            return result
        }
        var scores: [HCScore.Page] = []
        var perPage: [[String: Any]] = []
        for (i, page) in pages.enumerated() {
            let reading = doc.page(at: i)?.string ?? ""
            let s = HCScore.score(truth: page.truth, reading: reading)
            scores.append(s)
            perPage.append(["page": page.spec.number, "kind": page.spec.kind,
                            "cer": rounded(s.char.rate), "wer": rounded(s.word.rate),
                            "greekCER": rounded(s.greek.rate), "latinCER": rounded(s.latin.rate),
                            "truthChars": s.char.length, "edits": s.char.edits])
        }
        var byKind: [String: Any] = [:]
        for kind in Set(pages.map(\.spec.kind)).sorted() {
            let ix = pages.indices.filter { pages[$0].spec.kind == kind }
            byKind[kind] = summary(ix.map { scores[$0] })["cer"]
        }
        result["status"] = "ok"
        result["secondsTotal"] = rounded(seconds)
        result["secondsPerPage"] = rounded(seconds / Double(pages.count))
        result["ocrFailedPages"] = report.ocrFailedPages
        result["summary"] = summary(scores)
        result["cerByKind"] = byKind
        result["pages"] = perPage
        return result
    }

    // MARK: - The test

    @Test("Score the app's OCR text layer against known truth")
    func score() throws {
        let dir = try #require(HCEnv.dir)
        let wall = Date()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("HillClimbOCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Pages and truth.
        let pages = Self.makePages()
        #expect(pages.count >= 24)
        let truthDir = HCEnv.repo.appendingPathComponent("Tools/hillclimb/ocr/truth", isDirectory: true)
        var drift: [Int] = []
        for p in pages {
            let file = truthDir.appendingPathComponent(String(format: "page%02d.txt", p.spec.number))
            if HCEnv.flag("HILLCLIMB_WRITE_TRUTH") {
                try FileManager.default.createDirectory(at: truthDir, withIntermediateDirectories: true)
                try (p.truth + "\n").write(to: file, atomically: true, encoding: .utf8)
            } else if (try? String(contentsOf: file, encoding: .utf8)) != p.truth + "\n" {
                drift.append(p.spec.number)
            }
        }
        if !drift.isEmpty {
            print("HCOCR note: generated truth differs from Tools/hillclimb/ocr/truth for pages \(drift) (system hyphenation or fonts changed); scores use the generated truth")
        }
        if HCEnv.flag("HILLCLIMB_WRITE_FIXTURES") {
            let fixtures = HCEnv.repo.appendingPathComponent("Tools/hillclimb/ocr/fixtures", isDirectory: true)
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
            for n in [1, 18] {
                Self.writeJPEG(pages[n - 1].scan, to: fixtures.appendingPathComponent(String(format: "sample-page%02d.jpg", n)))
            }
            Self.writeJPEG(pages[0].rendered.image, to: fixtures.appendingPathComponent("sample-page01-clean.jpg"), quality: 0.4)
        }

        let source = work.appendingPathComponent("scan.pdf")
        Self.writePDF(pages.map { ($0.scan, $0.spec.size) }, to: source)
        let sourceDoc = try #require(PDFDocument(url: source))

        // Readers available here.
        let executable = TesseractService.executableURL()
        let (tessdata, packs) = Self.tessdataFolder(in: work)
        let previousOverride = PDFExporter.tessdataOverride
        PDFExporter.tessdataOverride = tessdata
        defer { PDFExporter.tessdataOverride = previousOverride }

        var runs: [[String: Any]] = []
        func skipped(_ name: String, _ reader: OCRReader, _ packs: [String], _ reason: String) {
            runs.append(["name": name, "reader": reader.rawValue, "packs": packs, "status": "skipped", "reason": reason])
        }
        func settings(_ reader: OCRReader, _ packs: [String]) -> PDFExporter.Settings {
            var s = PDFExporter.Settings()
            s.reader = reader; s.packs = packs
            return s
        }

        // 1. Apple Vision, English (what the app does with no pack ticked).
        runs.append(Self.run(Job(name: "vision-en", reader: .apple, packs: [], note: "Apple Vision, English"),
                             settings: settings(.apple, []), source: sourceDoc, pages: pages, work: work))
        // 2. Apple Vision with Greek ticked: Vision reads, Tesseract's grc fills in the Greek.
        //    Vision itself has no Greek, so this is also the "Vision with Tesseract fill-in" mode.
        if executable == nil {
            skipped("vision-grc-fillin", .apple, ["grc"], "no tesseract executable")
        } else if !packs.contains("grc") || !packs.contains("eng") {
            skipped("vision-grc-fillin", .apple, ["grc"], "grc.traineddata or eng.traineddata not found")
        } else {
            runs.append(Self.run(Job(name: "vision-grc-fillin", reader: .apple, packs: ["grc"],
                                     note: "Apple Vision, Greek filled in by Tesseract grc"),
                                 settings: settings(.apple, ["grc"]), source: sourceDoc, pages: pages, work: work))
        }
        // 3. The Tesseract reader with every pack of grc, lat, deu this Mac has, and English.
        let tessPacks = ["grc", "lat", "deu"].filter { packs.contains($0) }
        let missing = ["lat", "deu"].filter { !packs.contains($0) }
        if executable == nil {
            skipped("tesseract", .tesseract, tessPacks, "no tesseract executable")
        } else if !packs.contains("eng") || !packs.contains("grc") {
            skipped("tesseract", .tesseract, tessPacks, "eng.traineddata or grc.traineddata not found")
        } else {
            let note = "Tesseract reader, eng+" + tessPacks.joined(separator: "+")
                + (missing.isEmpty ? "" : " (no \(missing.joined(separator: ", ")) pack here)")
            runs.append(Self.run(Job(name: "tesseract", reader: .tesseract, packs: tessPacks, note: note),
                                 settings: settings(.tesseract, tessPacks), source: sourceDoc, pages: pages, work: work))
        }

        // Sanity: three pages with no degradation, through Vision English.
        var sanity: [String: Any] = [:]
        let sanityPages = [pages[0], pages[5], pages[9]]
        let cleanPDF = work.appendingPathComponent("clean.pdf")
        Self.writePDF(sanityPages.map { ($0.rendered.image, $0.spec.size) }, to: cleanPDF)
        if let cleanDoc = PDFDocument(url: cleanPDF) {
            sanity = Self.run(Job(name: "vision-en-clean", reader: .apple, packs: [],
                                  note: "Pages \(sanityPages.map { $0.spec.number }) without degradation"),
                              settings: settings(.apple, []), source: cleanDoc, pages: sanityPages, work: work)
            sanity["pages"] = nil
        }

        // Output.
        let tessVersion = executable.map(Self.tesseractVersion) ?? "none"
        let report: [String: Any] = [
            "label": HCEnv.label,
            "generated": ISO8601DateFormatter().string(from: Date()),
            "pageCount": pages.count,
            "truthChars": pages.reduce(0) { $0 + HCScore.normalize($1.truth).unicodeScalars.count },
            "fonts": Dictionary(pages.map { ($0.spec.family, $0.rendered.fonts) }, uniquingKeysWith: { a, _ in a }),
            "tesseract": tessVersion,
            "tessdataFound": packs.sorted(),
            "truthDriftPages": drift,
            "wallSeconds": Self.rounded(Date().timeIntervalSince(wall)),
            "runs": runs,
            "sanityClean": sanity,
        ]
        let outDir = URL(fileURLWithPath: dir).appendingPathComponent("results/\(HCEnv.label)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outDir.appendingPathComponent("ocr.json"))

        for run in runs + [sanity] where !run.isEmpty {
            print("HCOCR " + Self.line(run))
        }
        print("HCOCR wrote \(outDir.appendingPathComponent("ocr.json").path) in \(Int(Date().timeIntervalSince(wall))) s")
    }

    static func line(_ run: [String: Any]) -> String {
        let name = (run["name"] as? String ?? "?").padding(toLength: 18, withPad: " ", startingAt: 0)
        guard run["status"] as? String == "ok", let s = run["summary"] as? [String: Any] else {
            return "\(name) \(run["status"] as? String ?? "?"): \(run["reason"] as? String ?? "")"
        }
        func pct(_ k: String) -> String { (s[k] as? Double).map { String(format: "%6.2f%%", $0 * 100) } ?? "   n/a "}
        func num(_ k: String) -> String { (s[k] as? Double).map { String(format: "%.3f", $0) } ?? "n/a" }
        return "\(name) CER \(pct("cer")) WER \(pct("wer")) greekCER \(pct("greekCER")) latinCER \(pct("latinCER")) "
            + "order \(num("order")) recall \(num("chunkRecall")) "
            + String(format: "%.2f s/page", run["secondsPerPage"] as? Double ?? 0)
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.4) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
