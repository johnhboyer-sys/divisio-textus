import Foundation
import CoreGraphics
import AppKit

/// A small, downsampled 8-bit grayscale view of an image used for fast
/// column/row profiling (gutter + content-bounds detection). 0 = black, 255 = white.
struct GrayBuffer {
    init(width: Int, height: Int, pixels: [UInt8]) { self.width = width; self.height = height; self.pixels = pixels }
    let width: Int
    let height: Int
    let pixels: [UInt8]   // row-major, top-left origin

    func value(_ x: Int, _ y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    /// The paper's brightness in columns `xs` (all by default): the most common
    /// level among the pixels brighter than average. That is the paper whether
    /// the rest is a little ink, a wide black scanner band, or a white scanner lid
    /// around tinted stock; the single brightest pixel can be a white speck on
    /// yellowed paper, which would make the whole sheet read as ink.
    func paperLevel(columns xs: Range<Int>? = nil) -> Double {
        let xs = xs ?? 0..<width
        guard !xs.isEmpty, height > 0 else { return 255 }
        var hist = [Int](repeating: 0, count: 256)
        var sum = 0
        for y in 0..<height {
            for x in xs { let v = Int(pixels[y * width + x]); hist[v] += 1; sum += v }
        }
        let mean = sum / (height * xs.count)
        // Most common level at or above the mean, counting each level with its
        // neighbours (±8): grainy paper spreads over many levels, and a patch of
        // pure white (a scanner lid, a fill) must not outvote it on that alone.
        var best = 255, bestCount = -1
        var window = hist[max(0, mean - 8)...min(255, mean + 8)].reduce(0, +)
        for v in mean...255 {
            if v > mean {
                if v + 8 <= 255 { window += hist[v + 8] }
                if v - 9 >= 0 { window -= hist[v - 9] }
            }
            if window > bestCount { bestCount = window; best = v }
        }
        return Double(min(255, best))
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
