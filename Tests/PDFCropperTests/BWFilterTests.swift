import Testing
import Foundation
@testable import PDFCropper

/// LayeredScan's min and max filters (van Herk / Gil-Werman) give exactly what the
/// plain filter they replaced gave, edges and images narrower than the radius included.
@Suite("BW min and max filters")
struct BWFilterTests {

    /// The filter as it was: every pixel's window scanned in full, by rows then columns.
    static func reference(_ p: [UInt8], _ w: Int, _ h: Int, _ r: Int, _ pick: (UInt8, UInt8) -> UInt8) -> [UInt8] {
        var rows = p
        for y in 0..<h {
            for x in 0..<w {
                var v = p[y * w + x]
                for k in max(0, x - r)...min(w - 1, x + r) { v = pick(v, p[y * w + k]) }
                rows[y * w + x] = v
            }
        }
        var out = rows
        for y in 0..<h {
            for x in 0..<w {
                var v = rows[y * w + x]
                for k in max(0, y - r)...min(h - 1, y + r) { v = pick(v, rows[k * w + x]) }
                out[y * w + x] = v
            }
        }
        return out
    }

    @Test("Min and max match the plain filter on random images, at radii 1, 2, 10 and 25")
    func matchesReference() {
        var rng = HCRandom(41)
        let sizes = [(97, 61), (200, 3), (3, 150), (1, 1), (5, 7), (40, 40), (64, 2)]
        for (w, h) in sizes {
            // Noise, and a few flat patches, so runs of equal values are tried too.
            var p = (0..<(w * h)).map { _ in UInt8(rng.int(0, 255)) }
            for _ in 0..<3 {
                let x0 = rng.int(0, w - 1), y0 = rng.int(0, h - 1), v = UInt8(rng.int(0, 255))
                for y in y0..<min(h, y0 + 6) { for x in x0..<min(w, x0 + 9) { p[y * w + x] = v } }
            }
            for r in [1, 2, 10, 25] {
                #expect(LayeredScan.minFilter(p, w, h, radius: r) == Self.reference(p, w, h, r, min), "min \(w)x\(h) r \(r)")
                #expect(LayeredScan.maxFilter(p, w, h, radius: r) == Self.reference(p, w, h, r, max), "max \(w)x\(h) r \(r)")
            }
        }
    }
}
