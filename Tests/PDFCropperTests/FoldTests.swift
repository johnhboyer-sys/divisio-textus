import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFCropper

/// Whole page: a page runs on into the fold, so a crease or shade near it
/// doesn't make the page narrower than the book's size.
@Suite("Whole page: the fold", .serialized)
@MainActor
struct FoldTests {

    /// Twelve spreads of two 6 × 9 in sheets on a black bed (14 × 10 in scans),
    /// meeting at a black fold, where the split is found; the left page has a
    /// crease down it 20 pt from the fold.
    struct Book {
        static let media = CGRect(x: 0, y: 0, width: 1008, height: 720)
        static let sheetW = 432.0, sheetH = 648.0, top = 36.0
        static let shifts: [Double] = [0, 6, -5, 3, -8, 2, 0, -3, 7, -6, 0, 4]

        static func fold(_ i: Int) -> Double { 504 + shifts[i] }

        static func write() -> URL {
            let pages: [(CGContext) -> Void] = (0..<12).map { i in { c in draw(i, c) } }
            return Fixtures.writePDF("fold-\(UUID().uuidString).pdf", media: media, pages: pages)
        }

        private static func draw(_ i: Int, _ c: CGContext) {
            let H = media.height
            func fill(_ gray: Double, _ x: Double, _ yTop: Double, _ w: Double, _ h: Double) {
                c.setFillColor(CGColor(gray: gray, alpha: 1))
                c.fill(CGRect(x: x, y: H - yTop - h, width: w, height: h))
            }
            fill(0.04, 0, 0, media.width, H)
            let f = fold(i)
            fill(1, f - sheetW, top, 2 * sheetW, sheetH)
            fill(0.04, f - 2, top, 4, sheetH)
            fill(0.3, f - 22, top, 3, sheetH)              // a crease
            for t in text(i) {
                var y = t.minY
                while y + 6 <= t.maxY { fill(0.1, t.minX, y, t.width, 6); y += 14 }
            }
        }

        /// Each page's lines of type, in points from the scan's top left.
        static func text(_ i: Int) -> [CGRect] {
            let f = fold(i)
            let rows = (top + 54, top + 54 + 14 * floor((sheetH - 121) / 14) + 6)   // the first line's top, the last's bottom
            return [(f - sheetW + 54, f - 54), (f + 54, f + sheetW - 54)].map { x0, x1 in
                CGRect(x: x0, y: rows.0, width: x1 - x0, height: rows.1 - rows.0)
            }
        }
    }

    @Test("A crease by the fold doesn't narrow the page: it runs on into the fold, and gets the book's size")
    func creaseByFold() async throws {
        let m = testModel()
        m.setCropTarget(.page)
        m.load(url: Book.write())
        await waitUntilIdle(m)
        let W = Book.media.width, H = Book.media.height
        for (i, p) in m.pages.enumerated() {
            for (side, crop, t) in [("left", p.leftCrop, Book.text(i)[0]), ("right", p.rightCrop, Book.text(i)[1])] {
                #expect(abs(crop.width * W - Book.sheetW) < 4.4, "spread \(i) \(side): \(crop.width * W) pt wide")
                #expect(crop.minX * W <= t.minX + 0.5 && crop.maxX * W >= t.maxX - 0.5 && crop.minY * H <= t.minY + 0.5 && crop.maxY * H >= t.maxY - 0.5,
                        "spread \(i) \(side): type at \(t), crop \(crop.minX * W)...\(crop.maxX * W) pt")
            }
        }
    }
}
