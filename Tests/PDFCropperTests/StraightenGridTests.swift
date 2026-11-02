import Testing
import CoreGraphics
@testable import PDFCropper

@Suite("Straighten grid")
struct StraightenGridTests {

    @Test("Lines fall evenly inside the box, without its edges")
    func evenAndInside() {
        let lines = StraightenGrid.lines(across: 320)
        #expect(lines == [32, 64, 96, 128, 160, 192, 224, 256, 288])
    }

    @Test("The last gap ends on the far edge, whatever the box's length")
    func fitsAnyLength() {
        for length: CGFloat in [100, 251.5, 613.25, 4000] {
            let lines = StraightenGrid.lines(across: length)
            let gap = length / CGFloat(lines.count + 1)
            #expect(abs(gap - StraightenGrid.spacing) <= StraightenGrid.spacing / 2)
            for (i, line) in lines.enumerated() {
                #expect(abs(line - gap * CGFloat(i + 1)) < 0.001)
            }
        }
    }

    @Test("Spacing on screen holds when the page is zoomed")
    func spacingHoldsAtZoom() {
        let atFit = StraightenGrid.lines(across: 640)
        let atZoom = StraightenGrid.lines(across: 640 * 8)
        #expect(abs((atFit[1] - atFit[0]) - (atZoom[1] - atZoom[0])) < 0.001)
        #expect(atZoom.count > atFit.count)
    }

    @Test("A box too small for a line draws none")
    func tinyBox() {
        #expect(StraightenGrid.lines(across: 0).isEmpty)
        #expect(StraightenGrid.lines(across: 30).isEmpty)
    }

    @Test("The grid sits on the crop box as the page view moves and resizes")
    func followsTheBox() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25)
        let r = StraightenGrid.viewRect(crop, in: CGRect(x: 30, y: 40, width: 800, height: 1200))
        #expect(r == CGRect(x: 110, y: 280, width: 400, height: 300))
    }

    @Test("A drag holds the grid on its side after the pointer leaves")
    func dragOutranksHover() {
        var focus = StraightenFocus()
        #expect(focus.side == nil)
        focus.hovered = .right
        #expect(focus.side == .right)
        focus.dragged = .left
        focus.hovered = nil
        #expect(focus.side == .left)
        focus.dragged = nil
        #expect(focus.side == nil)
    }
}
