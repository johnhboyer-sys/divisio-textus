import Testing
import Foundation
import CoreGraphics
@testable import PDFCropper

/// Flatten pages on synthetic leaves (`HCSynth`, drawn at 330 DPI) warped with a known
/// curl into the gutter (`HillClimbFlattenTests.warp`).
@Suite("Flatten")
@MainActor
struct FlattenTests {

    /// A full text leaf of the first synthetic book, its gray pixels, and whether its gutter is on the right.
    static func leaf() -> (g: [UInt8], w: Int, h: Int, right: Bool)? {
        guard let item = HillClimbFlattenTests.synthLeaves().first,
              let scan = HCSynth.render(item.spec, .scan) else { return nil }
        let rect = item.spec.leaves[item.leaf].paper.integral
            .intersection(CGRect(x: 0, y: 0, width: item.spec.W, height: item.spec.H))
        guard let cut = scan.cropping(to: rect) else { return nil }
        return (HillClimb.gray(cut), cut.width, cut.height, item.leaf == 0)
    }

    static func image(_ g: [UInt8], _ w: Int, _ h: Int) -> CGImage {
        HillClimbFlattenTests.image(g, w, h)!
    }

    static func meanCurl(_ image: CGImage) -> (curl: Double, glyphs: [HCGlyph]) {
        let c = HillClimbFlattenTests.curl(image, dpi: HillClimbFlattenTests.synthDPI, gutterOnRight: nil)
        return (c.meanPt, c.glyphs)
    }

    @Test("The option is off by default, in the export settings and in the app")
    func offByDefault() {
        #expect(!PDFExporter.Settings().flattenPages)
        #expect(!HillClimb.makeModel().flattenPages)
    }

    @Test("A straight page is left as it is")
    func straightUnchanged() throws {
        let l = try #require(Self.leaf())
        let im = Self.image(l.g, l.w, l.h)
        #expect(Flatten.pages(im, regions: [(CGRect(x: 0, y: 0, width: l.w, height: l.h), l.right)]) == nil)
        #expect(Flatten.report(l.g, width: l.w, height: l.h, gutterOnRight: l.right).outcome == .straight)
    }

    @Test("A page curled into the gutter comes back straight, every glyph kept")
    func curledFlattened() throws {
        let l = try #require(Self.leaf())
        let wp = HillClimbFlattenTests.Warp(band: 0.4, tilt: 30, drop: 10, squash: 0)
        let warped = HillClimbFlattenTests.warp(l.g, l.w, l.h, wp, gutterOnRight: l.right)
        let im = Self.image(warped, l.w, l.h)
        let flat = try #require(Flatten.pages(im, regions: [(CGRect(x: 0, y: 0, width: l.w, height: l.h), l.right)])?.image)
        #expect(flat.width == l.w && flat.height == l.h)
        let before = Self.meanCurl(im), after = Self.meanCurl(flat)
        #expect(after.curl < 0.4 * before.curl, "curl \(before.curl) -> \(after.curl) pt")
        let rep = Flatten.report(warped, width: l.w, height: l.h, gutterOnRight: l.right)
        let check = HillClimbFlattenTests.printCheck(before: im, after: flat, glyphsBefore: before.glyphs,
                                                     glyphsAfter: after.glyphs, model: rep.model)
        #expect(check.lost.isEmpty && check.merged.isEmpty, "lost \(check.lost.count), merged \(check.merged.count)")
    }

    @Test("Text too small to trace is left as it is")
    func tooSmall() throws {
        let l = try #require(Self.leaf())
        // A quarter the size: about 3 px letters.
        let w = l.w / 4, h = l.h / 4
        var g = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h { for x in 0..<w { g[y * w + x] = l.g[(4 * y) * l.w + 4 * x] } }
        #expect(Flatten.pages(Self.image(g, w, h), regions: [(CGRect(x: 0, y: 0, width: w, height: h), nil)]) == nil)
    }

    @Test("A blank page is left as it is")
    func blank() {
        let g = [UInt8](repeating: 230, count: 400 * 600)
        #expect(Flatten.pages(Self.image(g, 400, 600), regions: [(CGRect(x: 0, y: 0, width: 400, height: 600), nil)]) == nil)
    }
}
