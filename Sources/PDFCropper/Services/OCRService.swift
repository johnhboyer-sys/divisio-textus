import Foundation
import Vision
import CoreGraphics
import CoreImage
import AppKit

/// Runs Apple's Vision text recognizer over a page image and returns the
/// recognized lines with their boxes. Used to build an invisible, searchable
/// text layer in the exported PDF.
enum OCRService {

    /// One recognized line. `box` is normalized [0,1] with a BOTTOM-LEFT origin
    /// (Vision's native convention), which matches PDF user space directly.
    struct Line {
        let text: String
        let box: CGRect
        /// Each word of `text` (split at spaces) with its own box, in the same
        /// coordinates as `box`; empty when Vision didn't box every word.
        var words: [Word] = []
    }

    struct Word {
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
            return recognizeWhole(cgImage, languages: languages).map { Recognition(lines: onInk($0, in: cgImage), complete: true) }
        }

        let imgW = CGFloat(cgImage.width), imgH = CGFloat(cgImage.height)
        // Block rects are normalized TOP-LEFT; CGImage.cropping is top-left too.
        let rects = blocks.map {
            CGRect(x: $0.minX * imgW, y: $0.minY * imgH, width: $0.width * imgW, height: $0.height * imgH)
        }
        let margin = (0.025 * imgW).rounded()
        var result: [Line] = []
        var failedBlocks = 0
        for (i, px) in rects.enumerated() {
            let widened = widen(px, by: margin, in: cgImage, apartFrom: rects.enumerated().filter { $0.offset != i }.map(\.element))
            let clamped = widened.integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
                  let crop = cgImage.cropping(to: clamped),
                  let sub = padded(crop, by: margin) else { continue }

            // Translate each padded-block box (Vision's bottom-left normalized) back
            // into full-page bottom-left normalized coordinates.
            let subW = CGFloat(sub.width), subH = CGFloat(sub.height)
            let pageBottom = imgH - clamped.maxY       // the crop's bottom edge, in pixels
            guard let lines = recognizeWhole(sub, languages: languages) else {
                failedBlocks += 1
                continue
            }
            func onPage(_ box: CGRect) -> CGRect {
                CGRect(x: (clamped.minX - margin + box.minX * subW) / imgW,
                       y: (pageBottom - margin + box.minY * subH) / imgH,
                       width: box.width * subW / imgW,
                       height: box.height * subH / imgH)
            }
            for line in lines {
                result.append(Line(text: line.text, box: onPage(line.box),
                                   words: line.words.map { Word(text: $0.text, box: onPage($0.box)) }))
            }
        }
        // Nothing read at all counts as a failed page; otherwise keep what was read.
        if failedBlocks > 0 && result.isEmpty { return nil }
        return Recognition(lines: onInk(result, in: cgImage), complete: failedBlocks == 0)
    }

    /// Each word's box trimmed sideways to its ink. Vision's start about a quarter
    /// of the line's height left of the ink, which left too small a gap between
    /// two table cells: readers ran their words together ("isThat" on Wallace 1957).
    private static func onInk(_ lines: [Line], in image: CGImage) -> [Line] {
        guard lines.contains(where: { !$0.words.isEmpty }),
              let g = GrayBuffer(cgImage: image, maxDim: max(image.width, image.height)) else { return lines }
        return lines.map { line in
            Line(text: line.text, box: line.box,
                 words: line.words.map { Word(text: $0.text, box: inkColumns(of: $0.box, in: g) ?? $0.box) })
        }
    }

    /// `box` (normalized, bottom-left) narrowed to its first and last columns with ink.
    private static func inkColumns(of box: CGRect, in g: GrayBuffer) -> CGRect? {
        let w = Double(g.width), h = Double(g.height)
        let x0 = max(0, Int(box.minX * w)), x1 = min(g.width, Int((box.maxX * w).rounded(.up)))
        let y0 = max(0, Int((1 - box.maxY) * h)), y1 = min(g.height, Int(((1 - box.minY) * h).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        func inked(_ x: Int) -> Bool { (y0..<y1).contains { g.value(x, $0) < 128 } }
        guard let first = (x0..<x1).first(where: inked), let last = (x0..<x1).last(where: inked) else { return nil }
        return CGRect(x: Double(first) / w, y: box.minY, width: Double(last + 1 - first) / w, height: box.height)
    }

    /// Blocks are cropped tight to their ink and can cut off a line's last letters
    /// ("caus" for "cause"); Vision also misreads letters that touch an image's edge
    /// ("gencrally" for "generally" on Wallace 1957). So each block is widened into
    /// the page by `margin`, then given a white border of `margin` too. It never
    /// goes past the whitest column between it and a block beside it (halfway, on a
    /// table's narrow gutter, can take in the next column's clipped letters), nor
    /// past halfway to a block above or below (or corner to corner).
    private static func widen(_ r: CGRect, by margin: CGFloat, in image: CGImage, apartFrom others: [CGRect]) -> CGRect {
        var x0 = r.minX - margin, x1 = r.maxX + margin, y0 = r.minY - margin, y1 = r.maxY + margin
        for o in others {
            let sideBySide = o.minY < r.maxY && o.maxY > r.minY
            // Within `margin` sideways counts as above or below, so a block set
            // corner to corner can't be taken in either.
            let stacked = o.minX < r.maxX + margin && o.maxX > r.minX - margin
            if sideBySide && o.minX >= r.maxX {
                x1 = min(x1, whitestColumn(image, between: r.maxX, and: o.minX, rows: r) ?? r.maxX)
            }
            if sideBySide && o.maxX <= r.minX {
                x0 = max(x0, whitestColumn(image, between: o.maxX, and: r.minX, rows: r) ?? r.minX)
            }
            if stacked && o.minY >= r.maxY { y1 = min(y1, (r.maxY + o.minY) / 2) }
            if stacked && o.maxY <= r.minY { y0 = max(y0, (o.maxY + r.minY) / 2) }
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The middle of the widest run of columns with the least ink, from `a` to `b`
    /// within `rows`, at full resolution (the layout's blocks come from a small copy).
    private static func whitestColumn(_ image: CGImage, between a: CGFloat, and b: CGFloat, rows: CGRect) -> CGFloat? {
        let strip = CGRect(x: a, y: rows.minY, width: b - a, height: rows.height).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !strip.isNull, strip.width >= 1, strip.height >= 1, let crop = image.cropping(to: strip),
              let g = GrayBuffer(cgImage: crop, maxDim: max(crop.width, crop.height)) else { return nil }
        let ink = (0..<g.width).map { x in (0..<g.height).filter { g.value(x, $0) < 128 }.count }
        guard let least = ink.min() else { return nil }
        var best = (start: 0, length: 0), start = -1
        for x in 0...g.width {
            if x < g.width && ink[x] == least {
                if start < 0 { start = x }
            } else if start >= 0 {
                if x - start > best.length { best = (start, x - start) }
                start = -1
            }
        }
        return strip.minX + CGFloat(best.start) + CGFloat(best.length) / 2
    }

    private static func padded(_ image: CGImage, by margin: CGFloat) -> CGImage? {
        let m = Int(margin)
        guard let ctx = CGContext(data: nil, width: image.width + 2 * m, height: image.height + 2 * m,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(image, in: CGRect(x: m, y: m, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Minimum image height (px) before the second, half-scale pass adds lines. It
    /// recovers lines Vision drops after deskew rotation on full-size pages, but on a
    /// small block (a table/footnote column) it tends to split a wrapped term
    /// differently and the merge double-adds it. On small blocks it only corrects words.
    private static let twoPassMinHeight = 600

    /// OCR over a whole image, in two passes (full + 50% scale): the second corrects
    /// misread words and, on large images, recovers deskew-dropped lines.
    private static func recognizeWhole(_ cgImage: CGImage, languages: [String]) -> [Line]? {
        guard let pass1 = runRequest(on: preprocess(cgImage), languages: languages) else { return nil }
        // The second pass only recovers lines and words; if it fails, pass1 alone is still good.
        guard let pass2 = runRequest(on: preprocess(halfScale(cgImage)), languages: languages) else { return pass1 }
        let isWord = { spelledRight($0, languages: languages) }
        let corrected = correct(withoutGhosts(pass1, pass2, isWord: isWord), with: pass2, isWord: isWord)
        guard cgImage.height >= twoPassMinHeight else { return corrected }
        return merge(corrected, pass2)
    }

    private static let spellLock = NSLock()

    /// True unless the system spell checker flags `token` (punctuation aside).
    /// Tokens with digits, and ones in a language the checker lacks, pass.
    static func spelledRight(_ token: String, languages: [String]) -> Bool {
        let w = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        guard w.count > 1, w.rangeOfCharacter(from: .decimalDigits) == nil else { return true }
        spellLock.lock(); defer { spellLock.unlock() }
        let checker = NSSpellChecker.shared
        let available = checker.availableLanguages
        guard let wanted = languages.first?.replacingOccurrences(of: "-", with: "_"),
              let language = available.first(where: { $0 == wanted })
                ?? available.first(where: { $0 == String(wanted.prefix(2)) })
                ?? available.first(where: { $0.hasPrefix(String(wanted.prefix(2))) })
        else { return true }
        return checker.checkSpelling(of: w, startingAt: 0, language: language, wrap: false,
                                     inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// Words pass1 misread that pass2, at half size, read as real words: "carth" →
    /// "earth", "specity" → "specify", "ScriptureiLet" → "Scripture "Let". The two
    /// lines are lined up word by word; a run of words that differs is replaced only
    /// when pass1's run has a misspelling, all of pass2's are spelled right, and the
    /// letters differ by at most two, not in accents alone. Runs under three letters
    /// stay: they are mostly footnote marks and subscripts ("t₂" read "tz" or "t").
    /// Numbers must agree, and a word broken at the line's end ("elec-") stays.
    /// Each pass2 line votes only on the nearest pass1 line whose row holds it.
    static func correct(_ pass1: [Line], with pass2: [Line], isWord: (String) -> Bool) -> [Line] {
        let voter: [Int?] = pass2.map { p in
            pass1.indices.filter {
                abs(pass1[$0].box.midY - p.box.midY) < pass1[$0].box.height / 2
                    && pass1[$0].box.minX - 0.005 < p.box.midX && p.box.midX < pass1[$0].box.maxX + 0.005
            }.min { abs(pass1[$0].box.midY - p.box.midY) < abs(pass1[$1].box.midY - p.box.midY) }
        }
        func fine(_ w: String) -> Bool { w.hasSuffix("-") || isWord(w) }
        // A line's words, boxed where Vision boxed them (.null where not).
        func words(_ line: Line) -> [Word] {
            line.words.isEmpty ? line.text.split(separator: " ").map { Word(text: String($0), box: .null) } : line.words
        }
        return pass1.enumerated().map { k, line in
            let row = pass2.indices.filter { voter[$0] == k }.map { pass2[$0] }.sorted { $0.box.minX < $1.box.minX }
            guard !row.isEmpty else { return line }
            let aw = words(line), bw = row.flatMap(words)
            let a = aw.map(\.text), b = bw.map(\.text)
            guard a != b else { return line }
            var out: [Word] = []
            var i = 0, j = 0
            for (ai, bj) in commonWords(a, b) + [(a.count, b.count)] {
                let ra = Array(a[i..<ai]), rb = Array(b[j..<bj])
                if !ra.isEmpty, !rb.isEmpty, ra.count <= 3, rb.count <= 3,
                   !ra.allSatisfy(fine), rb.allSatisfy(fine),
                   letters(ra).count >= 3, folded(ra) != folded(rb), digits(ra) == digits(rb),
                   distance(letters(ra), letters(rb)) <= 2 {
                    out += bw[j..<bj]
                } else {
                    out += aw[i..<ai]
                }
                if ai < a.count { out.append(aw[ai]) }
                i = ai + 1; j = bj + 1
            }
            return Line(text: out.map(\.text).joined(separator: " "), box: line.box,
                        words: out.contains { $0.box.isNull } ? [] : out)
        }
    }

    /// Accents aside: the half-size pass loses them ("quâ" read as "qua").
    private static func folded(_ words: [String]) -> [Character] {
        letters(words.map { $0.folding(options: .diacriticInsensitive, locale: nil) })
    }

    private static func digits(_ words: [String]) -> [Character] {
        Array(words.joined().filter(\.isNumber))
    }

    private static func letters(_ words: [String]) -> [Character] {
        Array(words.joined().lowercased().filter(\.isLetter))
    }

    /// Index pairs of a longest common run of equal words.
    private static func commonWords(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var len = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                len[i][j] = a[i] == b[j] ? len[i + 1][j + 1] + 1 : max(len[i + 1][j], len[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = [], i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if len[i + 1][j] >= len[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }

    /// Edit distance: the fewest letters added, dropped or changed to turn a into b.
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for ca in a {
            var diagonal = row[0]
            row[0] += 1
            for (j, cb) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (ca == cb ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
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
        return (request.results ?? []).compactMap { o in
            let top = o.topCandidates(1).first
            return makeLine(top?.string, box: o.boundingBox) { try? top?.boundingBox(for: $0)?.boundingBox }
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
                result.lines = observations.compactMap { o in
                    let top = o.topCandidates(1).first
                    return makeLine(top?.string, box: o.boundingBox.cgRect) { top?.boundingBox(for: $0)?.boundingBox.cgRect }
                }
            }
            done.signal()
        }
        done.wait()
        return result.lines
    }

    /// The line, with each word's box when Vision gives a sane one for every
    /// word: inside the line's row, left to right, overlapping the word before
    /// by no more than a quarter of its width and ending past it.
    static func makeLine(_ text: String?, box: CGRect, wordBox: (Range<String.Index>) -> CGRect?) -> Line? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let row = box.insetBy(dx: -0.01, dy: -box.height / 2)
        var words: [Word] = []
        for w in text.split(separator: " ") {
            guard let b = wordBox(w.startIndex..<w.endIndex), b.width > 0, b.height > 0, row.contains(b),
                  b.minX >= words.last.map({ $0.box.maxX - $0.box.width / 4 }) ?? 0,
                  b.maxX > words.last?.box.maxX ?? 0 else { return Line(text: text, box: box) }
            words.append(Word(text: String(w), box: b))
        }
        return Line(text: words.map(\.text).joined(separator: " "), box: box, words: words)
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
        var given: [Int: [Line]] = [:]     // pass1 index → its pass2 lines
        var unheld: [Line] = []
        for line in pass2 {
            guard let nearest = holder(of: line, in: pass1) else {
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

    /// The pass1 line `line` is given to: the nearest whose (slightly enlarged)
    /// box holds its centre.
    private static func holder(of line: Line, in pass1: [Line]) -> Int? {
        let center = CGPoint(x: line.box.midX, y: line.box.midY)
        return pass1.indices.filter { pass1[$0].box.insetBy(dx: -0.005, dy: -0.005).contains(center) }
            .min { abs(pass1[$0].box.midY - center.y) < abs(pass1[$1].box.midY - center.y) }
    }

    /// Lines Vision made up in the first pass (Wallace 1957). Lines are taken in
    /// turn, those a second-pass line is given to first, then longer before
    /// shorter, and one goes only by comparison with lines already kept:
    ///  • a ghost: no second-pass line is given to it, and three quarters of
    ///    each of its words lies on words of kept lines that have one ("1 Du
    ///    to the", over three real lines where nothing is printed);
    ///  • a copy: it shares at least half its words, in order, with a kept
    ///    line, each shared word lying on its partner, every word lies at
    ///    least half on that line's words, and the words it doesn't share are
    ///    misspelled ("is A dav that" over the table row "is A day that occurs
    ///    is longer and warmer"). Two readings that differ in a real word both
    ///    stay: there's no telling which is right.
    /// Lines without word boxes always stay.
    static func withoutGhosts(_ pass1: [Line], _ pass2: [Line], isWord: (String) -> Bool) -> [Line] {
        let read = Set(pass2.compactMap { holder(of: $0, in: pass1) })
        let order = pass1.indices.sorted {
            (read.contains($0) ? 0 : 1, -pass1[$0].words.count, $0) < (read.contains($1) ? 0 : 1, -pass1[$1].words.count, $1)
        }
        func liesOn(_ word: Word, _ under: [Word], _ share: Double) -> Bool {
            let area = word.box.width * word.box.height
            return area > 0 && unionArea(under.map { $0.box.intersection(word.box) }) >= share * area
        }
        // Where each line's words lie: a word may reach past its line's box.
        let spans = pass1.map { $0.words.map(\.box).reduce(CGRect.null) { $0.union($1) } }
        func isCopy(_ i: Int, of j: Int) -> Bool {
            guard spans[i].intersects(spans[j]) else { return false }
            let a = pass1[i].words, b = pass1[j].words
            let pairs = commonWords(a.map(\.text), b.map(\.text))
            let shared = Set(pairs.map(\.0))
            return pairs.count * 2 >= a.count
                && pairs.allSatisfy { liesOn(a[$0.0], [b[$0.1]], 0.5) }
                && a.allSatisfy { liesOn($0, b, 0.5) }
                && a.indices.allSatisfy { shared.contains($0) || !isWord(a[$0].text) }
        }
        var kept: [Int] = []
        for i in order {
            let line = pass1[i]
            if !line.words.isEmpty {
                if kept.contains(where: { isCopy(i, of: $0) }) { continue }
                let confirmed = kept.filter { read.contains($0) }.flatMap { pass1[$0].words }
                if !read.contains(i) && line.words.allSatisfy({ liesOn($0, confirmed, 0.75) }) { continue }
            }
            kept.append(i)
        }
        return kept.sorted().map { pass1[$0] }
    }

    /// The area of the union of `rects` (null and empty ones count for nothing).
    private static func unionArea(_ rects: [CGRect]) -> Double {
        let rs = rects.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        let xs = Set(rs.flatMap { [$0.minX, $0.maxX] }).sorted()
        var area = 0.0
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            // Within this slab, the length of the union of the rects' heights.
            let spans = rs.filter { $0.minX <= x0 && $0.maxX >= x1 }.map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
            var covered = 0.0, top = -Double.infinity
            for (lo, hi) in spans where hi > top {
                covered += hi - max(lo, top)
                top = hi
            }
            area += covered * (x1 - x0)
        }
        return area
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
