import Foundation
import AppKit
import CoreGraphics
import CoreText

/// Synthetic scan-like pages with known truth, for the hill-climb split/crop score.
/// Everything comes from a fixed seed, so two runs draw the same pages.
///
/// A page is a `SynthSpec`: the layout (paper, fold, every printed item) plus the
/// distractors. `HCSynth.render` draws it as a scan, or as a black-on-white mask of
/// the print or the paper of one leaf. The masks go through the same tilt as the scan,
/// so the score can ask: after the app straightens and cuts the page, is every
/// printed pixel still inside its page's crop?

enum SynthItem {
    case word(String, font: String, size: CGFloat, x: CGFloat, baseline: CGFloat)
    case rule(CGRect)
    case plate(CGRect, shade: CGFloat)
}

struct SynthLeaf {
    var paper: CGRect          // top-left origin, before the tilt
    var items: [SynthItem]
    var blank: Bool
}

enum SynthShadow {
    case none
    case soft(depth: Double, sigma: Double)
    case hard(depth: Double, half: Double, fall: Double)
}

struct SynthSpec {
    var book = 0, index = 0
    var isSpread = true
    var W = 0, H = 0
    var bed: CGFloat = 0.1
    var paperTone: CGFloat = 0.9
    var inkGray: CGFloat = 0.15
    var tiltDegrees = 0.0
    var leaves: [SynthLeaf] = []
    var foldX: CGFloat = 0                   // before the tilt; spreads
    var foldTruth = 0.5                      // after the tilt, at mid height, as a share of the width
    var shadow = SynthShadow.none
    var shadowX: CGFloat = 0                 // centre of the shadow, in the scan
    var foldLine: (gray: CGFloat, width: CGFloat)?
    var binding: (spiral: Bool, x: CGFloat, pitch: CGFloat, size: CGFloat)?
    var neighbour: (onLeft: Bool, width: CGFloat, gray: CGFloat)?
    var gradX = 0.0, gradY = 0.0, noise = 3.0
    var seed: UInt64 = 0
    var tags: [String] = []
    var paperRows: ClosedRange<CGFloat> = 0...0   // paper's top and bottom (before the tilt)
}

struct SynthBook {
    var number: Int
    var specs: [SynthSpec]
}

enum SynthLayer { case scan, print(Int), paper(Int) }

enum HCSynth {

    // MARK: Text

    static let words = ["substance", "motion", "nature", "potency", "act", "the", "of", "and", "in", "that", "which",
        "is", "it", "principle", "cause", "being", "matter", "form", "change", "physics", "Aristotle", "hence",
        "therefore", "moreover", "however", "whereas", "thus", "quantity", "quality", "relation", "place", "time",
        "void", "infinite", "continuum", "body", "soul", "knowledge", "science", "demonstration", "definition",
        "genus", "species", "differentia", "accident", "essence", "existence", "argument", "premise", "conclusion",
        "syllogism", "universal", "particular", "motion,", "is", "a", "an", "to", "by", "from", "with", "not", "for",
        "as", "are", "was", "be", "its", "this", "these", "those", "there", "their", "has", "have", "can", "must",
        "λόγος", "φύσις", "ἐπιστήμη", "(see", "p.", "1950", "1943", "quod", "ens", "esse", "ergo", "gravity",
        "falling", "projectile", "experiment", "hypothesis", "Galileo", "Newton", "inertia", "velocity",
        "acceleration", "proportion", "geometry", "philosophy", "judgment", "judgments", "judgment;", "jug", "quay",
        "pygmy", "fifty", "whole", "parts", "analysis", "synthesis", "question", "answer", "difference", "likeness"]
    static let heads = ["ARISTOTLE ON NATURE", "THE PRINCIPLES OF MOTION", "MATTER AND FORM", "LOGIC AND SCIENCE",
                        "PHILOSOPHICAL PHYSICS", "THE CONTINUUM", "NOTES"]
    static let endings = ["", "", "", "", ",", ",", ".", ";", ")"]

    nonisolated(unsafe) private static var widthCache: [String: CGFloat] = [:]
    nonisolated(unsafe) private static var fontCache: [String: CTFont] = [:]

