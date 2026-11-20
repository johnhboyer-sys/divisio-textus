import Testing
import Foundation
import PDFKit
@testable import PDFCropper

@Suite("Greek in the text layer")
struct GreekTextLayerTests {

    @Test("Polytonic Greek copies out of the exported page")
    func polytonicGreekSurvives() throws {
        let out = Fixtures.url("greek-\(UUID().uuidString).pdf")
        var page = CGRect(x: 0, y: 0, width: 400, height: 600)
        let ctx = try #require(CGContext(consumer: CGDataConsumer(url: out as CFURL)!, mediaBox: &page, nil))
        ctx.beginPage(mediaBox: &page)
        let lines = [
            OCRService.Line(text: "μῆνιν ἄειδε θεὰ Πηληϊάδεω Ἀχιλῆος", box: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.02)),
            OCRService.Line(text: "Aristotle writes τὸ τί ἦν εἶναι here", box: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.02)),
        ]
        PDFExporter.drawTextLayer(lines, in: ctx, pageSize: page.size, font: PDFExporter.makeTextLayerFont())
        ctx.endPage()
        ctx.closePDF()
        let text = try #require(PDFDocument(url: out)?.page(at: 0)?.string)
        let squeezed = text.precomposedStringWithCanonicalMapping
        #expect(squeezed.contains("μῆνιν ἄειδε θεὰ"), "got: \(text)")
        #expect(squeezed.contains("τὸ τί ἦν εἶναι"), "got: \(text)")
    }
}
