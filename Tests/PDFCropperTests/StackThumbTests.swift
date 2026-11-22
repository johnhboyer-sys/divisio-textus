import Testing
import Foundation
import AppKit
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
        let image = NSImage(size: NSSize(width: 100, height: 50))
        image.addRepresentation(rep)
        let piece = try #require(StackThumbList.cropped(image, to: CropRect(x: 0.5, y: 0, width: 0.4, height: 1)))
        let cg = try #require(piece.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.width == 40 && cg.height == 50)
    }
}
