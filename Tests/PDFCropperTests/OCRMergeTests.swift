import Testing
import Foundation
@testable import PDFCropper

/// The two OCR passes (full and half size) are merged line by line. Boxes are
/// Vision-style: normalized, bottom-left origin.
@Suite("OCR two-pass merge")
struct OCRMergeTests {

    /// Tightly set lines whose boxes are taller than the gap between them (as on
    /// Wallace's pages): boxes overlap, which once made lines appear twice.
    private func tightLines(_ texts: [String], dy: Double = 0) -> [OCRService.Line] {
        texts.enumerated().map { i, t in
            OCRService.Line(text: t, box: CGRect(x: 0.2, y: 0.70 - Double(i) * 0.023 + dy, width: 0.77, height: 0.034))
        }
    }

    @Test("Overlapping line boxes never duplicate a line")
    func noDuplicates() {
        let texts = (1...12).map { "line number \($0) of the page" }
        let merged = OCRService.merge(tightLines(texts), tightLines(texts, dy: 0.001))
        #expect(merged.map(\.text).sorted() == texts.sorted())
    }

    @Test("A line Vision garbled from two rows is replaced by the two rows")
    func garbledMerge() {
        let pass1 = [OCRService.Line(text: "garbled two rows", box: CGRect(x: 0.2, y: 0.60, width: 0.77, height: 0.06))]
        let pass2 = [OCRService.Line(text: "upper row", box: CGRect(x: 0.2, y: 0.632, width: 0.77, height: 0.025)),
                     OCRService.Line(text: "lower row", box: CGRect(x: 0.2, y: 0.602, width: 0.77, height: 0.025))]
        #expect(OCRService.merge(pass1, pass2).map(\.text).sorted() == ["lower row", "upper row"])
    }

    @Test("A line the first pass dropped is recovered from the second")
    func droppedLine() {
        let pass1 = tightLines(["first", "second"])
        let pass2 = tightLines(["first", "second"]) + [OCRService.Line(text: "dropped", box: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.03))]
        #expect(OCRService.merge(pass1, pass2).map(\.text).sorted() == ["dropped", "first", "second"])
    }
}
