import Foundation
import CoreText
import CoreGraphics
import AppKit

// Typesets test pages with CoreText the way old scholarly books look: justified
// text, hyphenated line ends, two columns, footnotes, running heads, folios, italic,
// small caps and polytonic Greek. Everything is drawn in points and rendered at
// 300 dpi. The truth for a page is the text actually drawn, in reading order.

enum HCKind { case roman, italic, smallcaps, greek }

struct HCPiece {
    var text: String
    var kind: HCKind
}

struct HCWord {
    var pieces: [HCPiece]
    /// What the reader sees: small caps are capitals.
    var plain: String { pieces.map { $0.kind == .smallcaps ? $0.text.uppercased() : $0.text }.joined() }
    var hasGreek: Bool { pieces.contains { $0.kind == .greek } }
}

enum HCMarkup {
    /// Splits markup (<i>, <sc>, <g>) into words; styles carry across spaces.
    static func words(_ s: String) -> [HCWord] {
        var words: [HCWord] = [], pieces: [HCPiece] = [], buffer = "", kind = HCKind.roman
        func endPiece() {
            if !buffer.isEmpty { pieces.append(HCPiece(text: buffer, kind: kind)); buffer = "" }
        }
        func endWord() {
            endPiece()
            if !pieces.isEmpty { words.append(HCWord(pieces: pieces)); pieces = [] }
        }
        let tags: [String: HCKind] = ["i": .italic, "sc": .smallcaps, "g": .greek,
                                      "/i": .roman, "/sc": .roman, "/g": .roman]
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">"),
               let next = tags[String(s[s.index(after: i)..<close])] {
                endPiece(); kind = next; i = s.index(after: close); continue
            }
            let c = s[i]
            if c == " " || c == "\n" { endWord() } else { buffer.append(c) }
            i = s.index(after: i)
        }
        endWord()
        return words
    }
}

/// The fonts of one page: Times New Roman or Palatino, with a Greek-capable face.
struct HCFonts {
    let romanName: String
    let italicName: String
    let greekName: String

    /// True when the font really is `name` (CoreText quietly substitutes another) and has
    /// the polytonic Greek letters if `needsGreek`.
    private static func usable(_ name: String, needsGreek: Bool) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        guard CTFontCopyPostScriptName(font) as String == name else { return false }
        guard needsGreek else { return true }
        var chars = Array("ἀᾳῷἄὕῥάέ".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
    }

    static func make(family: String) -> HCFonts {
        let times = ("TimesNewRomanPSMT", "TimesNewRomanPS-ItalicMT")
        let palatino = ("Palatino-Roman", "Palatino-Italic")
        let wanted = family == "palatino" ? palatino : times
        let roman = [wanted.0, times.0, "Times-Roman", "Helvetica"].first { usable($0, needsGreek: false) } ?? "Helvetica"
        let italic = [wanted.1, times.1, "Times-Italic", "Helvetica-Oblique"].first { usable($0, needsGreek: false) } ?? "Helvetica-Oblique"
        let greek = [wanted.0, times.0, "Athelas-Regular", "Helvetica"].first { usable($0, needsGreek: true) } ?? "Helvetica"
        return HCFonts(romanName: roman, italicName: italic, greekName: greek)
    }

    var summary: String { "roman \(romanName), italic \(italicName), greek \(greekName)" }

    func font(_ kind: HCKind, _ size: CGFloat) -> CTFont {
        switch kind {
        case .roman, .smallcaps: return CTFontCreateWithName(romanName as CFString, size, nil)
        case .italic: return CTFontCreateWithName(italicName as CFString, size, nil)
        case .greek: return CTFontCreateWithName(greekName as CFString, size, nil)
        }
    }
}

/// Builds and measures the attributed text of words at one size.
final class HCMeasure {
    let fonts: HCFonts
    let size: CGFloat
    private var widths: [String: CGFloat] = [:]
    lazy var space: CGFloat = width([HCPiece(text: " ", kind: .roman)], hyphen: false)

    init(fonts: HCFonts, size: CGFloat) { self.fonts = fonts; self.size = size }

