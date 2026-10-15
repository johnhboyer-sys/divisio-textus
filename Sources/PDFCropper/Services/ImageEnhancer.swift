import Foundation
import CoreImage
import CoreGraphics

/// Converts a page image to grayscale (a plain desaturation — no contrast,
/// brightness, or sharpening) when requested. Geometry is preserved, so crop
/// rectangles still map 1:1.
enum ImageEnhancer {

    private static let context = CIContext(options: nil)

    /// True when a color image holds only grays — a black-and-white or grayscale
    /// scan stored as RGB. Checked on a reduced copy; tinted paper (sepia,
    /// yellowed) counts as color, and so does any small colored mark (a red
    /// stamp or rubric), so color is kept whenever the page really has some.
    static func isEffectivelyGray(_ image: CGImage) -> Bool {
        if image.colorSpace?.model == .monochrome { return true }
        let w = min(400, image.width), h = max(1, image.height * w / max(1, image.width))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var colored = 0
        for i in 0..<(w * h) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            if max(abs(r - g), abs(g - b), abs(r - b)) > 12 { colored += 1 }
        }
        return colored * 20000 < w * h   // under 0.005%: stray noise, not a mark
    }

    static func apply(_ image: CGImage, mode: EnhanceMode) -> CGImage {
        switch mode {
        case .color:
            return image
        case .grayscale:
            let ci = CIImage(cgImage: image)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            let gray = CGColorSpaceCreateDeviceGray()
            return context.createCGImage(ci, from: ci.extent, format: .L8, colorSpace: gray) ?? image
        }
    }
}
