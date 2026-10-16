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

    /// The text found on a page. `complete` is false when Vision failed on part
    /// of it (one column of a two-column page, say): the lines from the parts it
    /// read are still here, but the page isn't fully searchable.
    struct Recognition {
        var lines: [Line]
        var complete: Bool
    }

    /// Returns nil when Vision failed on the whole page (not "no text found"), so
    /// callers can tell the user which pages ended up without a text layer.
    static func recognizeLines(_ cgImage: CGImage, languages: [String] = ["en-US"]) -> Recognition? {
        // Detect column / table blocks. Vision reads across column gaps, so a page
        // with side-by-side columns (uniform multi-column, or embedded syllogism /
        // footnote tables) gets OCR'd one block at a time; Vision never sees across a
        // gap, so columns stay separate and in reading order. A single-column page
        // yields no useful split and runs the whole-image path unchanged.
        let blocks = LayoutAnalyzer.columnBlocks(cgImage)
        guard blocks.count > 1 else {
            return recognizeWhole(cgImage, languages: languages).map { Recognition(lines: $0, complete: true) }
        }

        let imgW = CGFloat(cgImage.width), imgH = CGFloat(cgImage.height)
        var result: [Line] = []
        var failedBlocks = 0
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
            guard let lines = recognizeWhole(sub, languages: languages) else {
                failedBlocks += 1
                continue
            }
            for line in lines {
                let fullBox = CGRect(x: bx + line.box.minX * bw,
                                     y: blockBottom + line.box.minY * bh,
                                     width: line.box.width * bw,
                                     height: line.box.height * bh)
                result.append(Line(text: line.text, box: fullBox))
            }
        }
        // Nothing read at all counts as a failed page; otherwise keep what was read.
        if failedBlocks > 0 && result.isEmpty { return nil }
        return Recognition(lines: result, complete: failedBlocks == 0)
    }

    /// Minimum image height (px) before the second, half-scale OCR pass runs. The
    /// half-scale pass recovers lines Vision drops after deskew rotation on full-size
    /// pages, but on a small block (a table/footnote column) it tends to split a
    /// wrapped term differently and the merge double-adds it. Small blocks get one
    /// clean pass instead.
    private static let twoPassMinHeight = 600

    /// OCR over a whole image. Large images get two passes (full + 50% scale) merged
    /// to recover deskew-dropped lines; small blocks get a single full-resolution pass.
    private static func recognizeWhole(_ cgImage: CGImage, languages: [String]) -> [Line]? {
        guard let pass1 = runRequest(on: preprocess(cgImage), languages: languages) else { return nil }
        guard cgImage.height >= twoPassMinHeight else { return pass1 }
        // The second pass only recovers lines; if it fails, pass1 alone is still good.
        guard let pass2 = runRequest(on: preprocess(halfScale(cgImage)), languages: languages) else { return pass1 }
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

    /// Vision can fail outright (e.g. "e5rtError … precompiled compute operation"
    /// while macOS rebuilds its on-device model, or when other jobs are using the
    /// Neural Engine) and often succeeds a moment later, so retry before giving up.
    private static let retryDelays: [TimeInterval] = [0.5, 2]

    /// One recognition pass, retried on failure. nil = every attempt failed.
    private static func runRequest(on image: CGImage, languages: [String]) -> [Line]? {
        for attempt in 0...retryDelays.count {
            if attempt > 0 { Thread.sleep(forTimeInterval: retryDelays[attempt - 1]) }
            if let lines = recognizeOnce(image, languages: languages) { return lines }
        }
        return nil
    }

    private static func recognizeOnce(_ image: CGImage, languages: [String]) -> [Line]? {
        if #available(macOS 15, *) { return recognizeOnceModern(image, languages: languages) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0        // don't drop small body text
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        return (request.results ?? []).compactMap {
            makeLine($0.topCandidates(1).first?.string, box: $0.boundingBox)
        }
    }

    /// The macOS 15+ API, preferred because it recovers after a Vision failure:
    /// the next request works. With the older VNRecognizeTextRequest one failure
    /// made every later request in the process fail too. Same boxes as the old API.
    @available(macOS 15, *)
    private static func recognizeOnceModern(_ image: CGImage, languages: [String]) -> [Line]? {
        final class Result: @unchecked Sendable { var lines: [Line]? }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        // The API is async; export calls OCR from plain GCD threads, so wait here.
        Task.detached {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
            request.automaticallyDetectsLanguage = true
            request.minimumTextHeightFraction = 0    // don't drop small body text
            if let observations = try? await request.perform(on: image) {
                result.lines = observations.compactMap {
                    makeLine($0.topCandidates(1).first?.string, box: $0.boundingBox.cgRect)
                }
            }
            done.signal()
        }
        done.wait()
        return result.lines
    }

    private static func makeLine(_ text: String?, box: CGRect) -> Line? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Line(text: text, box: box)
    }

    /// Merge two line arrays, recovering lines that Vision garbles or drops in pass1.
    ///
    /// Each pass2 line is given to ONE pass1 line: the nearest whose (slightly
    /// enlarged) box holds its center. On tightly set text the line boxes overlap,
    /// and giving a pass2 line to every box it fell in once duplicated about one
    /// line in six. Then:
    ///  1. **Garbled merge** — Vision collapsed two adjacent lines into one
    ///     observation: the pass2 lines given to it sit on different rows, so they
    ///     replace it (they are individually cleaner at half resolution).
    ///  2. **Outright drop** — a pass2 line that no pass1 box holds is appended.
    static func merge(_ pass1: [Line], _ pass2: [Line]) -> [Line] {
        let expanded = pass1.map { $0.box.insetBy(dx: -0.005, dy: -0.005) }

        var given: [Int: [Line]] = [:]     // pass1 index → its pass2 lines
        var unheld: [Line] = []
        for line in pass2 {
            let center = CGPoint(x: line.box.midX, y: line.box.midY)
            let holders = expanded.indices.filter { expanded[$0].contains(center) }
            guard let nearest = holders.min(by: {
                abs(pass1[$0].box.midY - center.y) < abs(pass1[$1].box.midY - center.y)
            }) else {
                unheld.append(line)
                continue
            }
            given[nearest, default: []].append(line)
        }

        var result: [Line] = []
        for (i, line) in pass1.enumerated() {
            let mine = given[i] ?? []
            if mine.count >= 2 && onDifferentRows(mine) {
                result.append(contentsOf: mine)
            } else {
                result.append(line)
            }
        }
        return result + unheld
    }

    /// True when some of the lines sit above others (not side by side on one row).
    private static func onDifferentRows(_ lines: [Line]) -> Bool {
        let centers = lines.map(\.box.midY)
        guard let lowest = centers.min(), let highest = centers.max(),
              let height = lines.map(\.box.height).min() else { return false }
        return highest - lowest > height * 0.6
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