    func attributed(_ pieces: [HCPiece], hyphen: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ s: String, _ font: CTFont) {
            // No ligatures: the truth is plain letters.
            out.append(NSAttributedString(string: s, attributes: [.font: font, .ligature: 0]))
        }
        for p in pieces {
            if p.kind == .smallcaps {
                for ch in p.text {
                    if ch.isLowercase { add(String(ch).uppercased(), fonts.font(.roman, size * 0.78)) }
                    else { add(String(ch), fonts.font(.roman, size)) }
                }
            } else {
                add(p.text, fonts.font(p.kind, size))
            }
        }
        if hyphen {
            let last = pieces.last?.kind ?? .roman
            add("-", fonts.font(last == .smallcaps ? .roman : last, size))
        }
        return out
    }

    func width(_ pieces: [HCPiece], hyphen: Bool) -> CGFloat {
        let key = pieces.map { "\($0.kind)|\($0.text)" }.joined(separator: "¦") + (hyphen ? "-" : "")
        if let w = widths[key] { return w }
        let line = CTLineCreateWithAttributedString(attributed(pieces, hyphen: hyphen))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        widths[key] = w
        return w
    }
}

enum HCHyphen {
    /// Offsets (in characters) where the word may break, from the system hyphenator.
    static func points(_ word: HCWord, locale: String) -> [Int] {
        let plain = word.plain
        let n = plain.utf16.count
        guard !word.hasGreek, n >= 6, n == plain.count,
              plain.first?.isLetter == true,
              plain.allSatisfy({ $0.isLetter || ",.;:".contains($0) }) else { return [] }
        let cfLocale = CFLocaleCreate(nil, CFLocaleIdentifier(locale as CFString))
        let cf = plain as CFString
        var found = Set<Int>()
        for i in 3...(n - 2) {
            let at = CFStringGetHyphenationLocationBeforeIndex(cf, i, CFRangeMake(0, n), 0, cfLocale, nil)
            if at != kCFNotFound { found.insert(at) }
        }
        return found.sorted()
    }

    /// The word cut after `k` characters.
    static func split(_ word: HCWord, at k: Int) -> (HCWord, HCWord) {
        var left: [HCPiece] = [], right: [HCPiece] = [], seen = 0
        for p in word.pieces {
            let n = p.text.count
            if seen + n <= k { left.append(p) }
            else if seen >= k { right.append(p) }
            else {
                let cut = p.text.index(p.text.startIndex, offsetBy: k - seen)
                left.append(HCPiece(text: String(p.text[..<cut]), kind: p.kind))
                right.append(HCPiece(text: String(p.text[cut...]), kind: p.kind))
            }
            seen += n
        }
        return (HCWord(pieces: left), HCWord(pieces: right))
    }
}

struct HCPara {
    var markup: String
    var size: CGFloat = 11.5
    var leading: CGFloat = 14.5
    var justify = true
    var hyphenate = true
    var indent: CGFloat = 14
    var center = false
    var before: CGFloat = 0
    var locale = "en"
}

struct HCItem {
    var pieces: [HCPiece]
    var plain: String
    /// The word goes on in the next item with no space (a hyphenated line end).
    var joinNext: Bool
    var hyphen: Bool
    var width: CGFloat
}

struct HCLine {
    var items: [HCItem]
    var indent: CGFloat
    var gap: CGFloat
    var para: Int
    var first: Bool
}

