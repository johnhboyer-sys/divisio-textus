import Foundation

/// A group of book-page sides, measured relative to each side's own width.
struct PageStack: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case left, right, singleA, singleB, spreads
        var id: Self { self }
        var label: String {
            switch self {
            case .left: return "Left pages"
            case .right: return "Right pages"
            case .singleA: return "Odd single pages"
            case .singleB: return "Even single pages"
            case .spreads: return "Whole spreads"
            }
        }
    }

    struct Member: Identifiable, Equatable {
        let page: BookPage
        let side: Side
        enum Side: String { case left, right, single, whole }
        var id: BookPage.ID { page.id }
        var regionMinX: Double { side == .right ? page.splitX : 0 }
        var regionWidth: Double {
            switch side {
            case .left: return page.splitX
            case .right: return 1 - page.splitX
            case .single, .whole: return 1
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

        /// The box placed on this page at the stack's usual size and measured from the
        /// gutter: a text block is one size on every page and sits a set distance from
        /// the fold, while a half's width moves with the gutter. Kept inside its side
        /// at a size export leaves alone (export normalizes on the page, whose smallest
        /// crop can be wider than a small box on a side). A box edge on the stack's
        /// outer edge means this page's outer edge, however wide its half.
        func clampedCrop(_ crop: CropRect, usualWidth: Double) -> CropRect {
            let local = crop.normalized(), width = local.width * usualWidth
            var x = side == .left
                ? regionMinX + regionWidth - (1 - local.maxX) * usualWidth - width
                : regionMinX + local.x * usualWidth
            var right = x + width
            if side == .left, local.minX <= 0.001 { x = regionMinX }
            if side == .right, local.maxX >= 0.999 { right = regionMinX + regionWidth }
            var c = CropRect(x: x, y: local.y, width: right - x, height: local.height).normalized()
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

    /// Every spread whole, to set the split and both crops on one blend, as Briss
    /// does. Kept out of `groups`, which measures the page size and marks the rail.
    static func wholeSpreads(pages: [BookPage]) -> PageStack? {
        let members = pages.filter { $0.classification == .spread }.map { Member(page: $0, side: .whole) }
        return members.isEmpty ? nil : PageStack(id: .spreads, members: members)
    }

    /// The stacks the Stack view offers: the sides, then the whole spreads.
    static func all(pages: [BookPage]) -> [PageStack] {
        groups(pages: pages) + [wholeSpreads(pages: pages)].compactMap { $0 }
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
    /// Width is measured on the page, not the side: the gutter moves from spread to
    /// spread, so the same text block is a larger share of a narrower half.
    var outliers: [Member] {
        if id == .spreads { return splitOutliers }
        let widths = members.map { pageWidth($0) }, heights = members.map(\.crop.height)
        let width = Self.median(widths), height = Self.median(heights)
        let tolerance = 0.04 * usualRegionWidth
        return zip(members, zip(widths, heights)).filter { _, size in
            abs(size.0 - width) > tolerance || abs(size.1 - height) > 0.04
        }.map(\.0).sorted { $0.page.sourceIndex < $1.page.sourceIndex }
    }

    /// How far, as a share of the scan's width, a spread's split may sit from the
    /// median before it is flagged. A book page's gutter margin is often under a
    /// tenth of the scan; a split a third of that off is cutting into it or leaving
    /// the facing page's edge.
    static let splitTolerance = 0.03

    /// In the whole-spread stack: spreads whose split is far from the rest. A book
    /// that shifted on the scanner moves its fold too, so a flag asks for a look
    /// rather than saying the split is wrong.
    private var splitOutliers: [Member] {
        let split = Self.median(members.map(\.page.splitX))
        return members.filter { abs($0.page.splitX - split) > Self.splitTolerance }
    }

    /// In the whole-spread stack: the usual split and crops, on the page.
    var medianLayout: SpreadLayout {
        func median(_ crops: [CropRect]) -> CropRect {
            let x = Self.median(crops.map(\.minX)), y = Self.median(crops.map(\.minY))
            return CropRect(x: x, y: y, width: Self.median(crops.map(\.maxX)) - x,
                            height: Self.median(crops.map(\.maxY)) - y)
        }
        let pages = members.map(\.page)
        return SpreadLayout(splitX: Self.median(pages.map(\.splitX)),
                            leftCrop: median(pages.map(\.leftCrop)), rightCrop: median(pages.map(\.rightCrop)))
    }

    /// The width of a usual half in this stack, on the page.
    var usualRegionWidth: Double { Self.median(members.map(\.regionWidth)) }

    private func pageWidth(_ member: Member) -> Double {
        (member.side == .right ? member.page.rightCrop : member.page.leftCrop).width
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

/// A spread's split and its two crops, in page coordinates: the whole-spread
/// stack's draft.
struct SpreadLayout: Equatable {
    var splitX: Double
    var leftCrop: CropRect
    var rightCrop: CropRect

    /// Moves the split and the crops' inner edges with it, as Page view does.
    mutating func moveSplit(to x: Double) {
        splitX = max(0.05, min(x, 0.95))
        if splitX > leftCrop.minX + 0.02 { leftCrop.width = splitX - leftCrop.minX }
        leftCrop.normalize()
        if splitX < rightCrop.maxX - 0.02 {
            let right = rightCrop.maxX
            rightCrop.x = splitX; rightCrop.width = right - splitX
        }
        rightCrop.normalize()
    }

    /// The crops cut back to their own side of the split.
    var clamped: SpreadLayout {
        func clamp(_ crop: CropRect, _ lo: Double, _ hi: Double) -> CropRect {
            var c = crop.normalized()
            if c.minX < lo { c.width -= lo - c.minX; c.x = lo }
            if c.maxX > hi { c.width = hi - c.x }
            let least = min(0.02, hi - lo)
            if c.width < least { c.width = least; c.x = min(c.x, hi - least) }
            return c
        }
        return SpreadLayout(splitX: splitX, leftCrop: clamp(leftCrop, 0, splitX),
                            rightCrop: clamp(rightCrop, splitX, 1))
    }
}
