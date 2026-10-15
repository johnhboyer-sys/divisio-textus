import Foundation
import CoreGraphics
import AppKit

enum ImageTransform {
    /// Rotate a CGImage by `degrees` (positive = counter-clockwise), expanding
    /// the canvas so nothing is clipped and filling new corners with `fill`.
    /// Returns the input unchanged for ~0° to avoid needless resampling.
    static func rotate(_ image: CGImage, degrees: Double, fill: NSColor = .white) -> CGImage {
        guard abs(degrees) > 0.01 else { return image }

        let rad = degrees * .pi / 180
        let w = Double(image.width)
        let h = Double(image.height)
        let absCos = abs(cos(rad)), absSin = abs(sin(rad))
        let newW = max(1, Int((w * absCos + h * absSin).rounded()))
        let newH = max(1, Int((w * absSin + h * absCos).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: newW,
                                  height: newH,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        ctx.translateBy(x: CGFloat(newW) / 2, y: CGFloat(newH) / 2)
        ctx.rotate(by: CGFloat(rad))
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Rotate in place about a normalized pivot (top-left origin), keeping the
    /// original pixel dimensions. Corners that fall outside are filled with
    /// `fill`. Used to straighten one half of a spread around its own center so
    /// the result stays the same size and can be composited at the gutter.
    static func rotateInPlace(_ image: CGImage,
                              degrees: Double,
                              pivot: CGPoint,
                              fill: NSColor = .white) -> CGImage {
        guard abs(degrees) > 0.01 else { return image }
        let w = image.width, h = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext origin is bottom-left; pivot.y is top-left normalized.
        let px = pivot.x * Double(w)
        let py = (1 - pivot.y) * Double(h)
        ctx.translateBy(x: px, y: py)
        ctx.rotate(by: degrees * .pi / 180)
        ctx.translateBy(x: -px, y: -py)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Build the image the user crops on: each book page straightened by its own
    /// angle. For a spread, the left half (columns left of `splitX`) is rotated
    /// about its own center by `leftDegrees` and the right half by `rightDegrees`,
    /// then joined at the gutter. Output keeps the source dimensions so crop
    /// rectangles stay in one consistent coordinate space (preview == export).
    static func deskewedComposite(_ source: CGImage,
                                  splitX: Double,
                                  leftDegrees: Double,
                                  rightDegrees: Double,
                                  isSpread: Bool) -> CGImage {
        if !isSpread {
            return rotateInPlace(source, degrees: leftDegrees, pivot: CGPoint(x: 0.5, y: 0.5))
        }
        if abs(leftDegrees) < 0.01 && abs(rightDegrees) < 0.01 { return source }

        let w = source.width, h = source.height
        let splitPx = max(1, min(w - 1, Int(splitX * Double(w))))

        let leftRot = rotateInPlace(source, degrees: leftDegrees,
                                    pivot: CGPoint(x: splitX / 2, y: 0.5))
        let rightRot = rotateInPlace(source, degrees: rightDegrees,
                                     pivot: CGPoint(x: (splitX + 1) / 2, y: 0.5))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return source
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Left columns from the left-rotated image, right columns from the right.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: splitPx, height: h))
        ctx.draw(leftRot, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
        ctx.saveGState()
        ctx.clip(to: CGRect(x: splitPx, y: 0, width: w - splitPx, height: h))
        ctx.draw(rightRot, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
        return ctx.makeImage() ?? source
    }
}
