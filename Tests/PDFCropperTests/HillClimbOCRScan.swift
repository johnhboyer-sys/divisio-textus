import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct HCScanLook {
    var angle: Double            // degrees; the page lies a little crooked
    var blur: Double = 0.9       // gaussian sigma in pixels at 300 dpi
    var noise: Double = 5        // gray levels, standard deviation
    var shadowSide = 0           // -1 left edge, +1 right edge, 0 none (a gutter shadow)
    var shadowStrength = 0.5
    var jpegQuality = 0.6
    var paperPhase = 0.0
    var seed: UInt64
}

enum HCScan {
    /// A clean page as a flatbed scan of a library book would show it: rotated,
    /// slightly soft, grainy, on uneven paper, perhaps with a gutter shadow, then
    /// stored as JPEG. The result is backed by that JPEG data, as a PDF would embed it.
    static func degrade(_ clean: HCRendered, look: HCScanLook) -> (image: CGImage, jpegBytes: Int) {
        let w = clean.image.width, h = clean.image.height
        var rng = HCRandom(seed: look.seed)

        // 1. Rotate on white.
        var buffer = [UInt8](repeating: 255, count: w * h)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            ctx.rotate(by: CGFloat(look.angle * .pi / 180))
            ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
            ctx.draw(clean.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // 2. Blur (separable gaussian, integer weights).
        let radius = max(1, Int((look.blur * 2).rounded(.up)))
        var weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * look.blur * look.blur)) }
        let total = weights.reduce(0, +)
        var ints = weights.map { Int(($0 / total * 256).rounded()) }
        ints[radius] += 256 - ints.reduce(0, +)
        weights = []
        var temp = [UInt8](repeating: 255, count: w * h)
        buffer.withUnsafeBufferPointer { src in
            temp.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        var sum = 0
                        for j in -radius...radius {
                            sum += ints[j + radius] * Int(src[row + min(w - 1, max(0, x + j))])
                        }
                        dst[row + x] = UInt8(sum >> 8)
                    }
                }
            }
        }
        temp.withUnsafeBufferPointer { src in
            buffer.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for x in 0..<w {
                        var sum = 0
                        for j in -radius...radius {
                            sum += ints[j + radius] * Int(src[min(h - 1, max(0, y + j)) * w + x])
                        }
                        dst[y * w + x] = UInt8(sum >> 8)
                    }
                }
            }
        }

        // 3. Paper tone, shadow, grain.
        var column = [Double](repeating: 1, count: w)
        for x in 0..<w {
            let fx = Double(x) / Double(w)
            var f = 1 + 0.025 * sin(fx * .pi * 1.4 + look.paperPhase)
            if look.shadowSide != 0 {
                let d = look.shadowSide < 0 ? fx : 1 - fx
                let reach = 0.13
                if d < reach { f *= 1 - look.shadowStrength * pow(1 - d / reach, 2) }
            }
            column[x] = f
        }
        var rowFactor = [Double](repeating: 1, count: h)
        for y in 0..<h {
            let fy = Double(y) / Double(h)
            rowFactor[y] = 0.90 - 0.04 * fy + 0.015 * sin(fy * .pi * 2.1 + look.paperPhase * 1.7)
        }
        buffer.withUnsafeMutableBufferPointer { px in
            for y in 0..<h {
                let r = rowFactor[y]
                for x in 0..<w {
                    // Four uniforms from one draw; their sum is close to normal.
                    let bits = rng.next()
                    let sum = Double(bits & 0xFFFF) + Double((bits >> 16) & 0xFFFF)
                        + Double((bits >> 32) & 0xFFFF) + Double((bits >> 48) & 0xFFFF)
                    let g = (sum / 65536 - 2) * 1.732
                    let i = y * w + x
                    let ink = 22 + Double(px[i]) * (233.0 / 255.0)
                    let v = ink * r * column[x] + g * look.noise
                    px[i] = UInt8(max(0, min(255, v.rounded())))
                }
            }
        }

        // 4. JPEG, then a CGImage backed by the JPEG.
        let provider = CGDataProvider(data: Data(buffer) as CFData)!
        let gray = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let jpeg = NSMutableData()
        let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, gray, [kCGImageDestinationLossyCompressionQuality: look.jpegQuality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let embedded = CGImage(jpegDataProviderSource: CGDataProvider(data: jpeg)!, decode: nil,
                               shouldInterpolate: true, intent: .defaultIntent)!
        return (embedded, jpeg.length)
    }
}