    static func font(_ name: String, _ size: CGFloat) -> CTFont {
        let key = "\(name)|\(size)"
        if let f = fontCache[key] { return f }
        let f = CTFontCreateWithName(name as CFString, size, nil)
        fontCache[key] = f
        return f
    }

    static func line(_ text: String, _ name: String, _ size: CGFloat) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(name, size),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    static func width(_ text: String, _ name: String, _ size: CGFloat) -> CGFloat {
        let key = "\(name)|\(size)|\(text)"
        if let w = widthCache[key] { return w }
        let w = CGFloat(CTLineGetTypographicBounds(line(text, name, size), nil, nil, nil))
        widthCache[key] = w
        return w
    }

    // MARK: Layout

    struct BookParams {
        var leaf: CGFloat, height: CGFloat
        var inner: CGFloat, outer: CGFloat, top: CGFloat, bottom: CGFloat
        var size: CGFloat, leading: CGFloat
        var head: String
    }

    enum Side { case left, right, only }
    enum PageStyle { case full, short, opener, plate, blank }
    struct Flags {
        var nearGutter = false, margNums = false, frame = false, head = true, folio = true, footnote = false
        var rule = false
    }

    /// The printed items of one leaf. Never outside `paper`'s margins.
    static func leafItems(paper: CGRect, side: Side, p: BookParams, style: PageStyle, flags: Flags,
                          page: Int, rng: inout HCRandom) -> [SynthItem] {
        guard style != .blank else { return [] }
        var items: [SynthItem] = []
        let innerLeft = side != .left      // the fold is on this leaf's left
        let x0 = paper.minX + (innerLeft ? p.inner : p.outer)
        let x1 = paper.maxX - (innerLeft ? p.outer : p.inner)
        let tw = x1 - x0
        var y0 = paper.minY + p.top
        let y1 = paper.maxY - p.bottom
        let size = p.size, pitch = size * p.leading
        let body = "Times-Roman"

        // Running head and folio.
        let gap = CGFloat(rng.range(8, 22))
        func place(_ text: String, _ fontName: String, _ fsize: CGFloat, baseline: CGFloat) {
            let w = width(text, fontName, fsize)
            var x: CGFloat
            if flags.nearGutter && side != .only {
                x = innerLeft ? paper.minX + gap : paper.maxX - gap - w
            } else {
                switch Int(rng.next() % 3) {
                case 0: x = (x0 + x1) / 2 - w / 2
                case 1: x = innerLeft ? x1 - w : x0                     // at the outer edge
                default: x = innerLeft ? x0 : x1 - w                     // at the inner edge
                }
            }
            x = max(paper.minX + 6, min(x, paper.maxX - 6 - w))
            items.append(.word(text, font: fontName, size: fsize, x: x, baseline: baseline))
        }
        if flags.head {
            place(p.head, "Times-Roman", 11, baseline: paper.minY + p.top - 26)
            if flags.rule {
                items.append(.rule(CGRect(x: x0, y: paper.minY + p.top - 18, width: tw, height: 1)))
            }
        }
        if flags.folio { place(String(page), "Times-Roman", 12, baseline: y1 + 34) }

        var firstBaseline = y0 + size * 0.85
        var lastY = y1
        switch style {
        case .opener:
            let title = "CHAPTER \(rng.int(1, 12))"
            let tsize: CGFloat = 26
            let w = width(title, "Times-Bold", tsize)
            items.append(.word(title, font: "Times-Bold", size: tsize, x: (x0 + x1) / 2 - w / 2, baseline: y0 + 70))
            y0 += 130
            firstBaseline = y0 + size * 0.85
        case .plate:
            let pw = tw * CGFloat(rng.range(0.6, 1.0)), ph = (y1 - y0) * CGFloat(rng.range(0.3, 0.65))
            let px = x0 + (tw - pw) * CGFloat(rng.unit())
            let rect = CGRect(x: px, y: y0 + 10, width: pw, height: ph)
            items.append(.plate(rect, shade: CGFloat(rng.range(0.12, 0.45))))
            let cap = "Fig. \(rng.int(1, 40)). Motion of a body"
            items.append(.word(cap, font: "Times-Italic", size: size - 1, x: px, baseline: rect.maxY + 22))
            y0 = rect.maxY + 40
            firstBaseline = y0 + size * 0.85
        default: break
        }
        if flags.footnote {
            let fsize = max(9, size - 3)
            let fy = y1 - 3 * fsize * 1.25 - 6
            items.append(.rule(CGRect(x: x0, y: fy - 8, width: min(110, tw * 0.3), height: 1)))
            for k in 0..<3 {
                var t = "\(k + 1) See "
                for _ in 0..<rng.int(5, 8) { t += rng.pick(words) + " " }
                var s = t
                while width(s, body, fsize) > tw, let sp = s.lastIndex(of: " ") { s = String(s[..<sp]) }
                items.append(.word(s, font: body, size: fsize, x: x0, baseline: fy + CGFloat(k + 1) * fsize * 1.25))
            }
            lastY = fy - 14
        }

        var nLines = max(0, Int((lastY - (firstBaseline - size * 0.85)) / pitch))
        if style == .short { nLines = min(nLines, rng.int(6, max(7, nLines - 4))) }
        var paragraph = 0
        for k in 0..<nLines {
            let baseline = firstBaseline + CGFloat(k) * pitch
            let indent: CGFloat = paragraph == 0 ? 16 : 0
            // Fill the line with words.
            var chosen: [(String, String)] = []   // text, font
            var used = indent
            let space = width(" ", body, size)
            let lastOfParagraph = rng.chance(0.09) || k == nLines - 1
            let target = lastOfParagraph ? tw * CGFloat(rng.range(0.25, 0.85)) : tw
            while true {
                let word = rng.pick(words) + rng.pick(endings)
                let fontName = rng.chance(0.1) ? "Times-Italic" : body
                let w = width(word, fontName, size)
                if used + w > target { break }
                chosen.append((word, fontName)); used += w + space
                if chosen.count > 40 { break }
            }
            if chosen.isEmpty { chosen.append((rng.pick(words), body)) }
            let sum = chosen.reduce(CGFloat(0)) { $0 + width($1.0, $1.1, size) }
            let gaps = max(1, chosen.count - 1)
            let step = lastOfParagraph || chosen.count == 1 ? space : (tw - indent - sum) / CGFloat(gaps)
            var x = x0 + indent
            for (text, fontName) in chosen {
                items.append(.word(text, font: fontName, size: size, x: x, baseline: baseline))
                x += width(text, fontName, size) + max(step, 1)
            }
            paragraph = lastOfParagraph ? 0 : paragraph + 1
            if flags.margNums && (k + 1) % 5 == 0 {
                let t = String(k + 1)
                let w = width(t, body, 9)
                let off = CGFloat(rng.range(8, 20))
                let x = innerLeft ? paper.maxX - off - w : paper.minX + off
                items.append(.word(t, font: body, size: 9, x: x, baseline: baseline))
            }
        }
        if flags.frame {
            let t = CGFloat(rng.int(1, 2)), m: CGFloat = 12
            let f = CGRect(x: x0 - m, y: paper.minY + p.top - m, width: tw + 2 * m, height: y1 - paper.minY - p.top + 2 * m)
            items += [.rule(CGRect(x: f.minX, y: f.minY, width: f.width, height: t)),
                      .rule(CGRect(x: f.minX, y: f.maxY - t, width: f.width, height: t)),
                      .rule(CGRect(x: f.minX, y: f.minY, width: t, height: f.height)),
                      .rule(CGRect(x: f.maxX - t, y: f.minY, width: t, height: f.height))]
        }
        return items
    }

