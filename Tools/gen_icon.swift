// Generates a 1024×1024 PNG app icon for Divisio Textus: two cream pages divided
// by a gold seam on a deep indigo ground (the "division of the text").
// Build: swiftc Tools/gen_icon.swift -o /tmp/gen_icon
// Run:   /tmp/gen_icon /tmp/icon_1024.png
import AppKit

let S: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon_1024.png"

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Background: rounded-rect indigo gradient.
let bg = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: S - 120, height: S - 120),
                      xRadius: 200, yRadius: 200)
bg.addClip()
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.24, green: 0.31, blue: 0.55, alpha: 1),
    NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.28, alpha: 1)
])!
grad.draw(in: bg, angle: -90)

// Two pages with a gap between them.
let pageW: CGFloat = 262, pageH: CGFloat = 660
let gap: CGFloat = 56
let totalW = pageW * 2 + gap
let originX = (S - totalW) / 2
let originY = (S - pageH) / 2
let cream = NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 1)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -10)

func drawPage(x: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let p = NSBezierPath(roundedRect: NSRect(x: x, y: originY, width: pageW, height: pageH),
                         xRadius: 18, yRadius: 18)
    cream.setFill()
    p.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Faint text lines.
    NSColor(calibratedWhite: 0.55, alpha: 0.55).setFill()
    let lineH: CGFloat = 14, lineGap: CGFloat = 34
    let inset: CGFloat = 30
    var ly = originY + pageH - 70
    var i = 0
    while ly > originY + 50 {
        let w = pageW - inset * 2 - (i % 4 == 3 ? 70 : 0)
        NSBezierPath(roundedRect: NSRect(x: x + inset, y: ly, width: w, height: lineH),
                     xRadius: 6, yRadius: 6).fill()
        ly -= lineGap
        i += 1
    }
}
drawPage(x: originX)
drawPage(x: originX + pageW + gap)

// Gold seam down the division.
let seamX = S / 2
NSColor(calibratedRed: 0.85, green: 0.68, blue: 0.30, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: seamX - 7, y: originY - 14, width: 14, height: pageH + 28),
             xRadius: 7, yRadius: 7).fill()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
