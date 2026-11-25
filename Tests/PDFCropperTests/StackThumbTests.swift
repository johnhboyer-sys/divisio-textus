import Testing
import Foundation
import AppKit
import PDFKit
@testable import PDFCropper

@Suite("Stack thumbnails")
struct StackThumbTests {
    @Test("A stack thumbnail shows its own page's crop: left page left, right page right")
    func cropRect() {
        let left = CropRect(x: 0.05, y: 0.08, width: 0.40, height: 0.80)
        let right = CropRect(x: 0.55, y: 0.10, width: 0.38, height: 0.78)
        let page = BookPage(sourceIndex: 3, classification: .spread, splitX: 0.5, leftCrop: left, rightCrop: right)
        #expect(StackThumbList.cropRect(for: .init(page: page, side: .left)) == left)
        #expect(StackThumbList.cropRect(for: .init(page: page, side: .right)) == right)
        #expect(StackThumbList.cropRect(for: .init(page: page, side: .single)) == left)
    }

    @Test("Cutting a thumbnail keeps only the crop")
    func cutting() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = try #require(rep.cgImage)
        let piece = try #require(StackThumbList.cropped(image, to: CropRect(x: 0.5, y: 0, width: 0.4, height: 1)))
        let cg = try #require(piece.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.width == 40 && cg.height == 50)
    }

    @Test("A tilted page's thumbnail is cut from the page straightened, as its crop was drawn")
    @MainActor
    func straightened() throws {
        // A square page with a black bar down the middle, turned 10° in the editor: at the
        // top the straightened bar sits well off the middle of a narrow crop there.
        let url = Fixtures.writePDF("stack-thumb-tilt", media: CGRect(x: 0, y: 0, width: 1000, height: 1000), pages: [{ c in
            c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
            c.setFillColor(.black); c.fill(CGRect(x: 490, y: 0, width: 20, height: 1000))
        }])
        let m = testModel()
        m.document = PDFDocument(url: url)
        let crop = CropRect(x: 0.4, y: 0.02, width: 0.2, height: 0.08)
        var page = BookPage(sourceIndex: 0, classification: .single, leftCrop: crop, analyzed: true)
        page.leftSkew = 10
        m.pages = [page]
        let img = try #require(StackThumbList.image(for: .init(page: page, side: .single), in: m))
        let cg = try #require(img.cgImage(forProposedRect: nil, context: nil, hints: nil))
        // The darkest column's distance from the middle, as a share of the crop's width.
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let sums = (0..<w).map { x in (0..<h).reduce(0) { $0 + Int(px[$1 * w + x]) } }
        let darkest = try #require(sums.indices.min { sums[$0] < sums[$1] })
        let off = abs(Double(darkest) + 0.5 - Double(w) / 2) / Double(w)
        #expect(off > 0.25, "bar \(off) of the crop's width from its middle; unstraightened it sits on it")
    }
}
