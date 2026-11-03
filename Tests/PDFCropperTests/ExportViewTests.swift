import Testing
import Foundation
import CoreGraphics
@testable import PDFCropper

/// The Export view's pages: made the export's way, from a small render.
@Suite("Export view preview", .serialized)
@MainActor
struct ExportViewTests {

    @Test("Each scan previews as many pages as it exports, shaped like its crops")
    func countsAndShapes() async throws {
        let m = testModel()
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        m.setOmittedSide(.left, for: m.pages[1].id)
        let total = m.pages.reduce(0) { $0 + m.outputPreview(for: $1).count }
        #expect(total == m.outputPageCount)
        let page = m.pages[2]
        let size = try #require(m.displaySize(of: page))
        let shown = m.outputPreview(for: page)
        for (image, crop) in zip(shown, page.outputCrops(direction: m.direction)) {
            let want = crop.width * size.width / (crop.height * size.height)
            #expect(abs(Double(image.width) / Double(image.height) - want) < 0.05)
        }
    }

    @Test("Grayscale shows gray, and a new reading order swaps a spread's pages")
    func followsSettings() async throws {
        let m = testModel()
        m.load(url: Fixtures.sampleBook()); await waitUntilIdle(m)
        let i = try #require(m.pages.firstIndex { $0.classification == .spread })
        let ltr = m.outputPreview(for: m.pages[i])
        m.direction = .rightToLeft
        let rtl = m.outputPreview(for: m.pages[i])
        #expect(ltr.count == 2 && rtl.count == 2)
        #expect(ltr[0].width == rtl[1].width && ltr[1].width == rtl[0].width)
        m.enhanceMode = .grayscale
        let gray = try #require(m.outputPreview(for: m.pages[i]).first)
        #expect(gray.colorSpace?.model == .monochrome)
    }
}
