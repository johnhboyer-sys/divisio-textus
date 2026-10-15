import Foundation
import Vision
import CoreGraphics
import CoreImage

/// Runs Apple's Vision text recognizer over a page image and returns the
/// recognized lines with their boxes. Used to build an invisible, searchable
/// text layer in the exported PDF.
enum OCRService {

    /// One recognized line. `box` is normalized [0,1] with a BOTTOM-LEFT origin
    /// (Vision's native convention), which matches PDF user space directly.
    struct Line {
        let text: String
        let box: CGRect
    }

    private static let ciContext = CIContext(options: nil)

    static func recognizeLines(_ cgImage: CGImage, languages: [String] = ["en-US"]) -> [Line] {
        // Detect column / table blocks. Vision reads across column gaps, so a page
        // with side-by-side columns (uniform multi-column, or embedded syllogism /
        // footnote tables) gets OCR'd one block at a time; Vision never sees across a
        // gap, so columns stay separate and in reading order. A single-column page
        // yields no useful split and runs the whole-image path unchanged.
        let blocks = LayoutAnalyzer.columnBlocks(cgImage)
        guard blocks.count > 1 else {
            return recognizeWhole(cgImage, languages: languages)
        }

        let imgW = CGFloat(cgImage.width), imgH = CGFloat(cgImage.height)
        var result: [Line] = []
        for block in blocks {
            // Block rects are normalized TOP-LEFT; CGImage.cropping is top-left too.
            let px = CGRect(x: block.minX * imgW, y: block.minY * imgH,
                            width: block.width * imgW, height: block.height * imgH).integral
            let clamped = px.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
                  let sub = cgImage.cropping(to: clamped) else { continue }

            // Translate each block-local box (Vision's bottom-left normalized) back
            // into full-page bottom-left normalized coordinates.
            let bx = block.minX, bw = block.width
            let bh = block.height
            let blockBottom = 1 - (block.minY + block.height)
            for line in recognizeWhole(sub, languages: languages) {
                let fullBox = CGRect(x: bx + line.box.minX * bw,
                                     y: blockBottom + line.box.minY * bh,
                                     width: line.box.width * bw,
                                     height: line.box.height * bh)
                result.append(Line(text: line.text, box: fullBox))
            }
        }
        return result
    }

    /// Minimum image height (px) before the second, half-scale OCR pass runs. The
    /// half-scale pass recovers lines Vision drops after deskew rotation on full-size
    /// pages, but on a small block (a table/footnote column) it tends to split a
    /// wrapped term differently and the merge double-adds it. Small blocks get one
    /// clean pass instead.
    private static let twoPassMinHeight = 600

    /// OCR over a whole image. Large images get two passes (full + 50% scale) merged
    /// to recover deskew-dropped lines; small blocks get a single full-resolution pass.
    private static func recognizeWhole(_ cgImage: CGImage, languages: [String]) -> [Line] {
        let pass1 = runRequest(on: preprocess(cgImage), languages: languages)
        guard cgImage.height >= twoPassMinHeight else { return pass1 }
        let pass2 = runRequest(on: preprocess(halfScale(cgImage)), languages: languages)
        return merge(pass1, pass2)
    }

    private static func halfScale(_ image: CGImage) -> CGImage {
        let w = max(1, image.width / 2)
        let h = max(1, image.height / 2)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: - Internal helpers

    private static func runRequest(on image: CGImage, languages: [String]) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0        // don't drop small body text

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let text = candidate.string
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Line(text: text, box: obs.boundingBox)
        }
    }

    /// Merge two line arrays, recovering lines that Vision garbles or drops in pass1.
    ///
    /// Two failure modes are handled:
    ///  1. **Garbled merge** — Vision collapses two adjacent lines into one wide
    ///     observation with mangled text. Detected when two or more pass2 line centers
    ///     fall inside the same pass1 box; that pass1 entry is replaced by the pass2
    ///     lines (which are individually cleaner at half resolution).
    ///  2. **Outright drop** — Vision misses a line entirely in pass1. Detected when a
    ///     pass2 line's center doesn't fall inside any pass1 box at all; appended as-is.
    private static func merge(_ pass1: [Line], _ pass2: [Line]) -> [Line] {
        let expanded = pass1.map { ($0, $0.box.insetBy(dx: -0.005, dy: -0.005)) }

        // For every pass1 entry, collect how many pass2 centers land inside it.
        var pass2ByPass1: [Int: [Line]] = [:]   // pass1 index → pass2 lines inside it
        var pass2Covered: Set<Int> = []          // pass2 indices covered by any pass1 box

        for (p2idx, p2) in pass2.enumerated() {
            let pt = CGPoint(x: p2.box.midX, y: p2.box.midY)
            for (p1idx, (_, box)) in expanded.enumerated() where box.contains(pt) {
                pass2ByPass1[p1idx, default: []].append(p2)
                pass2Covered.insert(p2idx)
            }
        }

        var result: [Line] = []
        for (p1idx, (p1line, _)) in expanded.enumerated() {
            let insiders = pass2ByPass1[p1idx] ?? []
            if insiders.count >= 2 {
                // Pass1 likely garbled/merged multiple lines — use the pass2 versions.
                result.append(contentsOf: insiders)
            } else {
                result.append(p1line)
            }
        }

        // Append any pass2 line that didn't land inside any pass1 box (outright drop).
        for (p2idx, p2) in pass2.enumerated() where !pass2Covered.contains(p2idx) {
            result.append(p2)
        }
        return result
    }

    /// Desaturate and stretch contrast to give Vision a cleaner signal.
    private static func preprocess(_ image: CGImage) -> CGImage {
        let input = CIImage(cgImage: image)
        let adjusted = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,   // grayscale
            kCIInputContrastKey: 1.25,    // mild contrast stretch
            kCIInputBrightnessKey: 0.0
        ])
        return ciContext.createCGImage(adjusted, from: input.extent) ?? image
    }
}
