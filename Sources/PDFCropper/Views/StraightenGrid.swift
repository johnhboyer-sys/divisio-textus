import SwiftUI

/// Which Straighten row is in use, if any. The pointer can leave a row mid-drag, so
/// a drag counts until it ends and outranks the hover. Rows report in any order
/// when the pointer crosses or the rows swap, so each changes only its own claim.
struct StraightenFocus: Equatable {
    enum Row { case left, right, angle }

    private var hovered: Row?
    private var dragged: Row?

    var side: BookPage.Side? {
        guard let row = dragged ?? hovered else { return nil }
        return row == .right ? .right : .left
    }

    mutating func hover(_ row: Row, inside: Bool) {
        if inside { hovered = row } else if hovered == row { hovered = nil }
    }

    mutating func beginDrag(_ row: Row) { dragged = row }

    /// A drag hears no hover end, so its end says where the pointer is.
    mutating func endDrag(_ row: Row, pointerInside: Bool) {
        guard dragged == row else { return }
        dragged = nil
        hover(row, inside: pointerInside)
    }

    /// A row can go with the pointer still on it, and then hears no hover end.
    mutating func remove(_ row: Row) {
        hover(row, inside: false)
        if dragged == row { dragged = nil }
    }
}

/// Says where the pointer is when a drag ends, through a view behind each row.
final class StraightenRowProbes {
    fileprivate var views: [StraightenFocus.Row: NSView] = [:]

    func pointerIsOn(_ row: StraightenFocus.Row) -> Bool {
        guard let view = views[row], let window = view.window else { return false }
        return view.bounds.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}

struct StraightenRowProbe: NSViewRepresentable {
    let row: StraightenFocus.Row
    let probes: StraightenRowProbes

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probes.views[row] = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
