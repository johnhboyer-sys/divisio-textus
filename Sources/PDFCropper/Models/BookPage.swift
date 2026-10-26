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

    /// The crops that will actually be emitted, in reading order, given a direction.
    func outputCrops(direction: ReadingDirection) -> [CropRect] {
        switch classification {
        case .skip:
            return []
        case .single:
            return [leftCrop.normalized()]
        case .spread:
            let l = leftCrop.normalized()
            let r = rightCrop.normalized()
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
    /// "5.5 by 8.5" or 6" × 9". Nil for anything else, or a size outside `sensible`.
    init?(parsing text: String) {
        let number = #"(\d+(?:\.\d+)?|\.\d+)"#, unit = #"\s*(?:in|"|″)?\s*"#
        let pattern = "^\\s*" + number + unit + "(?:×|x|by)" + "\\s*" + number + unit + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
              let width = Double(text[a]), let height = Double(text[b]) else { return nil }
        self.init(width: width, height: height)
        guard isSensible else { return nil }
    }
}
