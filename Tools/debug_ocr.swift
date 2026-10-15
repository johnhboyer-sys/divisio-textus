// Standalone OCR debug tool — mirrors OCRService + drawTextLayer exactly.
// Build & run:
//   swiftc Tools/debug_ocr.swift -o /tmp/debug_ocr && /tmp/debug_ocr "/path/to/file.pdf"
import Foundation
import PDFKit
import Vision
import CoreGraphics
import CoreImage
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else { fatalError("Usage: debug_ocr <pdf-path>") }

let pdfURL = URL(fileURLWithPath: args[1])
guard let document = PDFDocument(url: pdfURL) else { fatalError("Cannot open \(args[1])") }

let ciContext = CIContext(options: nil)

func preprocess(_ image: CGImage) -> CGImage {
    let input = CIImage(cgImage: image)
    let adjusted = input.applyingFilter("CIColorControls", parameters: [
        kCIInputSaturationKey: 0.0,
        kCIInputContrastKey: 1.25,
        kCIInputBrightnessKey: 0.0
    ])
    return ciContext.createCGImage(adjusted, from: input.extent) ?? image
}

func renderPage(_ pdfPage: PDFPage, dpi: CGFloat) -> CGImage? {
    let mediaBox = pdfPage.bounds(for: .mediaBox)
    let scale = dpi / 72.0
    let w = Int(mediaBox.width * scale)
    let h = Int(mediaBox.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
    pdfPage.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

func runOCR(on cgImage: CGImage, label: String) {
    let pageW = CGFloat(cgImage.width)
    let pageH = CGFloat(cgImage.height)
    print("  \(label): \(Int(pageW)) x \(Int(pageH)) px")

    let ocrImage = preprocess(cgImage)

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    request.automaticallyDetectsLanguage = true
    request.minimumTextHeight = 0

    let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])
    do { try handler.perform([request]) } catch { print("  Vision error: \(error)"); return }

    guard let observations = request.results else { print("  No results"); return }

    let lines: [(text: String, box: CGRect)] = observations.compactMap { obs in
        guard let candidate = obs.topCandidates(1).first else { return nil }
        let text = candidate.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, obs.boundingBox)
    }
    print("  Vision returned \(lines.count) lines\n")

    for (i, line) in lines.enumerated() {
        let scaledW = line.box.width  * pageW
        let scaledH = line.box.height * pageH
        let wouldSkip = scaledW <= 1 || scaledH <= 1

        var fontSize = max(1.0, scaledH)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attr = NSAttributedString(string: line.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attr)
        let naturalWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        var shrunk = false
        if naturalWidth > scaledW, naturalWidth > 0 {
            fontSize *= scaledW / naturalWidth
            shrunk = true
        }

        let flag = wouldSkip ? " *** GUARD SKIP ***" :
                   (shrunk ? " (font shrunk \(String(format:"%.1f",scaledH))→\(String(format:"%.1f",max(1,fontSize)))pt)" : "")
        print(String(format: "  %3d [x:%.3f y:%.3f w:%.3f h:%.3f]%@ \"%@\"",
                     i + 1,
                     line.box.minX, line.box.minY,
                     line.box.width, line.box.height,
                     flag, line.text))
    }
}

/// Crop a CGImage to a sub-rect (in pixel coordinates, top-left origin).
func cropImage(_ src: CGImage, rect: CGRect) -> CGImage? {
    // CGImage.cropping uses top-left origin for the rect directly.
    return src.cropping(to: rect)
}

