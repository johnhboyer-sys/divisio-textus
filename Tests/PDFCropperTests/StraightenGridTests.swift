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
        focus.hover(.right, inside: true)
        #expect(focus.side == .right)
        focus.beginDrag(.left)
        focus.hover(.right, inside: false)
        #expect(focus.side == .left)
    }

    @Test("A drag released outside its row hides the grid without a hover end")
    func releasedOutside() {
        var focus = StraightenFocus()
        focus.hover(.left, inside: true)
        focus.beginDrag(.left)
        focus.endDrag(.left, pointerInside: false)
        #expect(focus.side == nil)
    }

    @Test("A drag released on its row keeps the grid, even if the hover ended mid-drag")
    func releasedInside() {
        var focus = StraightenFocus()
        focus.hover(.left, inside: true)
        focus.beginDrag(.left)
        focus.hover(.left, inside: false)
        focus.endDrag(.left, pointerInside: true)
        #expect(focus.side == .left)
    }

    @Test("A row going away leaves the hover of the row now under the pointer")
    func rowSwap() {
        var focus = StraightenFocus()
        focus.hover(.left, inside: true)
        focus.hover(.angle, inside: true)
        focus.remove(.left)
        #expect(focus.side == .left)    // Angle turns the left box's page
        focus.remove(.angle)
        #expect(focus.side == nil)
    }

    @Test("A late hover end from one row leaves the next row's hover")
    func crossingRows() {
        var focus = StraightenFocus()
        focus.hover(.left, inside: true)
        focus.hover(.right, inside: true)
        focus.hover(.left, inside: false)
        #expect(focus.side == .right)
    }

    @Test("A row that goes mid-drag ends the drag")
    func removedMidDrag() {
        var focus = StraightenFocus()
        focus.beginDrag(.right)
        focus.remove(.right)
        #expect(focus.side == nil)
    }
}
