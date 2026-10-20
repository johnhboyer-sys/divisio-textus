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
            return direction == .leftToRight ? [l, r] : [r, l]
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
