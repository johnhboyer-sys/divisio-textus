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
        /// The stack's width as a share of a scan: its widest half. Every side is
        /// drawn at true size against it, lined up at the fold (see PageStack.init).
        var span: Double = 1
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

        /// Stack x (0…1 across the stack) for a page x, and back. A left half ends
        /// at the stack's right edge and a right half starts at its left edge, so
        /// the fold lines up and a distance from it is the same on every page.
        private func stackX(_ x: Double) -> Double {
            switch side {
            case .left: return 1 - (page.splitX - x) / max(span, 0.000001)
            case .right: return (x - page.splitX) / max(span, 0.000001)
            case .single, .whole: return x
            }
        }
        private func pageX(_ u: Double) -> Double {
            switch side {
            case .left: return page.splitX - (1 - u) * span
            case .right: return page.splitX + u * span
            case .single, .whole: return u
            }
        }

        func localCrop(_ crop: CropRect) -> CropRect {
            let x0 = stackX(crop.x), x1 = stackX(crop.x + crop.width)
            return CropRect(x: x0, y: crop.y, width: x1 - x0, height: crop.height)
        }

        func pageCrop(_ crop: CropRect) -> CropRect {
            let x0 = pageX(crop.x), x1 = pageX(crop.x + crop.width)
            return CropRect(x: x0, y: crop.y, width: x1 - x0, height: crop.height)
        }

        /// The box placed on this page where the stack shows it: the same size on
        /// every page and the same distance from the fold. Where it reaches past a
        /// narrower half's outer edge, it stops at that edge. Kept inside its side
        /// at a size export leaves alone.
        func clampedCrop(_ crop: CropRect) -> CropRect {
            // Cut, not shifted, to the stack: a box that reaches past the stack's edge
            // (as a draft does once a wider half is left out) is shown cut there.
            let x0 = max(0, crop.minX), x1 = min(1, crop.maxX), y0 = max(0, crop.minY), y1 = min(1, crop.maxY)
            let shown = pageCrop(CropRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0)).normalized())
            let end = regionMinX + regionWidth
            let lo = max(regionMinX, shown.minX), hi = min(end, shown.maxX)
            var c = CropRect(x: lo, y: shown.y, width: max(0, hi - lo), height: shown.height).normalized()
            c.width = min(c.width, regionWidth)
            c.x = max(regionMinX, min(c.x, end - c.width))
            return c
        }
    }

    let id: Kind
    /// The pages in the stack: all of its pages but those left out (see `excludedMembers`).
    let members: [Member]
    /// Pages the user left out of this stack. Only this stack: they are not drawn
    /// in its blend, counted in its medians or flags, or changed by its Apply.
    let excludedMembers: [Member]

    init(id: Kind, members: [Member], excludedMembers: [Member] = []) {
        self.id = id
        let span = members.map(\.regionWidth).max() ?? 1
        self.members = members.map { var m = $0; m.span = span; return m }
        self.excludedMembers = excludedMembers
    }

    /// Every page that belongs to the stack, in or out, in book order.
    var allMembers: [Member] { (members + excludedMembers).sorted { $0.page.sourceIndex < $1.page.sourceIndex } }

    /// The stack of `members` with the ones whose page is in `excluded` set aside.
    private init(id: Kind, members: [Member], excluding excluded: Set<BookPage.ID>) {
        self.init(id: id, members: members.filter { !excluded.contains($0.id) },
                  excludedMembers: members.filter { excluded.contains($0.id) })
    }

    /// The stack's width as a share of a scan (see Member.span).
    var span: Double { members.first?.span ?? 1 }

    /// A box drawn when the stack was `oldSpan` wide, moved to this stack's width so
    /// it covers the same place on the page: the same size and distance from the fold.
    func rescaled(_ crop: CropRect, from oldSpan: Double) -> CropRect {
        guard oldSpan != span, span > 0 else { return crop }
        let k = oldSpan / span
        switch id {
        case .left: return CropRect(x: 1 - (1 - crop.x) * k, y: crop.y, width: crop.width * k, height: crop.height)
        case .right: return CropRect(x: crop.x * k, y: crop.y, width: crop.width * k, height: crop.height)
        default: return crop
        }
    }

    /// `excluded`: the pages left out of each stack (see AppModel.stackExclusions).
    static func groups(pages: [BookPage], excluded: [Kind: Set<BookPage.ID>] = [:]) -> [PageStack] {
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
            return PageStack(id: kind, members: members, excluding: excluded[kind] ?? [])
        }
    }

    /// Every spread whole, to set the split and both crops on one blend, as Briss
    /// does. Kept out of `groups`, which measures the page size and marks the rail.
    static func wholeSpreads(pages: [BookPage], excluded: [Kind: Set<BookPage.ID>] = [:]) -> PageStack? {
        let members = pages.filter { $0.classification == .spread }.map { Member(page: $0, side: .whole) }
        return members.isEmpty ? nil : PageStack(id: .spreads, members: members, excluding: excluded[.spreads] ?? [])
    }

    /// The stacks the Stack view offers: the sides, then the whole spreads.
    static func all(pages: [BookPage], excluded: [Kind: Set<BookPage.ID>] = [:]) -> [PageStack] {
        groups(pages: pages, excluded: excluded) + [wholeSpreads(pages: pages, excluded: excluded)].compactMap { $0 }
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

    /// Moves the split and the crops' inner edges with it, as Page view does. A
    /// box whose outer edge the split passes shrinks on its own side of the line.
    mutating func moveSplit(to x: Double) {
        splitX = max(0.05, min(x, 0.95))
        let left = min(leftCrop.minX, splitX - 0.02)
        leftCrop.x = left; leftCrop.width = splitX - left
        let right = max(rightCrop.maxX, splitX + 0.02)
        rightCrop.x = splitX; rightCrop.width = right - splitX
    }

    /// Lock sizes: moves the split with both crops on it, their widths kept (as
    /// without the lock the inner edges follow the split, but the widths change). A
    /// crop set off the split by hand (`keep…Gap`) keeps its gap instead. The split
    /// stops where a crop would leave the scan, so dragging back loses nothing.
    mutating func slideSplit(to x: Double, keepLeftGap: Bool = false, keepRightGap: Bool = false) {
        let s = splitX, lw = leftCrop.width, rw = rightCrop.width
        let lo = max(0.05, keepLeftGap ? s - leftCrop.minX : lw)
        let hi = min(0.95, keepRightGap ? s + 1 - rightCrop.maxX : 1 - rw)
        guard lo <= hi else { return }                  // two crops wider than the scan
        let t = max(lo, min(x, hi)), d = t - s
        leftCrop.x = keepLeftGap ? leftCrop.x + d : t - lw
        rightCrop.x = keepRightGap ? rightCrop.x + d : t
        splitX = t
    }

    /// The Match Sizes buttons: one crop takes the other's size, its edge at the fold
    /// kept. Where it would pass the scan's edge, the split moves (the other crop with
    /// it) by the shortfall, as far as the other crop has room on its outer side.
    mutating func matchSizesMovingSplit(rightMatchesLeft: Bool) {
        if rightMatchesLeft {
            let w = leftCrop.width, r0 = rightCrop.minX
            let d = min(max(0, r0 + w - 1), max(0, leftCrop.minX), max(0, splitX - 0.05))
            splitX -= d; leftCrop.x -= d
            let x = r0 - d
            rightCrop = CropRect(x: x, y: leftCrop.y, width: min(w, 1 - x), height: leftCrop.height)
        } else {
            let w = rightCrop.width, l1 = leftCrop.maxX
            let d = min(max(0, w - l1), max(0, 1 - rightCrop.maxX), max(0, 0.95 - splitX))
            splitX += d; rightCrop.x += d
            let end = l1 + d, x = max(0, end - w)
            leftCrop = CropRect(x: x, y: rightCrop.y, width: end - x, height: rightCrop.height)
        }
    }

    /// Sets one crop; with `locked`, the other becomes the same size (CropRect.matched).
    /// Locked, both are cut back to their own side first, as Apply cuts them, so the
    /// sizes the draft shows are the sizes Apply gives.
    mutating func setCrop(_ crop: CropRect, on side: BookPage.Side, locked: Bool) {
        if side == .left { leftCrop = crop } else { rightCrop = crop }
        guard locked else { return }
        self = clamped
        matchSizes(rightMatchesLeft: side == .left)
        self = clamped
    }

    /// Match Sizes: the right crop takes the left's size, or the left takes the right's.
    mutating func matchSizes(rightMatchesLeft: Bool) {
        if rightMatchesLeft {
            rightCrop = rightCrop.matched(to: leftCrop, foldOnRight: false)
        } else {
            leftCrop = leftCrop.matched(to: rightCrop, foldOnRight: true)
        }
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