    // MARK: Books

    /// `pages` pages: the first is a single (a title page); a share of the rest are
    /// singles, plates and blanks; the rest are spreads.
    static func book(_ number: Int, pages: Int) -> SynthBook {
        var rng = HCRandom(UInt64(20_261_119 + number * 7919))
        let p = BookParams(leaf: CGFloat(rng.range(600, 690)), height: CGFloat(rng.range(880, 990)),
                           inner: CGFloat(rng.range(40, 70)), outer: CGFloat(rng.range(58, 88)),
                           top: CGFloat(rng.range(70, 96)), bottom: CGFloat(rng.range(82, 106)),
                           size: CGFloat(rng.int(12, 16)), leading: CGFloat(rng.range(1.3, 1.45)),
                           head: rng.pick(heads))
        let baseBed = CGFloat(rng.range(0.04, 0.14))
        let baseTone = CGFloat(rng.range(0.82, 0.94))
        var specs: [SynthSpec] = []
        for i in 0..<pages {
            var s = SynthSpec()
            s.book = number; s.index = i
            s.seed = rng.next()
            let singleChance = i == 0 ? 1.0 : 0.13
            s.isSpread = !rng.chance(singleChance)
            let w0 = p.leaf + CGFloat(rng.range(-6, 6))
            var tags: [String] = []

            // Bed bands (scanner bed showing round the paper), and a neighbouring leaf's edge.
            let bedBands = rng.chance(0.6)
            func margin() -> CGFloat { bedBands && rng.chance(0.75) ? CGFloat(rng.int(4, 38)) : CGFloat(rng.int(0, 2)) }
            var mL = margin(), mR = margin(), mT = margin(), mB = margin()
            if bedBands && (mL > 3 || mR > 3 || mT > 3 || mB > 3) { tags.append("bedBands") }
            s.bed = baseBed
            if bedBands && rng.chance(0.14) { s.bed = 0.97; tags.append("whiteBed") }
            if rng.chance(0.12) {
                let onLeft = rng.chance(0.5)
                let nw = CGFloat(rng.int(10, 30))
                s.neighbour = (onLeft, nw, baseTone + CGFloat(rng.range(-0.05, 0.05)))
                if onLeft { mL = nw + 2 + CGFloat(rng.int(0, 6)) } else { mR = nw + 2 + CGFloat(rng.int(0, 6)) }
                tags.append("neighbour")
            }
            s.paperTone = baseTone + CGFloat(rng.range(-0.03, 0.03))
            s.inkGray = CGFloat(rng.range(0.08, 0.24))
            let unevenTone = rng.chance(0.6)
            if unevenTone { s.gradX = rng.range(-0.08, 0.08); s.gradY = rng.range(-0.08, 0.08); tags.append("uneven") }
            s.noise = rng.range(1.5, 5)

            // Tilt.
            s.tiltDegrees = rng.chance(0.2) ? 0 : rng.range(-1.5, 1.5)
            if abs(s.tiltDegrees) > 0.5 { tags.append("tilt") }

            let paperH = p.height + CGFloat(rng.range(-8, 8))
            s.W = Int(mL + w0 * (s.isSpread ? 2 : 1) + mR)
            s.H = Int(mT + paperH + mB)
            let top = mT, bottom = mT + paperH
            s.paperRows = top...bottom

            // Flags shared by the page.
            var flags = Flags()
            flags.nearGutter = s.isSpread && rng.chance(0.25)
            flags.margNums = rng.chance(0.2)
            flags.frame = rng.chance(0.18)
            flags.head = rng.chance(0.85)
            flags.folio = rng.chance(0.9)
            flags.footnote = rng.chance(0.2)
            flags.rule = rng.chance(0.5)
            if flags.nearGutter { tags.append("nearGutter") }
            if flags.margNums { tags.append("marginalNumbers") }
            if flags.frame { tags.append("frame") }
            if flags.footnote { tags.append("footnote") }

            func style(blankChance: Double) -> PageStyle {
                if rng.chance(blankChance) { return .blank }
                let r = rng.unit()
                return r < 0.12 ? .opener : r < 0.22 ? .plate : r < 0.38 ? .short : .full
            }
            let page = i * 2
            if s.isSpread {
                let left = CGRect(x: mL, y: top, width: w0, height: paperH)
                let right = CGRect(x: mL + w0, y: top, width: w0, height: paperH)
                s.foldX = mL + w0
                let ls = style(blankChance: 0.07), rs = style(blankChance: 0.07)
                s.leaves = [
                    SynthLeaf(paper: left, items: leafItems(paper: left, side: .left, p: p, style: ls, flags: flags, page: page, rng: &rng), blank: ls == .blank),
                    SynthLeaf(paper: right, items: leafItems(paper: right, side: .right, p: p, style: rs, flags: flags, page: page + 1, rng: &rng), blank: rs == .blank),
                ]
                if ls == .blank || rs == .blank { tags.append("blankSide") }
                if ls == .plate || rs == .plate { tags.append("plate") }
                // Where the fold ends up after the tilt, at the paper's middle.
                let cx = Double(s.W) / 2, cy = Double(s.H) / 2
                let th = s.tiltDegrees * .pi / 180
                let my = Double(top + paperH / 2)
                let fx = cx + cos(th) * (Double(s.foldX) - cx) - sin(th) * (my - cy)
                s.foldTruth = fx / Double(s.W)
                s.shadowX = CGFloat(fx)
            } else {
                let paper = CGRect(x: mL, y: top, width: w0, height: paperH)
                let st = style(blankChance: i == 0 ? 0.0 : 0.15)
                let st2: PageStyle = i == 0 ? .opener : st
                s.leaves = [SynthLeaf(paper: paper, items: leafItems(paper: paper, side: .only, p: p, style: st2, flags: flags, page: page, rng: &rng), blank: st2 == .blank)]
                if st2 == .blank { tags.append("blankSingle") }
                if st2 == .plate { tags.append("plate") }
                s.shadowX = rng.chance(0.5) ? paper.minX : paper.maxX
            }

            // Fold shadow, crease, binding marks.
            let r = rng.unit()
            if r < 0.28 { s.shadow = .soft(depth: rng.range(0.35, 0.6), sigma: rng.range(28, 55)); tags.append("shadowSoft") }
            else if r < 0.48 { s.shadow = .hard(depth: rng.range(0.6, 0.85), half: rng.range(6, 16), fall: rng.range(5, 9)); tags.append("shadowHard") }
            if s.isSpread && rng.chance(0.2) {
                s.foldLine = (CGFloat(rng.range(0.12, 0.35)), CGFloat(rng.int(2, 5))); tags.append("foldLine")
            }
            if rng.chance(0.18) {
                let spiral = rng.chance(0.5)
                s.binding = (spiral, s.isSpread ? s.foldX + CGFloat(rng.range(-26, 26)) : s.leaves[0].paper.minX + 18,
                             CGFloat(rng.range(24, 34)), CGFloat(rng.range(8, 13)))
                tags.append(spiral ? "spiral" : "comb")
            }
            s.tags = tags
            specs.append(s)
        }
        return SynthBook(number: number, specs: specs)
    }

