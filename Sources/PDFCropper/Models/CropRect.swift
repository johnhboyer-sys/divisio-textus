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