enum HCLayout {
    /// Greedy line breaking with hyphenation, justified to `width`.
    static func breakLines(_ para: HCPara, index: Int, width: CGFloat, fonts: HCFonts) -> [HCLine] {
        let measure = HCMeasure(fonts: fonts, size: para.size)
        var queue = HCMarkup.words(para.markup)
        var lines: [HCLine] = [], current: [HCItem] = [], currentWidth: CGFloat = 0
        let space = measure.space

        func available() -> CGFloat { width - (lines.isEmpty ? para.indent : 0) }
        func flush(last: Bool) {
            guard !current.isEmpty else { return }
            var gap = space
            if para.justify && !last && current.count > 1 {
                gap = (available() - current.reduce(0) { $0 + $1.width }) / CGFloat(current.count - 1)
            }
            lines.append(HCLine(items: current, indent: lines.isEmpty ? para.indent : 0,
                                gap: gap, para: index, first: lines.isEmpty))
            current = []; currentWidth = 0
        }

        var i = 0
        while i < queue.count {
            let word = queue[i]
            let w = measure.width(word.pieces, hyphen: false)
            let needed = current.isEmpty ? w : currentWidth + space + w
            if current.isEmpty || needed <= available() {
                current.append(HCItem(pieces: word.pieces, plain: word.plain, joinNext: false, hyphen: false, width: w))
                currentWidth = needed
                i += 1
                continue
            }
            let room = available() - currentWidth - space
            var cut: (HCWord, HCWord, CGFloat, Int)?
            if para.hyphenate {
                let n = word.plain.count
                for k in HCHyphen.points(word, locale: para.locale).reversed() where k >= 2 && n - k >= 3 {
                    let (pre, post) = HCHyphen.split(word, at: k)
                    let preWidth = measure.width(pre.pieces, hyphen: true)
                    if preWidth <= room { cut = (pre, post, preWidth, k); break }
                }
            }
            if let (pre, post, preWidth, _) = cut {
                current.append(HCItem(pieces: pre.pieces, plain: pre.plain, joinNext: true, hyphen: true, width: preWidth))
                queue[i] = post
            }
            flush(last: false)
        }
        flush(last: true)
        return lines
    }
}

struct HCPageSpec {
    var number: Int
    var kind: String
    var family: String
    var size: CGSize                       // points
    var margins = (left: CGFloat(52), right: CGFloat(52), top: CGFloat(62), bottom: CGFloat(66))
    var columns = 1
    var gutter: CGFloat = 18
    var body: [HCPara]
    var head: String?
    var folio: String?
    var footnotes: [String] = []
}

struct HCRendered {
    var image: CGImage            // 8-bit gray, 300 dpi
    var pixels: [UInt8]           // the same, row 0 at the top
    var truth: [String]           // paragraphs, in reading order
    var fonts: String
}

enum HCTypeset {
    static let dpi: CGFloat = 300
    private static let superscripts = ["¹", "²", "³"]