    // MARK: Drawing

    static func render(_ s: SynthSpec, _ layer: SynthLayer) -> CGImage? {
        let W = s.W, H = s.H
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        var isScan = false
        switch layer {
        case .scan: isScan = true; ctx.setFillColor(gray: s.bed, alpha: 1)
        default: ctx.setFillColor(gray: 1, alpha: 1)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // Top-left origin, then the tilt about the middle of the scan.
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(W) / 2, y: CGFloat(H) / 2)
        ctx.rotate(by: CGFloat(s.tiltDegrees * .pi / 180))
        ctx.translateBy(x: -CGFloat(W) / 2, y: -CGFloat(H) / 2)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldAntialias(true)

        func draw(_ items: [SynthItem], ink: CGFloat, plateOverride: CGFloat?) {
            for item in items {
                switch item {
                case .word(let text, let name, let size, let x, let baseline):
                    ctx.setFillColor(gray: ink, alpha: 1)
                    ctx.textPosition = CGPoint(x: x, y: baseline)
                    CTLineDraw(line(text, name, size), ctx)
                case .rule(let r):
                    ctx.setFillColor(gray: ink, alpha: 1)
                    ctx.fill(r)
                case .plate(let r, let shade):
                    ctx.setFillColor(gray: plateOverride ?? shade, alpha: 1)
                    ctx.fill(r)
                }
            }
        }

        switch layer {
        case .paper(let k):
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(s.leaves[k].paper)
            return ctx.makeImage()
        case .print(let k):
            draw(s.leaves[k].items, ink: 0, plateOverride: 0)
            return ctx.makeImage()
        case .scan: break
        }

        // The neighbouring leaf's edge, then the paper.
        if let n = s.neighbour {
            let first = s.leaves.first!.paper, last = s.leaves.last!.paper
            ctx.setFillColor(gray: n.gray, alpha: 1)
            if n.onLeft {
                ctx.fill(CGRect(x: first.minX - n.width - 2, y: -200, width: n.width, height: CGFloat(H) + 400))
                ctx.setFillColor(gray: 0.2, alpha: 1)
                ctx.fill(CGRect(x: first.minX - 2, y: -200, width: 2, height: CGFloat(H) + 400))
            } else {
                ctx.fill(CGRect(x: last.maxX + 2, y: -200, width: n.width, height: CGFloat(H) + 400))
                ctx.setFillColor(gray: 0.2, alpha: 1)
                ctx.fill(CGRect(x: last.maxX, y: -200, width: 2, height: CGFloat(H) + 400))
            }
        }
        for (k, leaf) in s.leaves.enumerated() {
            ctx.setFillColor(gray: s.paperTone + (k == 1 ? 0.01 : 0), alpha: 1)
            ctx.fill(leaf.paper)
        }
        if let f = s.foldLine {
            ctx.setFillColor(gray: f.gray, alpha: 1)
            ctx.fill(CGRect(x: s.foldX - f.width / 2, y: s.paperRows.lowerBound, width: f.width,
                            height: s.paperRows.upperBound - s.paperRows.lowerBound))
        }
        if let b = s.binding {
            ctx.setFillColor(gray: 0.12, alpha: 1)
            var y = s.paperRows.lowerBound + 14
            while y < s.paperRows.upperBound - 14 {
                if b.spiral { ctx.fillEllipse(in: CGRect(x: b.x - b.size / 2, y: y, width: b.size, height: b.size)) }
                else { ctx.fill(CGRect(x: b.x - b.size / 2, y: y, width: b.size, height: b.size * 1.8)) }
                y += b.pitch
            }
        }
        for leaf in s.leaves { draw(leaf.items, ink: s.inkGray, plateOverride: nil) }

        // Shading, tone drift and grain, in the scan's own frame.
        guard let data = ctx.data else { return ctx.makeImage() }
        let stride = ctx.bytesPerRow
        let px = data.assumingMemoryBound(to: UInt8.self)
        let seed = s.seed
        let gx = s.gradX, gy = s.gradY
        // Shadow per column.
        var column = [Double](repeating: 1, count: W)
        for x in 0..<W {
            let d = Double(CGFloat(x) - s.shadowX)
            switch s.shadow {
            case .none: column[x] = 1
            case .soft(let depth, let sigma): column[x] = 1 - depth * exp(-(d / sigma) * (d / sigma))
            case .hard(let depth, let half, let fall):
                let a = abs(d)
                column[x] = 1 - depth * (a <= half ? 1 : exp(-(a - half) / fall))
            }
            column[x] *= 1 + gx * (Double(x) / Double(W) - 0.5)
        }
        let noiseAmp = s.noise
        for y in 0..<H {
            let rowFactor = 1 + gy * (Double(y) / Double(H) - 0.5)
            let row = px + y * stride
            for x in 0..<W {
                var h = (UInt64(x) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(y) &* 0xC2B2_AE3D_27D4_EB4F) ^ seed
                h ^= h >> 29; h = h &* 0xBF58_476D_1CE4_E5B9; h ^= h >> 32
                let n = (Double(h & 0xFF) - 127.5) / 127.5 * noiseAmp
                let v = Double(row[x]) * column[x] * rowFactor + n
                row[x] = UInt8(max(0, min(255, v.rounded())))
            }
        }
        _ = isScan
        return ctx.makeImage()
    }

    /// Write a book's scans as one PDF, each page sized so a 110 DPI render gives the scan's pixels.
    static func writePDF(_ book: SynthBook, to url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return false }
        for s in book.specs {
            autoreleasepool {
                guard let image = render(s, .scan) else { return }
                var page = CGRect(x: 0, y: 0, width: Double(s.W) * 72 / 110, height: Double(s.H) * 72 / 110)
                ctx.beginPage(mediaBox: &page)
                ctx.draw(image, in: page)
                ctx.endPage()
            }
        }
        ctx.closePDF()
        return true
    }
}
