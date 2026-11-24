import Foundation

/// How a single source page should be treated.
enum PageClassification: String, Codable, CaseIterable, Identifiable {
    case spread   // two book pages side by side -> split into left + right
    case single   // one book page (cover, plate, etc.) -> one output page
    case skip     // excluded from the output entirely

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spread: return "Spread"
        case .single: return "Single"
        case .skip:   return "Skip"
        }
    }

    var symbol: String {
        switch self {
        case .spread: return "book.pages"
        case .single: return "doc"
        case .skip:   return "xmark.circle"
        }
    }
}

/// A box blanked in the export, and the straightening it was drawn on. A later
/// change of skew or split moves the print; these values let the box follow it.
struct Erasure: Codable, Equatable {
    var rect: CropRect
    var splitX: Double
    var leftSkew: Double
    var rightSkew: Double
    var spread: Bool
}

/// Model for one page of the SOURCE pdf and how to carve output pages from it.
struct BookPage: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceIndex: Int            // 0-based index in the source PDF

    var classification: PageClassification

    /// Normalized x of the gutter / split line (0...1). Only meaningful for spreads.
    var splitX: Double

    /// For a spread: the crop covering the LEFT book page.
    /// For a single: this is the only crop and covers the whole book page.
    var leftCrop: CropRect

    /// For a spread: the crop covering the RIGHT book page. Unused for singles.
    var rightCrop: CropRect

    /// Deskew correction (degrees) for each book page, applied to its half of
    /// the spread independently — the two pages of one scanned spread are often
    /// tilted by different amounts. For a single page only `leftSkew` is used.
    var leftSkew: Double
    var rightSkew: Double

    /// Set once auto-analysis has run so we don't clobber manual edits.
    var analyzed: Bool

    /// A skipped page's type before it was skipped, whose crops it keeps: un-skipping
    /// to another type must re-detect them. Absent in older saves.
    var typeBeforeSkip: PageClassification?

    /// For a spread: the one side left out of the export. Nil exports both. The
    /// side keeps its crop and skew, so choosing both again brings it back as it
    /// was. A single or skipped page ignores it. Absent in older saves.
    var omittedSide: Side?

    /// The sides whose box was set off the split by hand, which the split then leaves
    /// where it is. Absent in older saves (none). (Saves from 2026-10-24 named it
    /// offSplit, marked by a rule that also caught outer-edge drags; those are dropped.)
    var handOffSplit: Set<Side>?

    /// Trim: the part of the scan the book is on. The rest is hidden, and the
    /// split, boxes and analysis stay inside it. Nil: the whole page. Absent in
    /// older saves.
    var trim: CropRect?

    /// The trim was set by hand (Trim, Remove Trim, Trim All Pages Like This), so
    /// Auto-detect keeps it, a removed one too. Absent in older saves.
    var trimByHand: Bool?

    /// Boxes blanked in the export. Each remembers the straightening it was drawn
    /// on (see `erasureRects`). Absent in older saves; a save from before that
    /// stored plain rects, which decode as boxes in this page's own frame.
    var erasures: [Erasure]? = nil

    /// The trim, or the whole page.
    var bounds: CropRect { trim ?? .full }

    enum Side: String, Codable, CaseIterable, Identifiable {
        case left, right
        var id: String { rawValue }
    }

    init(sourceIndex: Int,
         classification: PageClassification = .spread,
         splitX: Double = 0.5,
         leftCrop: CropRect = CropRect(x: 0.02, y: 0.02, width: 0.46, height: 0.96),
         rightCrop: CropRect = CropRect(x: 0.52, y: 0.02, width: 0.46, height: 0.96),
         leftSkew: Double = 0,
         rightSkew: Double = 0,
         analyzed: Bool = false) {
        self.id = UUID()
        self.sourceIndex = sourceIndex
        self.classification = classification
        self.splitX = splitX
        self.leftCrop = leftCrop
        self.rightCrop = rightCrop
        self.leftSkew = leftSkew
        self.rightSkew = rightSkew
        self.analyzed = analyzed
    }

    /// True when this page is a spread that uses two independent skew angles.
    var isSpread: Bool { classification == .spread }

    /// `rect` as a box drawn on the page as it is straightened now.
    func erasure(for rect: CropRect) -> Erasure {
        Erasure(rect: rect, splitX: splitX, leftSkew: leftSkew, rightSkew: rightSkew, spread: isSpread)
    }

    /// The boxes in the page's current straightened frame. `width` and `height`
    /// are that image in pixels: a turn about a half's centre moves a point by an
    /// amount that depends on the half's pixel shape, the same way
    /// `ImageTransform.deskewedComposite` turns it. The box keeps its size; its
    /// centre is what moves. A box drawn on the current straightening is returned
    /// unchanged.
    func erasureRects(width: Int, height: Int) -> [CropRect] {
        guard let erasures else { return [] }
        guard width > 0, height > 0 else { return erasures.map(\.rect) }
        return erasures.map { placed($0, width: width, height: height) }
    }

    /// The gutter column `deskewedComposite` cuts on.
    private static func splitPixels(_ splitX: Double, _ width: Int) -> Int {
        max(1, min(width - 1, Int(splitX * Double(width))))
    }

    /// Whether `box` was drawn on this page's current straightening, so its rect
    /// already sits on the print. A turn of 0.01° or less is no turn at all.
    private func straighteningMatches(_ box: Erasure, width: Int) -> Bool {
        if box.spread != isSpread { return false }
        let idle = abs(box.leftSkew) <= 0.01 && abs(leftSkew) <= 0.01
            && abs(box.rightSkew) <= 0.01 && abs(rightSkew) <= 0.01
        if idle { return true }
        if abs(box.leftSkew - leftSkew) > 1e-9 { return false }
        if isSpread, abs(box.rightSkew - rightSkew) > 1e-9 { return false }
        if isSpread, Self.splitPixels(box.splitX, width) != Self.splitPixels(splitX, width) { return false }
        return true
    }

    /// `box` carried from the straightening it was drawn on to the current one.
    /// Each half — or the whole page, for a single — turns about its own centre.
    /// Positive degrees are counter-clockwise, and y grows downward, which is the
    /// sense of `rotateInPlace`. Points of the box go raw, then forward again, each
    /// by the half its pixel column is in, as the renderer cuts it. The box is the
    /// upright one round them, so the whole mark stays covered, a box across the
    /// split too (Codex review, rounds 2 and 3): its edges, and the split's line
    /// through it on either side, sampled every 1/32 of the box.
    private func placed(_ box: Erasure, width: Int, height: Int) -> CropRect {
        if straighteningMatches(box, width: width) { return box.rect }
        let w = Double(width), h = Double(height), r = box.rect
        var points: [(Double, Double)] = []
        let n = 32
        for k in 0...n {
            let t = Double(k) / Double(n)
            let x = r.minX + r.width * t, y = r.minY + r.height * t
            points += [(x, r.minY), (x, r.maxY), (r.minX, y), (r.maxX, y)]
            // Where the drawn frame's split runs through the box, both sides of it.
            for split in [box.spread ? box.splitX : -1, isSpread ? splitX : -1] where split >= 0 {
                let col = Double(Self.splitPixels(split, width)) / w
                if col > r.minX, col < r.maxX { points += [(col - 0.25 / w, y), (col, y)] }
            }
        }
        let carried = points.map { p -> (Double, Double) in
            let fromLeft = onLeft(p.0, box.spread, box.splitX, width)
            let raw = spin(p.0, p.1, degrees: -(fromLeft ? box.leftSkew : box.rightSkew),
                           pivotX: halfPivot(box.spread, box.splitX, fromLeft, width), width: w, height: h)
            let toLeft = onLeft(raw.0, isSpread, splitX, width)
            return spin(raw.0, raw.1, degrees: toLeft ? leftSkew : rightSkew,
                        pivotX: halfPivot(isSpread, splitX, toLeft, width), width: w, height: h)
        }
        let x0 = carried.map(\.0).min()!, x1 = carried.map(\.0).max()!
        let y0 = carried.map(\.1).min()!, y1 = carried.map(\.1).max()!
        return CropRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Which half a point lies in: the renderer's own cut, on whole pixels.
    private func onLeft(_ nx: Double, _ spread: Bool, _ splitX: Double, _ width: Int) -> Bool {
        guard spread else { return true }
        return nx * Double(width) < Double(Self.splitPixels(splitX, width))
    }

    /// The centre of the half `left`, or of the whole page, in normalized x.
    private func halfPivot(_ spread: Bool, _ splitX: Double, _ left: Bool, _ width: Int) -> Double {
        guard spread else { return 0.5 }
        let split = Double(Self.splitPixels(splitX, width)), w = Double(width)
        return left ? (split / 2) / w : (split + (w - split) / 2) / w
    }

    /// Turn `(nx, ny)` about `(pivotX, 0.5)` by `degrees`. A turn of 0.01° or less
    /// is left as it is, matching `rotateInPlace`.
    private func spin(_ nx: Double, _ ny: Double, degrees: Double, pivotX: Double,
                      width: Double, height: Double) -> (Double, Double) {
        guard abs(degrees) > 0.01 else { return (nx, ny) }
        let t = degrees * .pi / 180, c = cos(t), s = sin(t)
        let ox = (nx - pivotX) * width, oy = (ny - 0.5) * height
        return (pivotX + (ox * c + oy * s) / width, 0.5 + (-ox * s + oy * c) / height)
    }

    /// A rect stored by an older save, which had no straightening of its own.
    private struct StoredErasure: Decodable {
        var rect: CropRect?
        var splitX: Double?
        var leftSkew: Double?
        var rightSkew: Double?
        var spread: Bool?
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?

        func erasure(splitX pageSplit: Double, leftSkew pageLeft: Double, rightSkew pageRight: Double, spread: Bool) -> Erasure? {
            if let rect {
                return Erasure(rect: rect, splitX: splitX ?? pageSplit, leftSkew: leftSkew ?? pageLeft,
                               rightSkew: rightSkew ?? pageRight, spread: self.spread ?? spread)
            }
            guard let x, let y, let width, let height else { return nil }
            return Erasure(rect: CropRect(x: x, y: y, width: width, height: height),
                           splitX: pageSplit, leftSkew: pageLeft, rightSkew: pageRight, spread: spread)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceIndex, classification, splitX, leftCrop, rightCrop
        case leftSkew, rightSkew, analyzed, typeBeforeSkip, omittedSide
        case handOffSplit, trim, trimByHand, erasures
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceIndex = try c.decode(Int.self, forKey: .sourceIndex)
        classification = try c.decode(PageClassification.self, forKey: .classification)
        splitX = try c.decode(Double.self, forKey: .splitX)
        leftCrop = try c.decode(CropRect.self, forKey: .leftCrop)
        rightCrop = try c.decode(CropRect.self, forKey: .rightCrop)
        leftSkew = try c.decode(Double.self, forKey: .leftSkew)
        rightSkew = try c.decode(Double.self, forKey: .rightSkew)
        analyzed = try c.decode(Bool.self, forKey: .analyzed)
        typeBeforeSkip = try c.decodeIfPresent(PageClassification.self, forKey: .typeBeforeSkip)
        omittedSide = try c.decodeIfPresent(Side.self, forKey: .omittedSide)
        handOffSplit = try c.decodeIfPresent(Set<Side>.self, forKey: .handOffSplit)
        trim = try c.decodeIfPresent(CropRect.self, forKey: .trim)
        trimByHand = try c.decodeIfPresent(Bool.self, forKey: .trimByHand)
        // A plain rect is a box drawn in this page's own frame.
        if let raw = try c.decodeIfPresent([StoredErasure].self, forKey: .erasures) {
            erasures = raw.compactMap {
                $0.erasure(splitX: splitX, leftSkew: leftSkew, rightSkew: rightSkew, spread: classification == .spread)
            }
        } else {
            erasures = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceIndex, forKey: .sourceIndex)
        try c.encode(classification, forKey: .classification)
        try c.encode(splitX, forKey: .splitX)
        try c.encode(leftCrop, forKey: .leftCrop)
        try c.encode(rightCrop, forKey: .rightCrop)
        try c.encode(leftSkew, forKey: .leftSkew)
        try c.encode(rightSkew, forKey: .rightSkew)
        try c.encode(analyzed, forKey: .analyzed)
        try c.encodeIfPresent(typeBeforeSkip, forKey: .typeBeforeSkip)
        try c.encodeIfPresent(omittedSide, forKey: .omittedSide)
        try c.encodeIfPresent(handOffSplit, forKey: .handOffSplit)
        try c.encodeIfPresent(trim, forKey: .trim)
        try c.encodeIfPresent(trimByHand, forKey: .trimByHand)
        try c.encodeIfPresent(erasures, forKey: .erasures)
    }

    /// The crops that will actually be emitted, in reading order, given a direction.
    func outputCrops(direction: ReadingDirection) -> [CropRect] {
        switch classification {
        case .skip:
            return []
        case .single:
            return [leftCrop.normalized().kept(in: bounds)]
        case .spread:
            // Inside the trim even where normalizing grew a tiny box past it.
            let l = leftCrop.normalized().kept(in: bounds)
            let r = rightCrop.normalized().kept(in: bounds)
            switch omittedSide {
            case .left:  return [r]
            case .right: return [l]
            case nil:    return direction == .leftToRight ? [l, r] : [r, l]
            }
        }
    }
}

enum ReadingDirection: String, Codable, CaseIterable, Identifiable {
    case leftToRight
    case rightToLeft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .leftToRight: return "Left-to-right"
        case .rightToLeft: return "Right-to-left"
        }
    }
}

