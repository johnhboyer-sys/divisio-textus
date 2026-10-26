import SwiftUI

/// View ▸ Show Rulers / Hide Rulers.
struct RulerMenuButton: View {
    @AppStorage(Rulers.storageKey) private var shows = Rulers.shownByDefault

    var body: some View {
        Button(shows ? "Hide Rulers" : "Show Rulers") { shows.toggle() }
            .keyboardShortcut("r", modifiers: [.command, .option])
    }
}

/// The crop boxes' sizes, in the gap under the page; with two boxes, whether
/// they are the same size. Shown with or without the rulers. Matching the two
/// boxes is done in the inspector (SpreadSizeControls).
struct CropSizeLabel: View {
    let readout: CropSizeReadout

    var body: some View {
        // One line where it fits; in a narrow window the verdict goes on a second.
        ViewThatFits(in: .horizontal) {
            framed(HStack(spacing: 10) { sizes; SizeVerdict(readout: readout) })
            framed(VStack(spacing: 1) {
                HStack(spacing: 10) { sizes }
                SizeVerdict(readout: readout)
            })
        }
        .padding(.bottom, 2)
    }

    // The label takes no clicks: drags reach the handles under it.
    private var sizes: some View {
        ForEach(readout.sizes, id: \.self) { Text($0) }.allowsHitTesting(false)
    }

    private func framed(_ content: some View) -> some View {
        content
            // Small enough to sit under the page's bottom handles, not on them.
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background { RoundedRectangle(cornerRadius: 8).fill(.regularMaterial).allowsHitTesting(false) }
            .fixedSize()
    }
}

/// "Same size" or how the right box differs, with a tick or a warning.
private struct SizeVerdict: View {
    let readout: CropSizeReadout

    var body: some View {
        if let verdict = readout.verdict, let same = readout.same {
            Label {
                Text(verdict)
            } icon: {
                Image(systemName: same ? "checkmark.circle.fill" : "notequal.circle.fill")
                    .foregroundStyle(same ? .green : .orange)
            }
            .allowsHitTesting(false)
        }
    }
}

/// A spread's two crop sizes, the buttons that make one match the other, and the
/// Lock sizes switch: rows for the inspector's Crops section (Page view) and for
/// the whole-spread stack.
struct SpreadSizeControls: View {
    let readout: CropSizeReadout
    /// true makes the right box match the left; false, the left match the right.
    let match: (Bool) -> Void
    @AppStorage(CropLock.storageKey) private var locks = CropLock.onByDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(readout.sizes, id: \.self) { Text($0).monospacedDigit() }
            SizeVerdict(readout: readout)
        }
        Button("Make Right Match Left") { match(true) }
            .disabled(readout.same != false)
            .help("Give the right box the left's size: the edge at the fold stays, the outer edge moves, and the top and bottom line up. If the box would pass the scan's edge, the split moves to make room.")
        Button("Make Left Match Right") { match(false) }
            .disabled(readout.same != false)
            .help("Give the left box the right's size: the edge at the fold stays, the outer edge moves, and the top and bottom line up. If the box would pass the scan's edge, the split moves to make room.")
        Toggle("Lock sizes", isOn: $locks)
            .help("While on, dragging one box of a spread gives the other box its size, and moving the split moves both boxes with it, widths kept. Turning it on changes nothing until you drag.")
    }
}

/// A crop's extent along each ruler, as fractions of the page.
struct RulerMark: Equatable {
    var crop: CropRect
    var color: Color
}

/// The page a canvas draws: where on screen (in the canvas's own coordinates),
/// its real size in PDF points, and the crops to mark.
struct RulerPage: Equatable {
    var frame: CGRect
    var size: CGSize
    var marks: [RulerMark]
}

private struct RulerPageKey: PreferenceKey {
    static var defaultValue: RulerPage? { nil }
    static func reduce(value: inout RulerPage?, nextValue: () -> RulerPage?) {
        value = nextValue() ?? value
    }
}

private let rulerSpace = "rulers"

extension View {
    /// Marks this view as the page the rulers measure: `size` is its real size in
    /// PDF points. Reports the view's frame as it scrolls and zooms.
    func rulerPage(size: CGSize, marks: [RulerMark] = []) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: RulerPageKey.self,
                                   value: RulerPage(frame: geo.frame(in: .named(rulerSpace)), size: size, marks: marks))
        })
    }
}

/// A canvas with rulers along its top and left edges when View ▸ Show Rulers is on.
struct RulerFrame<Content: View>: View {
    @AppStorage(Rulers.storageKey) private var shows = Rulers.shownByDefault
    // @State's macro isn't available without Xcode (see StackView).
    private let pageState = State<RulerPage?>(initialValue: nil)
    private var page: RulerPage? { pageState.wrappedValue }
    @ViewBuilder var content: Content

    private let unit = RulerUnit()
    private let thickness: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            if shows {
                HStack(spacing: 0) {
                    Text(unit.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: thickness, height: thickness)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .overlay(alignment: .trailing) { Divider() }
                        .overlay(alignment: .bottom) { Divider() }
                    RulerBar(horizontal: true, unit: unit, page: page)
                        .frame(height: thickness)
                }
            }
            HStack(spacing: 0) {
                if shows {
                    RulerBar(horizontal: false, unit: unit, page: page)
                        .frame(width: thickness)
                }
                content
                    .coordinateSpace(name: rulerSpace)
                    .overlay {
                        if shows, let page { CropSizes(page: page, unit: unit) }
                    }
            }
        }
        .onPreferenceChange(RulerPageKey.self) { pageState.wrappedValue = $0 }
    }
}

