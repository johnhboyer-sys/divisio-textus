import Foundation

/// A group of book-page sides, measured relative to each side's own width.
struct PageStack: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case left, right, singleA, singleB
        var id: Self { self }
        var label: String {
            switch self {
            case .left: return "Left pages"
            case .right: return "Right pages"
            case .singleA: return "Odd single pages"
            case .singleB: return "Even single pages"
            }
        }
    }

    struct Member: Identifiable, Equatable {
        let page: BookPage
        let side: Side
        enum Side: String { case left, right, single }
        var id: BookPage.ID { page.id }
        var regionMinX: Double { side == .right ? page.splitX : 0 }
        var regionWidth: Double {
            switch side {
            case .left: return page.splitX
            case .right: return 1 - page.splitX
            case .single: return 1
            }
        }
        var crop: CropRect { localCrop(side == .right ? page.rightCrop : page.leftCrop) }

        func localCrop(_ crop: CropRect) -> CropRect {
            CropRect(x: (crop.x - regionMinX) / max(regionWidth, 0.000001), y: crop.y,
                     width: crop.width / max(regionWidth, 0.000001), height: crop.height)
        }

        func pageCrop(_ crop: CropRect) -> CropRect {
            CropRect(x: regionMinX + crop.x * regionWidth, y: crop.y,
                     width: crop.width * regionWidth, height: crop.height)
        }

        /// Kept inside its side at a size export leaves alone: export normalizes on
        /// the page, whose smallest crop can be wider than a small box on a side.
        func clampedCrop(_ crop: CropRect) -> CropRect {
            var c = pageCrop(crop.normalized()).normalized()
            let end = regionMinX + regionWidth
            c.width = min(c.width, regionWidth)
            c.x = max(regionMinX, min(c.x, end - c.width))
            return c
        }
    }

    let id: Kind
    let members: [Member]

    static func groups(pages: [BookPage]) -> [PageStack] {
        var groups: [Kind: [Member]] = [:]
        var singlePosition = 0
        for page in pages {
            switch page.classification {
            case .spread:
                groups[.left, default: []].append(Member(page: page, side: .left))
                groups[.right, default: []].append(Member(page: page, side: .right))
            case .single:
                let kind: Kind = singlePosition % 2 == 0 ? .singleA : .singleB
                groups[kind, default: []].append(Member(page: page, side: .single))
                singlePosition += 1
            case .skip: break
            }
        }
        return Kind.allCases.compactMap { kind in
            guard let members = groups[kind], !members.isEmpty else { return nil }
            return PageStack(id: kind, members: members)
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    var medianCrop: CropRect {
        let crops = members.map(\.crop)
        let x = Self.median(crops.map(\.minX)), y = Self.median(crops.map(\.minY))
        return CropRect(x: x, y: y, width: Self.median(crops.map(\.maxX)) - x,
                        height: Self.median(crops.map(\.maxY)) - y)
    }

    /// Pages whose crop is a different size from the rest. Position isn't judged:
    /// the book shifts on the scanner, so a good crop moves with its text block.
    var outliers: [Member] {
        let crops = members.map(\.crop)
        let width = Self.median(crops.map(\.width)), height = Self.median(crops.map(\.height))
        return members.filter {
            abs($0.crop.width - width) > 0.04 || abs($0.crop.height - height) > 0.04
        }.sorted { $0.page.sourceIndex < $1.page.sourceIndex }
    }

    /// Crops don't affect the blend; only page membership and geometry do.
    struct Geometry: Equatable {
        let id: BookPage.ID
        let index: Int
        let classification: PageClassification
        let split, leftSkew, rightSkew: Double
    }
    var geometry: [Geometry] {
        members.map { Geometry(id: $0.id, index: $0.page.sourceIndex, classification: $0.page.classification,
                               split: $0.page.splitX, leftSkew: $0.page.leftSkew, rightSkew: $0.page.rightSkew) }
    }
}