/// What auto-detection crops each book page to.
enum CropTarget: String, Codable, CaseIterable, Identifiable {
    case text       // the printed text block, with a little room
    case page       // the whole sheet of paper, margins included
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: return "Text block"
        case .page: return "Whole page"
        }
    }
}

/// A book page's physical size, in inches.
struct PageSize: Codable, Equatable {
    var width: Double
    var height: Double
}

extension PageSize {
    /// The sizes a book page can sensibly have, in inches.
    static let sensible: ClosedRange<Double> = 1...30

    var isSensible: Bool { Self.sensible.contains(width) && Self.sensible.contains(height) }

    /// Inches rounded down to the hundredth, so the size fits as typed; one that is
    /// a hundredth already but for floating-point error stays put.
    static func roundedDown(_ v: Double) -> Double { (v * 100 + 1e-6).rounded(.down) / 100 }

    /// A size as typed: two numbers in inches, such as "6 × 9", "6 x 9 in",
    /// "5.5 by 8.5", "6,5 × 9,25" or 6" × 9". A comma is a decimal point.
    /// Nil for anything else, or a size outside `sensible`.
    /// One length as typed in a Width or Height field: inches, as "6", "5.45 in", "6,5" or 6".
    static func inches(_ text: String) -> Double? {
        let pattern = #"^\s*(\d+(?:[.,]\d+)?|[.,]\d+)\s*(?:in|"|″)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[r].replacingOccurrences(of: ",", with: "."))
    }

    init?(parsing text: String) {
        let number = #"(\d+(?:[.,]\d+)?|[.,]\d+)"#, unit = #"\s*(?:in|"|″)?\s*"#
        let pattern = "^\\s*" + number + unit + "(?:×|x|by)" + "\\s*" + number + unit + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
              let width = Double(text[a].replacingOccurrences(of: ",", with: ".")),
              let height = Double(text[b].replacingOccurrences(of: ",", with: ".")) else { return nil }
        self.init(width: width, height: height)
        guard isSensible else { return nil }
    }
}
