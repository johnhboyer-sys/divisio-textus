import Testing
import Foundation
import CoreGraphics
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

    // MARK: - Word vote

    private func row(_ text: String) -> [OCRService.Line] {
        [OCRService.Line(text: text, box: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.02))]
    }
    private let misspelled: Set<String> = ["carth", "cxrth", "specity", "ScriptureiLet", "quâ", "tz", "elec"]
    private func isWord(_ s: String) -> Bool {
        !misspelled.contains(s.trimmingCharacters(in: .punctuationCharacters.union(.symbols)))
    }

    @Test("A word the first pass misread takes the second pass's spelling")
    func misreadReplaced() {
        // Cherniss 1935, Wallace 1957 and Oesterle 1955, read by both passes.
        let cases = [("according to some the carth", "according to some the earth"),
                     ("In order to specity this notation", "In order to specify this notation"),
                     ("when it is said in ScriptureiLet us make man", "when it is said in Scripture \"Let us make man")]
        for (first, second) in cases {
            #expect(OCRService.correct(row(first), with: row(second), isWord: isWord).map(\.text) == [second])
        }
    }

    @Test("Accents, short marks, and words both passes misread stay as first read")
    func votesKept() {
        let cases = [("So the whole sky, quâ", "So the whole sky, qua"),     // printed quâ
                     ("tz in the plane", "t in the plane"),                  // printed t₂
                     ("the carth moves", "the cxrth moves"),                 // second pass no better
                     ("the earth moves", "the carth moves"),                 // first pass already right
                     ("Static elec-", "Static elect"),                       // broken at the line's end
                     ("\"carth\" 1957", "earth 1935")]                     // numbers differ
        for (first, second) in cases {
            #expect(OCRService.correct(row(first), with: row(second), isWord: isWord).map(\.text) == [first], "\(first)")
        }
    }

    @Test("Only the line on the same row votes")
    func otherRowIgnored() {
        let below = [OCRService.Line(text: "according to some the earth", box: CGRect(x: 0.1, y: 0.45, width: 0.8, height: 0.02))]
        #expect(OCRService.correct(row("according to some the carth"), with: below, isWord: isWord).map(\.text)
                == ["according to some the carth"])
    }

    @Test("A second-pass line votes only on its nearest row")
    func nearestRowVotes() {
        // A tall first-pass box whose row reaches the next line's.
        let tall = OCRService.Line(text: "the carth", box: CGRect(x: 0.1, y: 0.49, width: 0.8, height: 0.04))
        let next = OCRService.Line(text: "the carth", box: CGRect(x: 0.1, y: 0.485, width: 0.8, height: 0.02))
        let second = [OCRService.Line(text: "the earth", box: CGRect(x: 0.1, y: 0.487, width: 0.8, height: 0.02))]
        #expect(OCRService.correct([tall, next], with: second, isWord: isWord).map(\.text) == ["the carth", "the earth"])
    }

    @Test("The spell checker flags misreads, not numbers")
    func spelling() {
        #expect(!OCRService.spelledRight("specity", languages: ["en-US"]))
        #expect(OCRService.spelledRight("specify,", languages: ["en-US"]))
        #expect(OCRService.spelledRight("1957", languages: ["en-US"]))
    }
}
