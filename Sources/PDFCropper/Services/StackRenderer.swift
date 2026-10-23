import Foundation
import CoreGraphics
import PDFKit

/// Blends low-resolution, straightened sides without retaining every page image.
enum StackRenderer {
    static func render(_ stack: PageStack, from document: PDFDocument,
                       isCancelled: @escaping () -> Bool = { false }) -> CGImage? {
        render(stack, workers: 1, open: { document }, isCancelled: isCancelled)
    }

    /// Splits the pages among `workers` threads. `open` must give each call its own
    /// PDFDocument: PDFKit can't draw one document from two threads. Decoding the
    /// full-resolution scans is most of the time, so this scales with the cores.
    static func render(_ stack: PageStack, workers: Int, open: @escaping () -> PDFDocument?,
                       isCancelled: @escaping () -> Bool) -> CGImage? {
        guard let document = open() else { return nil }
        // Each side at true size: one scale for every page (a usual scan's width in
        // pixels), with the stack as wide as its widest side (see PageStack.Member.span).
        let sizes = stack.members.compactMap { member -> CGSize? in
            guard let page = document.page(at: member.page.sourceIndex) else { return nil }
            let size = PDFRenderer.displaySize(of: page)
            return CGSize(width: size.width * 30 / 72, height: size.height * 30 / 72)
        }
        guard sizes.count == stack.members.count, !sizes.isEmpty else { return nil }
        let scanWidth = PageStack.median(sizes.map { Double($0.width) })
        let width = max(1, Int((scanWidth * stack.span).rounded()))
        let height = max(1, Int(PageStack.median(sizes.map { Double($0.height) }).rounded()))

        let members = stack.members
        let count = max(1, min(workers, members.count))
        let results = Results(count: count)
        DispatchQueue.concurrentPerform(iterations: count) { w in
            // Worker 0 reuses the document opened above.
            guard let doc = w == 0 ? document : open() else { return }
            var ink = [Double](repeating: 0, count: width * height)
            for k in stride(from: w, to: members.count, by: count) {
                guard !isCancelled(),
                      add(members[k], from: doc, to: &ink, width: width, height: height) else { return }
            }
            results.set(w, ink)
        }
        guard !isCancelled(), let parts = results.all() else { return nil }
        var ink = parts[0]
        for part in parts.dropFirst() {
            for i in ink.indices { ink[i] += part[i] }
        }
        let n = Double(members.count)
        let pixels = ink.map { UInt8(max(0, min(255, ((1 - sqrt($0 / n)) * 255).rounded()))) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Adds one side's ink, scaled to the common canvas. False if it couldn't be drawn.
    private static func add(_ member: PageStack.Member, from document: PDFDocument,
                            to ink: inout [Double], width: Int, height: Int) -> Bool {
        autoreleasepool { () -> Bool in
            let p = member.page
            guard let page = document.page(at: p.sourceIndex),
                  let image = PDFRenderer.renderCGImage(page: page, dpi: 30) else { return false }
            let straight = ImageTransform.deskewedComposite(image, splitX: p.splitX,
                leftDegrees: p.leftSkew, rightDegrees: p.rightSkew, isSpread: p.isSpread)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.setFillColor(gray: 1, alpha: 1)               // a narrower side leaves paper-white
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // The whole scan at the stack's scale, placed so the fold lands where the
            // stack's coordinates put it (a left side's at the right edge, a right
            // side's at the left), and clipped to this side: no rounding to pixels.
            let scan = Double(width) / member.span                // pixels per scan width
            let origin = member.side == .left ? Double(width) - p.splitX * scan
                : member.side == .right ? -p.splitX * scan : 0
            let side = CGRect(x: origin + member.regionMinX * scan, y: 0,
                              width: member.regionWidth * scan, height: Double(height))
            context.clip(to: side)
            context.draw(straight, in: CGRect(x: origin, y: 0, width: scan, height: Double(height)))
            guard let data = context.data else { return false }
            let gray = data.bindMemory(to: UInt8.self, capacity: ink.count)
            for i in ink.indices { ink[i] += (255 - Double(gray[i])) / 255 }
            return true
        }
    }

    /// Each worker's sum, or nil for a worker that stopped early.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [[Double]?]
        init(count: Int) { parts = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ ink: [Double]) { lock.lock(); parts[i] = ink; lock.unlock() }
        func all() -> [[Double]]? {
            lock.lock(); defer { lock.unlock() }
            return parts.contains { $0 == nil } ? nil : parts.map { $0! }
        }
    }
}
