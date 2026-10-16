import Testing
import Foundation
import AppKit
import PDFKit
@testable import PDFCropper

@Suite("Rendering and image processing")
struct RenderingTests {

    @Test("Pages render as a viewer shows them: crop box and every rotation",
          arguments: [0, 90, 180, 270])
    func rendersLikeAViewer(rotation: Int) throws {
        let cropped = Fixtures.markedPage()
        cropped.setBounds(CGRect(x: 100, y: 100, width: 400, height: 700), for: .cropBox)
        for page in [Fixtures.markedPage(), cropped] {
            page.rotation = rotation
            let ours = try #require(PDFRenderer.renderCGImage(page: page, dpi: 72))
            let size = PDFRenderer.displaySize(of: page)
            #expect(abs(Double(ours.width) - size.width) <= 1 && abs(Double(ours.height) - size.height) <= 1)
            let reference = try #require(page.thumbnail(of: NSSize(width: size.width, height: size.height), for: .cropBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil))
            #expect(Fixtures.difference(ours, reference) < 1.0)
        }
    }

    @Test("Straightening one half of a spread never pulls in the facing page")
    func spreadHalvesDoNotBleed() {
        // Left page white, right page solid black.
        let spread = Fixtures.image(2000, 1500) { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 1000, y: 0, width: 1000, height: 1500))
        }
        let composite = ImageTransform.deskewedComposite(spread, splitX: 0.5, leftDegrees: 3,
                                                         rightDegrees: 0, isSpread: true)
        #expect(composite.width == 2000 && composite.height == 1500)
        let g = GrayBuffer(cgImage: composite, maxDim: 2000)!
        var dark = 0
        for y in 0..<g.height { for x in 0..<(g.width / 2 - 1) where g.value(x, y) < 128 { dark += 1 } }
        #expect(dark == 0)
    }

    @Test("Gray detection: plain pages are gray, a small red mark keeps color")
    func grayDetection() {
        let bars: (CGContext) -> Void = { c in
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            for i in 0..<40 { c.fill(CGRect(x: 200, y: 200 + i * 60, width: 1600, height: 12)) }
        }
        #expect(ImageEnhancer.isEffectivelyGray(Fixtures.image(2000, 3000, bars)))
        let marked = Fixtures.image(2000, 3000) { c in
            bars(c)
            c.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
            c.fill(CGRect(x: 300, y: 2700, width: 50, height: 50))
        }
        #expect(!ImageEnhancer.isEffectivelyGray(marked))
    }

    @Test("Scan resolution is measured at the size the page draws the scan")
    func scanResolution() throws {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        func dpis(_ url: URL) throws -> [Double?] {
            let doc = try #require(PDFDocument(url: url))
            return (0..<doc.pageCount).map { PDFRenderer.scanDPI(of: doc.page(at: $0)!).map { $0.rounded() } }
        }

        // 300 DPI scan inside an 8.5x11 in crop box on a 17x22 in page.
        let inCrop = Fixtures.writePDF("dpi-crop.pdf", media: CGRect(x: 0, y: 0, width: 1224, height: 1584), pages: [
            { $0.draw(Fixtures.scan(2550, 3300), in: CGRect(x: 100, y: 100, width: 612, height: 792)) }])
        let doc = try #require(PDFDocument(url: inCrop))
        doc.page(at: 0)!.setBounds(CGRect(x: 100, y: 100, width: 612, height: 792), for: .cropBox)
        doc.write(to: inCrop)
        #expect(try dpis(inCrop) == [300])

        // The same scan drawn turned a quarter on a landscape page.
        let turned = Fixtures.writePDF("dpi-turned.pdf", media: CGRect(x: 0, y: 0, width: 792, height: 612), pages: [
            { c in c.translateBy(x: 792, y: 0); c.rotate(by: .pi / 2); c.draw(Fixtures.scan(2550, 3300), in: letter) }])
        #expect(try dpis(turned) == [300])

        // Two pages, each drawing only its own scan.
        let mixed = Fixtures.writePDF("dpi-mixed.pdf", media: letter, pages: [
            { $0.draw(Fixtures.scan(2550, 3300), in: letter) },
            { $0.draw(Fixtures.scan(5100, 6600), in: letter) }])
        #expect(try dpis(mixed) == [300, 600])

        // Squeezed: 150 DPI across but 600 DPI down -> the sharper axis.
        let squeezed = Fixtures.writePDF("dpi-squeezed.pdf", media: letter, pages: [
            { $0.draw(Fixtures.scan(1275, 6600), in: letter) }])
        #expect(try dpis(squeezed) == [600])

        // One banner drawn six times over the same strip is not a page scan.
        let banner = Fixtures.writePDF("dpi-banner.pdf", media: letter, pages: [
            { c in let b = Fixtures.scan(5100, 660); for _ in 0..<6 { c.draw(b, in: CGRect(x: 0, y: 713, width: 612, height: 79)) } }])
        #expect(try dpis(banner) == [nil])
    }
}