/// Export one CGImage as a single-page PDF with an OCR text layer and return
/// the text as read back by PDFKit — exactly simulates PDFExporter.
func roundTripOCR(_ cgImage: CGImage, label: String) {
    let w = cgImage.width, h = cgImage.height
    print("\n-- Round-trip export: \(label) (\(w)×\(h)) --")

    let lines = runOCRReturnLines(cgImage)
    print("  OCR: \(lines.count) lines recognized")

    // Write PDF
    let outURL = URL(fileURLWithPath: "/tmp/debug_ocr_roundtrip.pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: w, height: h)
    guard let consumer = CGDataConsumer(url: outURL as CFURL),
          let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        print("  ERROR: could not create PDF context"); return
    }

    ctx.beginPage(mediaBox: &mediaBox)
    ctx.draw(cgImage, in: mediaBox)

    // Mirror drawTextLayer exactly
    let pageSize = CGSize(width: CGFloat(w), height: CGFloat(h))
    ctx.saveGState()
    ctx.setTextDrawingMode(.invisible)
    ctx.textMatrix = .identity
    for line in lines {
        let box = CGRect(x: line.box.minX * pageSize.width,
                         y: line.box.minY * pageSize.height,
                         width: line.box.width * pageSize.width,
                         height: line.box.height * pageSize.height)
        guard box.width > 1, box.height > 1 else {
            print("  SKIP (guard): \"\(line.text)\""); continue
        }
        var fontSize = max(1, box.height)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attr = NSAttributedString(string: line.text, attributes: [.font: font])
        var ctLine = CTLineCreateWithAttributedString(attr)
        let naturalWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        if naturalWidth > box.width, naturalWidth > 0 {
            fontSize *= box.width / naturalWidth
            let font2 = CTFontCreateWithName("Helvetica" as CFString, max(1, fontSize), nil)
            let attr2 = NSAttributedString(string: line.text, attributes: [.font: font2])
            ctLine = CTLineCreateWithAttributedString(attr2)
        }
        ctx.textPosition = CGPoint(x: box.minX, y: box.minY + fontSize * 0.18)
        CTLineDraw(ctLine, ctx)
    }
    ctx.restoreGState()
    ctx.endPage()
    ctx.closePDF()

    // Read back
    guard let readDoc = PDFDocument(url: outURL),
          let readPage = readDoc.page(at: 0) else {
        print("  ERROR: could not reopen exported PDF"); return
    }
    let text = readPage.string ?? ""
    let extractedLines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    print("  Readback: \(extractedLines.count) lines extracted")
    for (i, l) in extractedLines.enumerated() {
        print("  \(i+1). \"\(l)\"")
    }
}

/// Like runOCR but returns the lines array for further use.
func runOCRReturnLines(_ cgImage: CGImage) -> [(text: String, box: CGRect)] {
    let ocrImage = preprocess(cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    request.automaticallyDetectsLanguage = true
    request.minimumTextHeight = 0
    let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])
    do { try handler.perform([request]) } catch { return [] }
    guard let observations = request.results else { return [] }
    return observations.compactMap { obs in
        guard let candidate = obs.topCandidates(1).first else { return nil }
        let text = candidate.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, obs.boundingBox)
    }
}

func rotateInPlace(_ src: CGImage, degrees: Double) -> CGImage {
    guard abs(degrees) > 0.01 else { return src }
    let w = src.width, h = src.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return src }
    ctx.interpolationQuality = .high
    ctx.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1))
    ctx.fill(CGRect(x:0,y:0,width:w,height:h))
    let px = Double(w)/2, py = Double(h)/2
    ctx.translateBy(x: px, y: py)
    ctx.rotate(by: degrees * .pi / 180)
    ctx.translateBy(x: -px, y: -py)
    ctx.draw(src, in: CGRect(x:0,y:0,width:w,height:h))
    return ctx.makeImage() ?? src
}

// ----- PageAnalyzer.contentBounds (inlined for standalone script) -----

struct GBuf {
    let width: Int, height: Int
    let pixels: [UInt8]
    func value(_ x: Int, _ y: Int) -> UInt8 { pixels[y * width + x] }
    func columnMean(_ x: Int) -> Double {
        var s = 0; for y in 0..<height { s += Int(pixels[y*width+x]) }
        return Double(s)/Double(height)
    }
    init?(_ src: CGImage, maxDim: Int = 800) {
        let sw = src.width, sh = src.height
        guard sw > 0, sh > 0 else { return nil }
        let sc = Double(maxDim)/Double(max(sw,sh))
        let w = max(1, Int((Double(sw)*min(1,sc)).rounded()))
        let h = max(1, Int((Double(sh)*min(1,sc)).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x:0,y:0,width:w,height:h))
        guard let data = ctx.data else { return nil }
        let raw = data.bindMemory(to: UInt8.self, capacity: w*h)
        width=w; height=h; pixels=Array(UnsafeBufferPointer(start:raw,count:w*h))
    }
}

func detectGutter(_ g: GBuf) -> Double {
    let lo = Int(Double(g.width)*0.40), hi = Int(Double(g.width)*0.60)
    guard hi > lo else { return 0.5 }
    var bestX = g.width/2, bestMean = Double.greatestFiniteMagnitude
    for x in lo..<hi { let m = g.columnMean(x); if m < bestMean { bestMean=m; bestX=x } }
    return Double(bestX)/Double(g.width)
}

