// Draws close-ups of pages whose split or crop moved. Run by diff_split.py:
//   swift render_strips.swift jobs.json
// Each job: {pdf, page (0-based), out, a: record, b: record}. A record has cls, split,
// left, right ([x, y, w, h] as shares of the page). Output: two panels side by side,
// full page height. Left panel: the split lines (A red, B blue). Right panel: the crop
// boxes (A red, B blue). For a spread the strip is centred on the two splits; for
// anything else it is the whole page width.
import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Rec {
    var cls: String
    var split: Double
    var rects: [[Double]]
    init(_ d: [String: Any]) {
        cls = d["cls"] as? String ?? "spread"
        split = d["split"] as? Double ?? 0.5
        rects = []
        if let l = d["left"] as? [Double] { rects.append(l) }
        if let r = d["right"] as? [Double] { rects.append(r) }
    }
}

func render(_ page: PDFPage, maxSide: Double) -> CGImage? {
    let box = page.bounds(for: .cropBox)
    let turned = ((page.rotation % 360) + 360) % 360 / 90 % 2 == 1
    let size = turned ? CGSize(width: box.height, height: box.width) : box.size
    let scale = min(110.0 / 72, maxSide / Double(max(size.width, size.height)))
    let w = max(1, Int((Double(size.width) * scale).rounded())), h = max(1, Int((Double(size.height) * scale).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .cropBox, to: ctx)
    return ctx.makeImage()
}

let red = CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1), blue = CGColor(red: 0.1, green: 0.3, blue: 0.95, alpha: 1)

func panel(_ img: CGImage, x0: Double, x1: Double, draw: (CGContext, (Double) -> Double, Double) -> Void) -> CGImage? {
    let W = Double(img.width), H = Double(img.height)
    let sx = Int(x0 * W), ex = Int(x1 * W)
    guard ex > sx, let strip = img.cropping(to: CGRect(x: sx, y: 0, width: ex - sx, height: img.height)),
          let ctx = CGContext(data: nil, width: strip.width, height: strip.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.draw(strip, in: CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
    // Top-left origin from here on.
    ctx.translateBy(x: 0, y: Double(strip.height))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx, { ($0 * W) - Double(sx) }, H)
    return ctx.makeImage()
}

func line(_ ctx: CGContext, _ x: Double, _ h: Double, _ color: CGColor) {
    ctx.setStrokeColor(color); ctx.setLineWidth(2)
    ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h)); ctx.strokePath()
}

func box(_ ctx: CGContext, _ r: [Double], _ px: (Double) -> Double, _ h: Double, _ color: CGColor, dash: Bool) {
    ctx.setStrokeColor(color); ctx.setLineWidth(2)
    ctx.setLineDash(phase: 0, lengths: dash ? [8, 5] : [])
    ctx.stroke(CGRect(x: px(r[0]), y: r[1] * h, width: (px(r[0] + r[2]) - px(r[0])), height: r[3] * h))
}

func write(_ img: CGImage, _ path: String) {
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}

guard CommandLine.arguments.count >= 2,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let jobs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
    print("usage: render_strips.swift jobs.json"); exit(2)
}
var cache: [String: PDFDocument] = [:]
var done = 0
for job in jobs {
    guard let path = job["pdf"] as? String, let pageNo = job["page"] as? Int, let out = job["out"] as? String,
          let ja = job["a"] as? [String: Any], let jb = job["b"] as? [String: Any] else { continue }
    if cache[path] == nil { cache[path] = PDFDocument(url: URL(fileURLWithPath: path)) }
    guard let doc = cache[path], let page = doc.page(at: pageNo), let img = render(page, maxSide: 1800) else {
        print("cannot draw \(path) page \(pageNo + 1)"); continue
    }
    let a = Rec(ja), b = Rec(jb)
    var x0 = 0.0, x1 = 1.0
    if a.cls == "spread" && b.cls == "spread" {
        let lo = min(a.split, b.split), hi = max(a.split, b.split)
        let half = max(0.08, (hi - lo) * 1.5 + 0.04)
        x0 = max(0, (lo + hi) / 2 - half); x1 = min(1, (lo + hi) / 2 + half)
    }
    let p1 = panel(img, x0: x0, x1: x1) { ctx, px, h in
        if a.cls == "spread" { line(ctx, px(a.split), h, red) }
        if b.cls == "spread" { line(ctx, px(b.split), h, blue) }
    }
    let p2 = panel(img, x0: x0, x1: x1) { ctx, px, h in
        for r in a.rects { box(ctx, r, px, h, red, dash: false) }
        for r in b.rects { box(ctx, r, px, h, blue, dash: true) }
    }
    guard let left = p1, let right = p2,
          let ctx = CGContext(data: nil, width: left.width * 2 + 12, height: left.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
    ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.draw(left, in: CGRect(x: 0, y: 0, width: left.width, height: left.height))
    ctx.draw(right, in: CGRect(x: left.width + 12, y: 0, width: right.width, height: right.height))
    if let combined = ctx.makeImage() { write(combined, out); done += 1 }
}
print("wrote \(done) close-ups")