    static func render(_ spec: HCPageSpec) -> HCRendered {
        let fonts = HCFonts.make(family: spec.family)
        let scale = dpi / 72
        let pxW = Int((spec.size.width * scale).rounded()), pxH = Int((spec.size.height * scale).rounded())
        let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: pxW,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldAntialias(true)
        ctx.textMatrix = .identity

        let pageH = spec.size.height
        let textWidth = spec.size.width - spec.margins.left - spec.margins.right
        let columnWidth = (textWidth - spec.gutter * CGFloat(spec.columns - 1)) / CGFloat(spec.columns)

        func drawLine(_ line: HCLine, para: HCPara, x0: CGFloat, width: CGFloat, baselineFromTop: CGFloat) {
            let measure = HCMeasure(fonts: fonts, size: para.size)
            var x = x0
            var gap = line.gap
            if para.center {
                let total = line.items.reduce(0) { $0 + $1.width } + measure.space * CGFloat(line.items.count - 1)
                x = x0 + (width - total) / 2
                gap = measure.space
            } else {
                x += line.indent
            }
            for item in line.items {
                let ct = CTLineCreateWithAttributedString(measure.attributed(item.pieces, hyphen: item.hyphen))
                ctx.textPosition = CGPoint(x: x, y: pageH - baselineFromTop)
                CTLineDraw(ct, ctx)
                x += item.width + gap
            }
        }
        func text(_ lines: [HCLine]) -> String {
            var out = ""
            for line in lines {
                for item in line.items {
                    out += item.plain
                    if !item.joinNext { out += " " }
                }
            }
            return out.trimmingCharacters(in: .whitespaces)
        }

        var truthHead: [String] = [], truthFoot: [String] = [], truthFolio: [String] = []

        // Running head and folio.
        if let head = spec.head {
            let para = HCPara(markup: head, size: 9.5, leading: 12, justify: false, hyphenate: false, indent: 0, center: true)
            let lines = HCLayout.breakLines(para, index: 0, width: textWidth, fonts: fonts)
            for l in lines { drawLine(l, para: para, x0: spec.margins.left, width: textWidth, baselineFromTop: spec.margins.top - 24) }
            truthHead.append(text(lines))
        }
        if let folio = spec.folio {
            let para = HCPara(markup: folio, size: 10, leading: 12, justify: false, hyphenate: false, indent: 0, center: true)
            let lines = HCLayout.breakLines(para, index: 0, width: textWidth, fonts: fonts)
            for l in lines { drawLine(l, para: para, x0: spec.margins.left, width: textWidth, baselineFromTop: pageH - spec.margins.bottom + 26) }
            truthFolio.append(text(lines))
        }

        // Footnotes, at the foot of the text block.
        var footBlock: CGFloat = 0
        var footParas: [HCPara] = [], footLines: [[HCLine]] = []
        for (k, note) in spec.footnotes.enumerated() {
            let para = HCPara(markup: "\(superscripts[k % 3]) \(note)", size: 8.5, leading: 10.5, indent: 10)
            footParas.append(para)
            let lines = HCLayout.breakLines(para, index: k, width: textWidth, fonts: fonts)
            footLines.append(lines)
            footBlock += CGFloat(lines.count) * para.leading
        }
        if !footParas.isEmpty {
            let top = pageH - spec.margins.bottom - footBlock
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: spec.margins.left, y: pageH - (top - 6)))
            ctx.addLine(to: CGPoint(x: spec.margins.left + textWidth * 0.28, y: pageH - (top - 6)))
            ctx.strokePath()
            var cursor = top
            for (k, lines) in footLines.enumerated() {
                let para = footParas[k]
                for l in lines {
                    cursor += para.leading
                    drawLine(l, para: para, x0: spec.margins.left, width: textWidth, baselineFromTop: cursor - 2.8)
                }
                truthFoot.append(text(lines))
            }
            footBlock += 14
        }

        // Body, poured down each column in turn.
        var all: [(HCLine, HCPara)] = []
        for (k, para) in spec.body.enumerated() {
            for l in HCLayout.breakLines(para, index: k, width: columnWidth, fonts: fonts) { all.append((l, para)) }
        }
        let bodyTop = spec.margins.top
        let bodyBottom = pageH - spec.margins.bottom - footBlock
        var placed: [(line: HCLine, para: HCPara, column: Int, baseline: CGFloat)] = []
        var column = 0, cursor = bodyTop
        for (line, para) in all {
            var before = (line.first && cursor > bodyTop) ? para.before : 0
            if cursor + before + para.leading > bodyBottom {
                column += 1; cursor = bodyTop; before = 0
                if column >= spec.columns { break }
            }
            cursor += before + para.leading
            placed.append((line, para, column, cursor - ((para.leading - para.size) / 2 + para.size * 0.22)))
        }
        // A last line that ends in half a word would leave the word unfinished.
        if let last = placed.last, last.line.items.last?.joinNext == true { placed.removeLast() }
        var byPara: [Int: [HCLine]] = [:]
        for p in placed {
            drawLine(p.line, para: p.para, x0: spec.margins.left + CGFloat(p.column) * (columnWidth + spec.gutter),
                     width: columnWidth, baselineFromTop: p.baseline)
            byPara[p.line.para, default: []].append(p.line)
        }
        let truthBody = byPara.keys.sorted().map { text(byPara[$0]!) }

        var pixels = [UInt8](repeating: 255, count: pxW * pxH)
        if let data = ctx.data {
            let rowBytes = ctx.bytesPerRow
            for y in 0..<pxH {
                let row = data.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<pxW { pixels[y * pxW + x] = row[x] }
            }
        }
        return HCRendered(image: ctx.makeImage()!, pixels: pixels,
                          truth: truthHead + truthBody + truthFoot + truthFolio.filter { !$0.isEmpty },
                          fonts: fonts.summary)
    }
}
