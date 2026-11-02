import SwiftUI

/// Which page's Straighten control is in use, if any. The pointer can leave the
/// control mid-drag, so a drag counts until it ends and outranks the hover.
struct StraightenFocus: Equatable {
    var hovered: BookPage.Side?
    var dragged: BookPage.Side?

    var side: BookPage.Side? { dragged ?? hovered }
}

/// The lines over a crop box while its page is straightened by hand. They stay
/// put while the page turns beneath them, so type can be compared against them.
struct StraightenGrid: View {
    let crop: CropRect
    let imageFrame: CGRect

    var body: some View {
        let r = Self.viewRect(crop, in: imageFrame)
        // A pale line with a dark core: one or the other shows on any scan.
        StraightenGridLines()
            .stroke(.white.opacity(0.4), lineWidth: 1)
            .overlay(StraightenGridLines().stroke(.black.opacity(0.65), lineWidth: 0.5))
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }

    /// The same on screen at any zoom, so a line of type always has a grid line near
    /// it, and wide enough to leave large type readable.
    static let spacing: CGFloat = 32

    /// Where the lines fall across a box `length` long: evenly, from edge to edge,
    /// leaving out the edges themselves, which the box draws.
    static func lines(across length: CGFloat) -> [CGFloat] {
        let cells = Int((length / spacing).rounded())
        guard cells > 1 else { return [] }
        return (1..<cells).map { length * CGFloat($0) / CGFloat(cells) }
    }

    /// The crop box's place in the view, as CropBoxView draws it.
    static func viewRect(_ crop: CropRect, in imageFrame: CGRect) -> CGRect {
        CGRect(x: imageFrame.minX + crop.x * imageFrame.width,
               y: imageFrame.minY + crop.y * imageFrame.height,
               width: crop.width * imageFrame.width,
               height: crop.height * imageFrame.height)
    }
}

private struct StraightenGridLines: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            for x in StraightenGrid.lines(across: rect.width) {
                p.move(to: CGPoint(x: rect.minX + x, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX + x, y: rect.maxY))
            }
            for y in StraightenGrid.lines(across: rect.height) {
                p.move(to: CGPoint(x: rect.minX, y: rect.minY + y))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + y))
            }
        }
    }
}