struct CropR { var x,y,width,height: Double }
func contentBounds(_ g: GBuf, x0: Int, x1: Int) -> CropR {
    var maxVal: UInt8 = 0
    for row in 0..<g.height { for col in x0..<x1 { maxVal = max(maxVal, g.value(col,row)) } }
    let threshold = Double(maxVal)*0.75
    let minRun = 0.01
    var top=g.height, bottom = -1, left=g.width, right = -1
    for y in 0..<g.height {
        var dark=0; for x in x0..<x1 where Double(g.value(x,y))<threshold { dark+=1 }
        if dark > Int(Double(x1-x0)*minRun) { top=min(top,y); bottom=max(bottom,y) }
    }
    for x in x0..<x1 {
        var dark=0; for y in 0..<g.height where Double(g.value(x,y))<threshold { dark+=1 }
        if dark > Int(Double(g.height)*minRun) { left=min(left,x); right=max(right,x) }
    }
    guard bottom>=top, right>=left else {
        return CropR(x: Double(x0)/Double(g.width), y:0.02,
                     width: Double(x1-x0)/Double(g.width)-0.02, height:0.96)
    }
    let pad=0.012
    return CropR(x: max(0,Double(left)/Double(g.width)-pad),
                 y: max(0,Double(top)/Double(g.height)-pad),
                 width: min(1,Double(right-left)/Double(g.width)+2*pad),
                 height: min(1,Double(bottom-top)/Double(g.height)+2*pad))
}

func cropCGImage(_ src: CGImage, rect: CropR) -> CGImage? {
    let w=Double(src.width), h=Double(src.height)
    let px = CGRect(x: rect.x*w, y: rect.y*h, width: rect.width*w, height: rect.height*h).integral
    let clamped = px.intersection(CGRect(x:0,y:0,width:src.width,height:src.height))
    guard !clamped.isNull, clamped.width>=1, clamped.height>=1 else { return nil }
    return src.cropping(to: clamped)
}

func composeCGImage(_ img: CGImage, canvasW: Int, canvasH: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: canvasW, height: canvasH,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1))
    ctx.fill(CGRect(x:0,y:0,width:canvasW,height:canvasH))
    let dx=(canvasW-img.width)/2, dy=(canvasH-img.height)/2
    ctx.draw(img, in: CGRect(x:dx,y:dy,width:img.width,height:img.height))
    return ctx.makeImage()
}

for pageIndex in 0..<document.pageCount {
    guard let pdfPage = document.page(at: pageIndex) else { continue }
    print("\n=== PDF page \(pageIndex + 1) of \(document.pageCount) ===")

    guard let full = renderPage(pdfPage, dpi: 300) else {
        print("  RENDER FAILED"); continue
    }
    let fw = full.width, fh = full.height

    // --- Full spread ---
    print("\n-- Full spread --")
    runOCR(on: full, label: "full \(fw)×\(fh)")

    // --- Right half (simulates what the app crops for the right book page) ---
    let rightRect = CGRect(x: fw / 2, y: 0, width: fw - fw / 2, height: fh)
    if let rightHalf = cropImage(full, rect: rightRect) {
        print("\n-- Right half only (app crop simulation) --")
        runOCR(on: rightHalf, label: "right-half \(rightHalf.width)×\(rightHalf.height)")

        // --- Round-trip: write PDF + read back text to catch drawTextLayer drops ---
        roundTripOCR(rightHalf, label: "right-half round-trip")
    }

    // --- Deskew sensitivity test: rotate right half by common angles, rerun OCR ---
    if let rightHalf = cropImage(full, rect: CGRect(x: fw / 2, y: 0, width: fw - fw / 2, height: fh)) {
        print("\n-- Deskew sensitivity (right half, several angles) --")
        for deg in [-3.0, -2.0, -1.0, -0.5, 0.5, 1.0, 2.0, 3.0] {
            let rotated = rotateInPlace(rightHalf, degrees: deg)
            let lines = runOCRReturnLines(rotated)
            print("  \(String(format:"%+.1f",deg))°: \(lines.count) lines")
        }
    }

    // --- App-crop simulation: use PageAnalyzer's contentBounds for the right column ---
    if let g = GBuf(full) {
        let splitX = detectGutter(g)
        let splitPx = Int(Double(g.width) * splitX)
        let rightBounds = contentBounds(g, x0: splitPx, x1: g.width)
        print("\n-- App-crop simulation --")
        print("  Gutter splitX: \(String(format:"%.3f", splitX))")
        print("  Right contentBounds: x=\(String(format:"%.3f",rightBounds.x)) y=\(String(format:"%.3f",rightBounds.y)) w=\(String(format:"%.3f",rightBounds.width)) h=\(String(format:"%.3f",rightBounds.height))")

        if let rightCrop = cropCGImage(full, rect: rightBounds) {
            print("  Right crop pixel size: \(rightCrop.width) x \(rightCrop.height)")
            // Canvas = just this one page (exporting single file), so canvasW/H = crop size.
            if let composed = composeCGImage(rightCrop, canvasW: rightCrop.width, canvasH: rightCrop.height) {
                roundTripOCR(composed, label: "app-crop round-trip")
            }
        }
    }
}