/// One ruler: ticks from the page's top (or left) edge to its bottom (or right),
/// and a band for each crop's extent.
private struct RulerBar: View {
    let horizontal: Bool
    let unit: RulerUnit
    let page: RulerPage?

    var body: some View {
        Canvas { context, size in
            guard let page, page.size.width > 0, page.size.height > 0 else { return }
            let along = horizontal ? size.width : size.height
            let across = horizontal ? size.height : size.width
            let origin = horizontal ? page.frame.minX : page.frame.minY
            let drawn = horizontal ? page.frame.width : page.frame.height
            let length = horizontal ? page.size.width : page.size.height

            // A rect spanning `from...to` along the ruler and `depth` in from the page side.
            func rect(_ from: Double, _ to: Double, depth: Double) -> CGRect {
                horizontal ? CGRect(x: from, y: across - depth, width: to - from, height: depth)
                    : CGRect(x: across - depth, y: from, width: depth, height: to - from)
            }

            // Each crop: a faint band, and a line where it starts and one where it ends.
            for mark in page.marks {
                let start = origin + (horizontal ? mark.crop.minX : mark.crop.minY) * drawn
                let end = origin + (horizontal ? mark.crop.maxX : mark.crop.maxY) * drawn
                context.fill(Path(rect(start, end, depth: across)), with: .color(mark.color.opacity(0.15)))
                context.fill(Path(rect(start - 0.75, start + 0.75, depth: across)), with: .color(mark.color))
                context.fill(Path(rect(end - 0.75, end + 0.75, depth: across)), with: .color(mark.color))
            }

            var ticks = Path()
            for tick in RulerScale(unit: unit, screenPerPoint: drawn / length).ticks(length: length, origin: origin)
            where tick.position >= -20 && tick.position <= along + 1 {
                let depth = tick.size == .long ? across * 0.75 : tick.size == .medium ? across * 0.45 : across * 0.25
                ticks.addRect(rect(tick.position - 0.5, tick.position + 0.5, depth: depth))
                if let label = tick.label {
                    let text = Text(label).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary)
                    if horizontal {
                        context.draw(text, at: CGPoint(x: tick.position + 2, y: 1), anchor: .topLeading)
                    } else {
                        context.draw(text, at: CGPoint(x: 2, y: tick.position + 1), anchor: .topLeading)
                    }
                }
            }
            context.fill(ticks, with: .color(.primary.opacity(0.6)))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: horizontal ? .bottom : .trailing) { Divider() }
        .clipped()
    }
}

/// Each crop's width under the top ruler and height beside the left one, in the
/// rulers' unit, centred on the part of the crop in view.
private struct CropSizes: View {
    let page: RulerPage
    let unit: RulerUnit

    var body: some View {
        GeometryReader { geo in
            // Only crops with some part in view.
            let shown = page.marks.indices.compactMap { i -> (Int, Double, Double)? in
                guard let x = span(i, horizontal: true, in: geo.size),
                      let y = span(i, horizontal: false, in: geo.size) else { return nil }
                return (i, x, y)
            }
            ForEach(shown, id: \.0) { i, x, _ in
                pill(page.marks[i], length: page.marks[i].crop.width * page.size.width)
                    .position(x: min(max(x, 32), geo.size.width - 32), y: 10)
            }
            let heights = shown.map { ($0.0, $0.2) }
            let ys = spaced(heights.map(\.1))
            ForEach(heights.indices, id: \.self) { n in
                let i = heights[n].0
                pill(page.marks[i], length: page.marks[i].crop.height * page.size.height)
                    .position(x: 30, y: ys[n])
            }
        }
        .allowsHitTesting(false)
    }

    /// A spread's two crops share most of their height: two pills that would touch
    /// sit one above the other, either side of their midpoint. All stay below the row
    /// of width pills.
    private func spaced(_ ys: [Double]) -> [Double] {
        var ys = ys
        if ys.count == 2, abs(ys[0] - ys[1]) < 20 {
            let mid = (ys[0] + ys[1]) / 2
            ys = ys[0] <= ys[1] ? [mid - 10, mid + 10] : [mid + 10, mid - 10]
        }
        let down = max(0, 30 - (ys.min() ?? 30))
        return ys.map { $0 + down }
    }

    /// The middle of the crop's visible part along one axis, or nil when it's out of view.
    private func span(_ i: Int, horizontal: Bool, in size: CGSize) -> Double? {
        let crop = page.marks[i].crop
        let origin = horizontal ? page.frame.minX : page.frame.minY
        let drawn = horizontal ? page.frame.width : page.frame.height
        let start = origin + (horizontal ? crop.minX : crop.minY) * drawn
        let end = origin + (horizontal ? crop.maxX : crop.maxY) * drawn
        let lo = max(start, 0), hi = min(end, horizontal ? size.width : size.height)
        return hi > lo ? (lo + hi) / 2 : nil
    }

    private func pill(_ mark: RulerMark, length: Double) -> some View {
        Text(unit.label(points: length))
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(mark.color, in: Capsule())
            .foregroundStyle(.white)
            .fixedSize()
    }
}
