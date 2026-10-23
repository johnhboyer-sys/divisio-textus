import SwiftUI

/// View ▸ Show Rulers / Hide Rulers.
struct RulerMenuButton: View {
    @AppStorage(Rulers.storageKey) private var shows = Rulers.shownByDefault

    var body: some View {
        Button(shows ? "Hide Rulers" : "Show Rulers") { shows.toggle() }
            .keyboardShortcut("r", modifiers: [.command, .option])
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

            // Each crop: a line at its start and end, a thin strip between.
            for mark in page.marks {
                let start = origin + (horizontal ? mark.crop.minX : mark.crop.minY) * drawn
                let end = origin + (horizontal ? mark.crop.maxX : mark.crop.maxY) * drawn
                context.fill(Path(rect(start, end, depth: 3)), with: .color(mark.color.opacity(0.45)))
                context.fill(Path(rect(start - 0.75, start + 0.75, depth: across)), with: .color(mark.color))
                context.fill(Path(rect(end - 0.75, end + 0.75, depth: across)), with: .color(mark.color))
            }

            var ticks = Path()
            for tick in RulerScale(unit: unit, screenPerPoint: drawn / length).ticks(length: length, origin: origin)
            where tick.position >= -20 && tick.position <= along + 1 {
                let depth = tick.size == .long ? across * 0.75 : tick.size == .medium ? across * 0.45 : across * 0.25
                ticks.addRect(rect(tick.position - 0.5, tick.position + 0.5, depth: depth))
                if let label = tick.label {
                    let text = Text(label).font(.system(size: 9).monospacedDigit())
                    if horizontal {
                        context.draw(text, at: CGPoint(x: tick.position + 2, y: 1), anchor: .topLeading)
                    } else {
                        context.draw(text, at: CGPoint(x: 2, y: tick.position + 1), anchor: .topLeading)
                    }
                }
            }
            context.fill(ticks, with: .style(.secondary))
        }
        .foregroundStyle(.secondary)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: horizontal ? .bottom : .trailing) { Divider() }
        .clipped()
    }
}
