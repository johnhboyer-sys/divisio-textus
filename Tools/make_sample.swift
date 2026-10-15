// Standalone generator for a fake "scanned book" PDF to test PDF Cropper.
// Build:  swiftc Tools/make_sample.swift -o /tmp/make_sample
// Run:    /tmp/make_sample sample-book.pdf
import AppKit
import PDFKit
import CoreGraphics

func drawTextBlock(_ ctx: CGContext, rect: CGRect, lines: Int) {
    ctx.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor)
    let lineH = rect.height / CGFloat(lines)
    for i in 0..<lines {
        let y = rect.minY + CGFloat(i) * lineH + lineH * 0.3
        // vary line width to look like text
        let w = rect.width * (0.6 + 0.4 * CGFloat((i * 7 % 10)) / 10.0)
        ctx.fill(CGRect(x: rect.minX, y: y, width: w, height: lineH * 0.35))
    }
}

/// Draw a text block rotated about `pivot` by `deg` degrees.
func drawTiltedBlock(_ ctx: CGContext, rect: CGRect, lines: Int, deg: CGFloat, pivot: CGPoint) {
    ctx.saveGState()
    ctx.translateBy(x: pivot.x, y: pivot.y)
    ctx.rotate(by: deg * .pi / 180)
    ctx.translateBy(x: -pivot.x, y: -pivot.y)
    drawTextBlock(ctx, rect: rect, lines: lines)
    ctx.restoreGState()
}

func makePage(_ ctx: CGContext, size: CGSize, spread: Bool, jitter: CGFloat,
              leftSkew: CGFloat = 0, rightSkew: CGFloat = 0) {
    ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor) // off-white paper
    ctx.fill(CGRect(origin: .zero, size: size))

    if spread {
        // gutter shadow down the middle (straight)
        let gx = size.width / 2 + jitter * 12
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                              colors: [NSColor(white: 0.4, alpha: 1).cgColor,
                                       NSColor(white: 0.96, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: gx - 18, y: 0, width: 36, height: size.height))
        ctx.drawLinearGradient(grad, start: CGPoint(x: gx, y: 0), end: CGPoint(x: gx - 18, y: 0), options: [])
        ctx.drawLinearGradient(grad, start: CGPoint(x: gx, y: 0), end: CGPoint(x: gx + 18, y: 0), options: [])
        ctx.restoreGState()

        let m: CGFloat = 60
        let halfW = size.width / 2
        let left = CGRect(x: m + jitter * 8, y: m, width: halfW - m * 1.6, height: size.height - m * 2)
        let right = CGRect(x: halfW + m * 0.6, y: m - jitter * 8, width: halfW - m * 1.6, height: size.height - m * 2)
        // Each book page tilted by its OWN angle, about its own half's center.
        drawTiltedBlock(ctx, rect: left, lines: 28, deg: leftSkew,
                        pivot: CGPoint(x: halfW / 2, y: size.height / 2))
        drawTiltedBlock(ctx, rect: right, lines: 28, deg: rightSkew,
                        pivot: CGPoint(x: halfW + halfW / 2, y: size.height / 2))
    } else {
        let m: CGFloat = 90
        let r = CGRect(x: m, y: m, width: size.width - m * 2, height: size.height - m * 2)
        drawTiltedBlock(ctx, rect: r, lines: 20, deg: leftSkew,
                        pivot: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "sample-book.pdf"
let url = URL(fileURLWithPath: outPath)

let spreadSize = CGSize(width: 1200, height: 900) // landscape spread
let singleSize = CGSize(width: 600, height: 900)  // portrait single

var mediaBox = CGRect(origin: .zero, size: spreadSize)
guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
    fatalError("cannot create pdf context")
}

// Page 1: single cover
var coverBox = CGRect(origin: .zero, size: singleSize)
ctx.beginPage(mediaBox: &coverBox)
makePage(ctx, size: singleSize, spread: false, jitter: 0)
ctx.endPage()

// Pages 2..6: spreads where each book page has its OWN tilt (left vs right).
let leftSkews: [CGFloat]  = [3.0, -2.0,  0.0,  2.5, -3.5]
let rightSkews: [CGFloat] = [0.0,  2.5, -3.0, -1.5,  1.0]
for i in 0..<5 {
    var box = CGRect(origin: .zero, size: spreadSize)
    ctx.beginPage(mediaBox: &box)
    makePage(ctx, size: spreadSize, spread: true, jitter: CGFloat(i % 3) - 1,
             leftSkew: leftSkews[i], rightSkew: rightSkews[i])
    ctx.endPage()
}

ctx.closePDF()
print("Wrote \(outPath)")
