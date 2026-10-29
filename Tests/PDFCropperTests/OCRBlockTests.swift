import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import PDFCropper

/// Pages with side-by-side columns are OCR'd one column block at a time.
@Suite("OCR by column block")
struct OCRBlockTests {

    /// Two columns of serif text, each line drawn from its column's left edge.
    /// Returns the page and each line's text with its box (normalized, bottom-left).
    private func twoColumns(_ rows: [String]) -> (CGImage, [(String, CGRect)]) {
        let w = 1700, h = 2200, size: CGFloat = 30
        let font = CTFontCreateWithName("Times-Roman" as CFString, size, nil)
        var drawn: [(String, CGRect)] = []
        let image = Fixtures.image(w, h) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for (i, text) in rows.enumerated() {
                for x in [150.0, 900.0] {
                    let line = CTLineCreateWithAttributedString(
                        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
                    let y = 1900 - Double(i) * 44
                    c.textMatrix = .identity
                    c.textPosition = CGPoint(x: x, y: y)
                    CTLineDraw(line, c)
                    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                    drawn.append((text, CGRect(x: x / Double(w), y: (y - 8) / Double(h),
                                               width: width / Double(w), height: 34 / Double(h))))
                }
            }
        }
        return (image, drawn)
    }

    @Test("Words at a block's edge read right, and each line's box lands on its print")
    func edgeWords() throws {
        // Words Vision misread on Wallace 1957 when they began or ended a block.
        let rows = ["generally the forms", "it differs in kind", "we specify the cause", "phases of the moon",
                    "substance is first", "a type of motion", "the compound body", "generally it moves"]
        let (image, drawn) = twoColumns(rows)
        #expect(LayoutAnalyzer.columnBlocks(image).count > 1)
        let read = try #require(OCRService.recognizeLines(image))
        #expect(read.complete)
        #expect(read.lines.count == drawn.count, "\(read.lines.map(\.text))")
        for (text, box) in drawn {
            let hit = read.lines.first { $0.box.contains(CGPoint(x: box.midX, y: box.midY)) }
            #expect(hit?.text == text, "\(text) at \(box): \(hit.map { "\($0.text) \($0.box)" } ?? "nothing")")
            // The box covers its own print, not the gutter or the other column.
            if let hit {
                #expect(abs(hit.box.minX - box.minX) < 0.01 && abs(hit.box.maxX - box.maxX) < 0.01, "\(text): \(hit.box) vs \(box)")
            }
        }
    }

    @Test("A narrow column of item numbers stays with its text")
    func itemNumbers() throws {
        // Wallace 1957 numbers each syllogism ("3. Type D; ..."): the numbers form
        // a column too narrow to stand alone, and were dropped as a scanner sliver.
        let w = 1700, h = 2200
        let font = CTFontCreateWithName("Times-Roman" as CFString, 30, nil)
        let numberX = 150.0, textX = 215.0
        let image = Fixtures.image(w, h) { c in
            func draw(_ text: String, _ x: Double, _ y: Double) {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                c.textMatrix = .identity
                c.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, c)
            }
            for i in 0..<6 {
                let y = 1900 - Double(i) * 44
                draw("\(i + 2).", numberX, y)
                draw("Type D explicit", textX, y)
                draw("in Aristotle", 900, y)
            }
        }
        let blocks = LayoutAnalyzer.columnBlocks(image)
        #expect(blocks.count > 1)
        // One block holds the numbers and their text (it doesn't start at textX).
        #expect(blocks.contains { $0.minX * Double(w) < numberX + 20 && $0.maxX * Double(w) > textX + 100 }, "\(blocks)")
    }

    @Test("A dark scanner strip or mark beside a column is still left out", arguments: [350.0, 120.0])
    func scannerStrip(height: Double) {
        let w = 1700, h = 2200
        let font = CTFontCreateWithName("Times-Roman" as CFString, 30, nil)
        let image = Fixtures.image(w, h) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 100, y: 1950 - height, width: 15, height: height))   // as narrow as a column of numbers
            for i in 0..<8 {
                for x in [150.0, 900.0] {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "the cause of motion", attributes: [.font: font]))
                    c.textMatrix = .identity
                    c.textPosition = CGPoint(x: x, y: 1900 - Double(i) * 44)
                    CTLineDraw(line, c)
                }
            }
        }
        let blocks = LayoutAnalyzer.columnBlocks(image)
        #expect(blocks.count > 1)
        #expect(!blocks.contains { $0.minX * Double(w) < 140 }, "\(blocks)")
    }
}
