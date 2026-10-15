import Foundation
import CoreGraphics
import AppKit

/// A small, downsampled 8-bit grayscale view of an image used for fast
/// column/row profiling (gutter + content-bounds detection). 0 = black, 255 = white.
struct GrayBuffer {
    let width: Int
    let height: Int
    let pixels: [UInt8]   // row-major, top-left origin

    func value(_ x: Int, _ y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    /// Average brightness of a single column (0 = black).
    func columnMean(_ x: Int) -> Double {
        var sum = 0
        for y in 0..<height { sum += Int(pixels[y * width + x]) }
        return Double(sum) / Double(height)
    }

    /// Build from a CGImage, downsampling so the longest side is `maxDim`.
    init?(cgImage: CGImage, maxDim: Int = 800) {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW > 0, srcH > 0 else { return nil }

        let scale = Double(maxDim) / Double(max(srcW, srcH))
        let w = max(1, Int((Double(srcW) * min(1, scale)).rounded()))
        let h = max(1, Int((Double(srcH) * min(1, scale)).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: w,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }

        // A CGBitmapContext stores row 0 at the top, matching the source
        // CGImage's top-left orientation, so read the buffer as-is. (No flip:
        // flipping here vertically mirrored content-bounds detection.)
        let raw = data.bindMemory(to: UInt8.self, capacity: w * h)
        self.width = w
        self.height = h
        self.pixels = Array(UnsafeBufferPointer(start: raw, count: w * h))
    }
}
