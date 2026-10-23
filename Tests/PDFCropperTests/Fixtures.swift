import Foundation
import AppKit
import PDFKit
import CoreGraphics
import CoreText
@testable import PDFCropper

/// Test PDFs are generated on the fly (or copied from the repo's sample book)
/// into a temporary folder, so the suite needs nothing outside the repo.
enum Fixtures {

    /// One temporary folder per test run. Saved edits are redirected here too,
    /// so tests never touch the user's real ones.
    static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DivisioTextusTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ProjectStore.directory = dir.appendingPathComponent("Edits", isDirectory: true)
        return dir
    }()

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The repo's synthetic sample book (1 single + 5 spreads, some skewed),
    /// copied with a unique trailer so each copy has its own saved-edits key.
    static func sampleBook() -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var data = try! Data(contentsOf: repo.appendingPathComponent("sample-book.pdf"))
        data.append(Data("\n%test-\(UUID().uuidString)\n".utf8))
        let copy = url("sample-\(UUID().uuidString).pdf")
        try! data.write(to: copy)
        return copy
    }

    /// An RGB image: white, with optional drawing.
    static func image(_ w: Int, _ h: Int, gray: Bool = false, _ draw: (CGContext) -> Void = { _ in }) -> CGImage {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: info)!
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(c)
        return c.makeImage()!
    }

    /// A gray "scan" with text-like bars.
    static func scan(_ w: Int, _ h: Int) -> CGImage {
        image(w, h, gray: true) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for i in 0..<30 { c.fill(CGRect(x: w / 10, y: h / 10 + i * h / 40, width: w * 8 / 10, height: max(1, h / 120))) }
        }
    }

    /// Write a PDF with Core Graphics; `pages` draws each page.
    static func writePDF(_ name: String, media: CGRect, pages: [(CGContext) -> Void]) -> URL {
        let out = url(name)
        var box = media
        let ctx = CGContext(consumer: CGDataConsumer(url: out as CFURL)!, mediaBox: &box, nil)!
        for draw in pages { ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage() }
        ctx.closePDF()
        return out
    }

    /// A portrait page with a marker in its top-left corner, so orientation and
    /// cropping show up when compared against PDFKit's own rendering.
    static func markedPage() -> PDFPage {
        let size = CGSize(width: 600, height: 900)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        NSColor.black.setFill()
        NSRect(x: 20, y: size.height - 120, width: 100, height: 100).fill()
        NSRect(x: 0, y: size.height - 8, width: size.width, height: 8).fill()
        for i in 0..<20 { NSRect(x: 60, y: 100 + CGFloat(i) * 30, width: size.width - 120, height: 10).fill() }
        img.unlockFocus()
        return PDFPage(image: img)!
    }

    /// Draw `text` as real, visible PDF text (as a born-digital or OCR'd PDF has it).
    static func drawText(_ text: String, in c: CGContext, at point: CGPoint, size: CGFloat = 18) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        c.textMatrix = .identity
        c.textPosition = point
        CTLineDraw(line, c)
    }

    /// The data of every image the page draws, also inside form objects, as
    /// stored in the file (a JPEG stays JPEG bytes), with its storage format.
    static func imageStreams(_ page: CGPDFPage) -> [(data: Data, format: CGPDFDataFormat)] {
        var found: [(Data, CGPDFDataFormat)] = []
        func walk(_ resources: CGPDFDictionaryRef, depth: Int) {
            var xobjects: CGPDFDictionaryRef?
            guard depth < 4, CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xo = xobjects else { return }
            CGPDFDictionaryApplyBlock(xo, { _, object, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let s = stream,
                      let dict = CGPDFStreamGetDictionary(s) else { return true }
                var subtype: UnsafePointer<CChar>?
                CGPDFDictionaryGetName(dict, "Subtype", &subtype)
                switch subtype.map({ String(cString: $0) }) {
                case "Image":
                    var format = CGPDFDataFormat.raw
                    if let data = CGPDFStreamCopyData(s, &format) { found.append((data as Data, format)) }
                case "Form":
                    var r: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dict, "Resources", &r), let r { walk(r, depth: depth + 1) }
                default: break
                }
                return true
            }, nil)
        }
        if let dict = page.dictionary {
            var r: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &r), let r { walk(r, depth: 0) }
        }
        return found
    }

    static func save(_ page: PDFPage, _ name: String, options: [PDFDocumentWriteOption: Any] = [:]) -> URL {
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        let out = url(name)
        doc.write(to: out, withOptions: options)
        return out
    }

    /// Mean absolute gray difference between two images at a small common size.
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let ga = GrayBuffer(cgImage: a, maxDim: 150)!, gb = GrayBuffer(cgImage: b, maxDim: 150)!
        guard ga.width == gb.width, ga.height == gb.height else { return .infinity }
        var sum = 0.0
        for i in 0..<ga.pixels.count { sum += abs(Double(ga.pixels[i]) - Double(gb.pixels[i])) }
        return sum / Double(ga.pixels.count)
    }
}

/// A model that saves into the test folder and never opens Finder.
@MainActor
func testModel(ocr: Bool = false) -> AppModel {
    _ = Fixtures.directory
    let m = AppModel()
    m.ocrEnabled = ocr
    m.revealExportInFinder = false
    m.setCropTarget(.text)   // most tests were written for text-block crops
    return m
}

/// Wait until analysis or export has finished. The timeout only stops a hang: a debug
/// build on a busy Mac can take several minutes over a book.
@MainActor
func waitUntilIdle(_ m: AppModel, timeout: TimeInterval = 600) async {
    let start = Date()
    while m.isBusy && Date().timeIntervalSince(start) < timeout {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Undo groups opened and closed explicitly, so tests don't depend on run-loop turns.
@MainActor
func undoable(_ undo: UndoManager, _ body: () -> Void) {
    undo.beginUndoGrouping(); body(); undo.endUndoGrouping()
}

@MainActor
func exportAndOpen(_ m: AppModel, _ name: String) async -> PDFDocument? {
    let out = Fixtures.url(name)
    try? FileManager.default.removeItem(at: out)
    m.export(to: out)
    await waitUntilIdle(m)
    return PDFDocument(url: out)
}

extension GrayBuffer {
    /// Feed this buffer to a function, so a test can build and analyze in one line.
    func pipe<T>(_ f: (GrayBuffer) -> T) -> T { f(self) }
}
