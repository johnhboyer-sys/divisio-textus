import Foundation
import CoreGraphics

/// A rectangle stored in normalized coordinates [0,1] relative to the full
/// source page, with the origin at the TOP-LEFT (image convention).
/// Keeping crops normalized makes them resolution-independent: we can edit
/// against a low-res preview and apply against a full-res render at export.
struct CropRect: Equatable, Codable {
    var x: Double      // left edge, 0...1
    var y: Double      // top edge, 0...1
    var width: Double  // 0...1
    var height: Double // 0...1

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }

    /// Clamp into the unit square and keep a sane minimum size.
    mutating func normalize() {
        let minSize = 0.02
        width = max(minSize, min(width, 1))
        height = max(minSize, min(height, 1))
        x = max(0, min(x, 1 - width))
        y = max(0, min(y, 1 - height))
    }

    func normalized() -> CropRect {
        var c = self
        c.normalize()
        return c
    }

    /// This box at `reference`'s size (Match Sizes): the edge at the fold stays (a left
    /// page's right edge, a right page's left edge), the outer edge moves, and the top
    /// and bottom become the reference's. Kept within the page, or its trim `bounds`.
    func matched(to reference: CropRect, foldOnRight: Bool, within bounds: CropRect = .full) -> CropRect {
        var c = CropRect(x: x, y: reference.y, width: reference.width, height: reference.height)
        if foldOnRight {
            c.x = max(bounds.minX, maxX - reference.width)
            c.width = maxX - c.x
        } else {
            c.width = min(reference.width, bounds.maxX - x)
        }
        return c
    }

    /// This rect in `area`'s own coordinates (0…1 across it), as a view of just
    /// that part of the page shows it; `absolute(in:)` turns it back.
    func relative(to area: CropRect) -> CropRect {
        CropRect(x: (x - area.x) / area.width, y: (y - area.y) / area.height,
                 width: width / area.width, height: height / area.height)
    }

    func absolute(in area: CropRect) -> CropRect {
        CropRect(x: area.x + x * area.width, y: area.y + y * area.height,
                 width: width * area.width, height: height * area.height)
    }

    /// This rect cut to `bounds`. Along an axis where hardly any of it is inside, it
    /// is moved inside instead, at its own length or the bounds' if shorter.
    func kept(in bounds: CropRect) -> CropRect {
        // Already inside: exactly as it is (no rounding from rebuilding it).
        if minX >= bounds.minX, maxX <= bounds.maxX, minY >= bounds.minY, maxY <= bounds.maxY { return self }
        func axis(_ lo: Double, _ hi: Double, _ b0: Double, _ b1: Double) -> (Double, Double) {
            let a = max(lo, b0), z = min(hi, b1)
            if z - a >= min(0.02, b1 - b0) { return (a, z) }
            let length = min(max(hi - lo, 0.02), b1 - b0), start = max(b0, min(lo, b1 - length))
            return (start, start + length)
        }
        let (x0, x1) = axis(minX, maxX, bounds.minX, bounds.maxX), (y0, y1) = axis(minY, maxY, bounds.minY, bounds.maxY)
        return CropRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The smallest rect containing both.
    func union(_ other: CropRect) -> CropRect {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        return CropRect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }

    /// Convert to a pixel-space CGRect (top-left origin) for an image of the
    /// given pixel dimensions.
    func pixelRect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width,
               y: y * size.height,
               width: width * size.width,
               height: height * size.height)
    }

    /// Pixel size this crop would yield for a source of `size`.
    func pixelSize(in size: CGSize) -> CGSize {
        CGSize(width: width * size.width, height: height * size.height)
    }
}
