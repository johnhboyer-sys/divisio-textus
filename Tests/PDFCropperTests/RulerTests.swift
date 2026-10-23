import Testing
import Foundation
import PDFKit
@testable import PDFCropper

/// The rulers' ticks: real page size (72 points to the inch), in the Mac's units,
/// spaced to stay readable at any zoom and placed where the page is drawn.
@Suite("Rulers")
struct RulerTests {

    @Test("Units follow the Mac's measurement setting")
    func unitsFromLocale() {
        #expect(RulerUnit(locale: Locale(identifier: "en_US")) == .inches)
        #expect(RulerUnit(locale: Locale(identifier: "fr_FR")) == .centimeters)
        #expect(RulerUnit(locale: Locale(identifier: "en_GB")) == .centimeters)
        #expect(RulerUnit(locale: Locale(identifier: "en_US@measure=metric")) == .centimeters)
        #expect(RulerUnit.inches.points == 72)
        #expect(abs(RulerUnit.centimeters.points - 72 / 2.54) < 1e-9)
    }

    @Test("A letter page at 1 screen point per PDF point: eighths, half inches, inch labels")
    func letterAtActualSize() {
        let scale = RulerScale(unit: .inches, screenPerPoint: 1)
        #expect(scale.tickStep == 0.125)
        #expect(scale.labelStep == 1)
        let ticks = scale.ticks(length: 612, origin: 0)
        #expect(ticks.count == 69)                                // 0 to 8.5 in, every 1/8
        #expect(ticks.allSatisfy { abs($0.position.truncatingRemainder(dividingBy: 9)) < 1e-9 })
        #expect(ticks.compactMap(\.label) == (0...8).map(String.init))
        let labelled: [Double] = ticks.filter { $0.label != nil }.map(\.position)
        let inches: [Double] = (0...8).map { Double($0) * 72 }
        #expect(labelled == inches)
        #expect(ticks[0].size == .long)
        #expect(ticks[4].size == .medium)                         // half inch
        #expect(ticks[1].size == .short)
        #expect(ticks[8].size == .long)
        #expect(ticks.last?.position == 612)
    }

    @Test("Zoomed out, ticks and labels thin out to stay readable")
    func zoomedOut() {
        let scale = RulerScale(unit: .inches, screenPerPoint: 0.25)   // an inch is 18 points
        #expect(scale.labelStep == 2)
        #expect(scale.tickStep == 0.5)
        let ticks = scale.ticks(length: 612, origin: 0)
        #expect(ticks.compactMap(\.label) == ["0", "2", "4", "6", "8"])
        let labelled: [Double] = ticks.filter { $0.label != nil }.map(\.position)
        #expect(labelled == [0, 36, 72, 108, 144])
        #expect(ticks.first { $0.position == 18 }?.size == .medium)  // 1 in
        #expect(ticks.first { $0.position == 9 }?.size == .short)    // 1/2 in
    }

    @Test("Zoomed in, sixteenths appear")
    func zoomedIn() {
        let scale = RulerScale(unit: .inches, screenPerPoint: 8)
        #expect(scale.tickStep == 0.0625)
        #expect(scale.labelStep == 1)
        let positions: [Double] = scale.ticks(length: 72, origin: 0).map(\.position)
        let sixteenths: [Double] = (0...16).map { Double($0) * 36 }
        #expect(positions == sixteenths)
    }

    @Test("Centimetres: millimetre ticks with whole-centimetre labels when there is room")
    func centimetres() {
        let scale = RulerScale(unit: .centimeters, screenPerPoint: 2)  // a centimetre is 56.7 points
        #expect(scale.tickStep == 0.1)
        #expect(scale.labelStep == 1)
        let ticks = scale.ticks(length: 72 / 2.54 * 3, origin: 0)
        #expect(ticks.count == 31)
        #expect(ticks.compactMap(\.label) == ["0", "1", "2", "3"])
        #expect(ticks[5].size == .medium)                         // 5 mm
        #expect(ticks[1].size == .short)
        #expect(abs(ticks[10].position - 72 / 2.54 * 2) < 1e-9)

        let small = RulerScale(unit: .centimeters, screenPerPoint: 0.5) // 14.2 points
        #expect(small.labelStep == 2)
        #expect(small.tickStep == 0.5)
    }

    @Test("Ticks start at the page's drawn edge, wherever scrolling puts it")
    func origin() {
        let scale = RulerScale(unit: .inches, screenPerPoint: 1.5)
        let ticks = scale.ticks(length: 144, origin: -250)
        #expect(ticks.first?.position == -250)
        #expect(ticks.last?.position == -250 + 144 * 1.5)
        #expect(ticks.first { $0.label == "1" }?.position == -250 + 108)
    }

    @Test("Empty or broken sizes give no ticks, without hanging")
    func degenerate() {
        #expect(RulerScale(unit: .inches, screenPerPoint: 0).ticks(length: 612, origin: 0).isEmpty)
        #expect(RulerScale(unit: .inches, screenPerPoint: .nan).ticks(length: 612, origin: 0).isEmpty)
        #expect(RulerScale(unit: .inches, screenPerPoint: 1).ticks(length: 0, origin: 0).count == 1)
        #expect(RulerScale(unit: .inches, screenPerPoint: 1).ticks(length: -5, origin: 0).isEmpty)
    }

