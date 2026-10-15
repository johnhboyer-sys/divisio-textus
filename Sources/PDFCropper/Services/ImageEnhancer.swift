import Foundation
import CoreImage
import CoreGraphics

/// Converts a page image to grayscale (a plain desaturation — no contrast,
/// brightness, or sharpening) when requested. Geometry is preserved, so crop
/// rectangles still map 1:1.
enum ImageEnhancer {

    private static let context = CIContext(options: nil)

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