    @Test("Stack rulers measure the PDF, not the rounded stack picture (Codex review)")
    func stackSize() throws {
        // A 612-point Letter spread split in half: each half is 306 points, which at
        // the stack's 30 pixels to the inch is 127.5 pixels, drawn as 128.
        let media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = Fixtures.writePDF("ruler-stack-\(UUID().uuidString).pdf", media: media,
                                    pages: [{ c in c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(media) }])
        let doc = try #require(PDFDocument(url: url))
        let stack = try #require(PageStack.groups(pages: [BookPage(sourceIndex: 0, analyzed: true)]).first { $0.id == .left })
        let size = try #require(StackRenderer.pointSize(of: stack, in: doc))
        #expect(abs(size.width - 306) < 1e-9)
        #expect(abs(size.height - 792) < 1e-9)
        let image = try #require(StackRenderer.render(stack, from: doc))
        #expect(image.width == 128)
        #expect(image.height == 330)
    }

    @Test("Crop sizes read in the ruler's unit, in the Mac's number format")
    func sizeLabels() {
        let us = Locale(identifier: "en_US"), fr = Locale(identifier: "fr_FR")
        #expect(RulerUnit.inches.label(points: 442, locale: us) == "6.14 in")
        #expect(RulerUnit.inches.label(points: 612, locale: us) == "8.50 in")
        #expect(RulerUnit.centimeters.label(points: 72 / 2.54 * 21.04, locale: fr) == "21,0 cm")
        #expect(RulerUnit.centimeters.label(points: 72 / 2.54 * 9.96, locale: us) == "10.0 cm")
    }

    @Test("One box: its size alone")
    func readoutSingle() {
        let r = CropSizeReadout(left: CGSize(width: 442, height: 648), right: nil, unit: .inches, locale: Locale(identifier: "en_US"))
        #expect(r.sizes == ["6.14 × 9.00 in"])
        #expect(r.verdict == nil)
        #expect(r.same == nil)
    }

    @Test("Two boxes within one export pixel are the same size")
    func readoutSame() {
        #expect(CropSizeReadout.tolerance == 72.0 / 150)
        let r = CropSizeReadout(left: CGSize(width: 442, height: 648), right: CGSize(width: 442.4, height: 647.7),
                                unit: .inches, locale: Locale(identifier: "en_US"))
        #expect(r.sizes == ["Left 6.14 × 9.00 in", "Right 6.14 × 9.00 in"])
        #expect(r.verdict == "Same size")
        #expect(r.same == true)
    }

    @Test("Two boxes that differ say by how much, relative to the left")
    func readoutDiffer() {
        let us = Locale(identifier: "en_US")
        let wider = CropSizeReadout(left: CGSize(width: 442, height: 648), right: CGSize(width: 443.44, height: 648),
                                    unit: .inches, locale: us)
        #expect(wider.verdict == "Right is 0.02 in wider")
        #expect(wider.same == false)
        let both = CropSizeReadout(left: CGSize(width: 442, height: 648), right: CGSize(width: 435, height: 655.2),
                                   unit: .inches, locale: us)
        #expect(both.verdict == "Right is 0.10 in narrower and 0.10 in taller")
        // Just over the tolerance still shows a non-zero difference in centimetres.
        let cm = CropSizeReadout(left: CGSize(width: 300, height: 600), right: CGSize(width: 300.5, height: 600),
                                 unit: .centimeters, locale: Locale(identifier: "fr_FR"))
        #expect(cm.verdict == "Right is 0,02 cm wider")
        #expect(cm.sizes == ["Left 10,58 × 21,17 cm", "Right 10,60 × 21,17 cm"])
    }

    @Test("Sizes that differ never print the same (Codex review)")
    func readoutNoContradiction() {
        // 7.8167 and 7.8236 in both print 7.82; half a point apart, they aren't the same size.
        let r = CropSizeReadout(left: CGSize(width: 562.8, height: 648), right: CGSize(width: 563.3, height: 648),
                                unit: .inches, locale: Locale(identifier: "en_US"))
        #expect(r.same == false)
        #expect(r.sizes == ["Left 7.817 × 9.000 in", "Right 7.824 × 9.000 in"])
        #expect(r.verdict == "Right is 0.01 in wider")
        let taller = CropSizeReadout(left: CGSize(width: 562.8, height: 648), right: CGSize(width: 563.3, height: 660),
                                     unit: .inches, locale: Locale(identifier: "en_US"))
        #expect(taller.sizes == ["Left 7.817 × 9.000 in", "Right 7.824 × 9.167 in"])
    }

    @Test("Rulers start hidden, under a fixed defaults key")
    func toggleDefault() {
        #expect(Rulers.storageKey == "showsRulers")
        #expect(Rulers.shownByDefault == false)
        let defaults = UserDefaults(suiteName: "RulerTests-\(UUID().uuidString)")!
        #expect(Rulers.isShown(in: defaults) == false)
        defaults.set(true, forKey: Rulers.storageKey)
        #expect(Rulers.isShown(in: defaults) == true)
    }
}
