import SwiftUI

/// The central canvas: shows the selected source page with editable crop boxes
/// and (for spreads) a draggable gutter / split line.
struct PageEditorView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(CropLock.storageKey) private var locksSizes = CropLock.onByDefault

    var body: some View {
        if let idx = model.selectedIndex {
            editor(for: idx)
        } else {
            ContentUnavailablePlaceholder()
        }
    }

    /// Live pinch amount, applied on top of model.zoom until the gesture ends.
    @GestureState private var pinch: CGFloat = 1

    /// The erase box being drawn, in the straightened page's frame. State rather
    /// than @State: Command Line Tools can't compile the @State macro (see CropBoxView).
    private let eraseDraftState = State<CropRect?>(initialValue: nil)
    private var eraseDraft: CropRect? {
        get { eraseDraftState.wrappedValue }
        nonmutating set { eraseDraftState.wrappedValue = newValue }
    }

    @ViewBuilder
    private func editor(for idx: Int) -> some View {
        let page = model.pages[idx]
        // Trimmed, only the trim shows (boxes, split and rulers in its terms);
        // while the trim is drawn, the whole page.
        let trimming = model.trimmingPage == page.id
        let area = trimming ? CropRect.full : page.bounds
        RulerFrame {
            GeometryReader { geo in
                // A trim is shown larger: rendered as finely as that zoom would be.
                let image = model.previewImage(for: page, zoom: model.zoom / min(area.width, area.height))
                let fit = imageFrame(size: image.map { CGSize(width: $0.size.width * area.width, height: $0.size.height * area.height) },
                                     in: geo.size)
                let zoom = min(8, max(1, CGFloat(model.zoom) * pinch))
                // Zoomed, the page grows inside a scroll view; the canvas is at least the
                // window's size so a small page stays centered.
                let canvas = CGSize(width: max(geo.size.width, fit.width * zoom + 48),
                                    height: max(geo.size.height, fit.height * zoom + 48))
                let frame = CGRect(x: (canvas.width - fit.width * zoom) / 2,
                                   y: (canvas.height - fit.height * zoom) / 2,
                                   width: fit.width * zoom, height: fit.height * zoom)

                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        Color(nsColor: .underPageBackgroundColor)

                        if let image {
                            // The whole scan at the trim's scale, cut to the trim.
                            let whole = CGSize(width: frame.width / area.width, height: frame.height / area.height)
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: whole.width, height: whole.height)
                                .offset(x: -area.x * whole.width - (frame.width - whole.width) / 2,
                                        y: -area.y * whole.height - (frame.height - whole.height) / 2)
                                .frame(width: frame.width, height: frame.height)
                                .clipped()
                                .rulerPage(size: model.displaySize(of: page).map { CGSize(width: $0.width * area.width,
                                                                                        height: $0.height * area.height) } ?? .zero,
                                           marks: rulerMarks(page, area))
                                .position(x: frame.midX, y: frame.midY)
                        } else {
                            ProgressView()
                        }

                        if trimming {
                            trimOverlay(frame: frame)
                        } else if page.classification == .skip {
                            skipOverlay(frame: frame)
                        } else if frame.width > 0, model.erasingPage != page.id {
                            overlays(for: idx, frame: frame, area: area)
                        }
                        // Erase boxes stay visible so the blanked area is obvious.
                        // While erasing, the crop boxes above are gone: they would
                        // take the drag that draws a new box.
                        if !trimming, frame.width > 0,
                           model.erasingPage == page.id || page.erasures?.isEmpty == false {
                            eraseOverlay(for: idx, frame: frame, area: area, canvas: canvas)
                        }
                    }
                    .frame(width: canvas.width, height: canvas.height)
                    .coordinateSpace(name: "pageCanvas")
                    .focusable(model.erasingPage == page.id)
                    .onDeleteCommand {
                        if model.erasingPage == page.id { model.removeSelectedErasure() }
                    }
                }
                .scrollDisabled(zoom <= 1)
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in
                            model.zoom = min(8, max(1, model.zoom * value.magnification))
                        }
                )
            }
            .overlay(alignment: .bottom) {
                if !trimming, let readout = sizeReadout(page) {
                    CropSizeLabel(readout: readout)
                }
            }
        }
    }

    private func sizeReadout(_ page: BookPage) -> CropSizeReadout? {
        guard page.classification != .skip, let size = model.displaySize(of: page) else { return nil }
        return CropSizeReadout(leftCrop: page.leftCrop, rightCrop: page.classification == .spread ? page.rightCrop : nil,
                               in: size, unit: RulerUnit())
    }

    /// Where the crops start and end, for the rulers (which measure what shows).
    private func rulerMarks(_ page: BookPage, _ area: CropRect) -> [RulerMark] {
        switch page.classification {
        case .skip: return []
        case .single: return [RulerMark(crop: page.leftCrop.relative(to: area), color: .blue)]
        case .spread: return [RulerMark(crop: page.leftCrop.relative(to: area), color: .blue),
                              RulerMark(crop: page.rightCrop.relative(to: area), color: .green)]
        }
    }

    /// Trim: the trim's box over the whole page, the rest dimmed.
    @ViewBuilder
    private func trimOverlay(frame: CGRect) -> some View {
        let t = model.trimDraft
        let shown = CGRect(x: frame.minX + t.x * frame.width, y: frame.minY + t.y * frame.height,
                           width: t.width * frame.width, height: t.height * frame.height)
        Path { p in p.addRect(frame); p.addRect(shown) }
            .fill(.black.opacity(0.4), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
        CropBoxView(crop: Binding(get: { model.trimDraft }, set: { model.trimDraft = $0 }),
                    imageFrame: frame, color: .pink, label: "Trim", tracksPageEdits: false)
    }

    /// Each erase box, white so the page shows what will go blank, with a red
    /// edge. While erasing, a drag on empty page draws a new one and the selected
    /// box can be moved.
    @ViewBuilder
    private func eraseOverlay(for idx: Int, frame: CGRect, area: CropRect, canvas: CGSize) -> some View {
        let page = model.pages[idx]
        let boxes = page.erasures ?? []
        let erasing = model.erasingPage == page.id
        // One canvas-sized layer, so positions match the crop boxes' frame.
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: canvas.width, height: canvas.height).allowsHitTesting(false)
            if erasing {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .highPriorityGesture(eraseDrawGesture(idx: idx, frame: frame, area: area))
            }
            ForEach(Array(boxes.indices), id: \.self) { i in
                if let r = placed(boxes[i], frame: frame, area: area) {
                    eraseMark(r, tap: erasing && model.selectedErasure != i ? i : nil)
                }
            }
            if erasing, let i = model.selectedErasure, boxes.indices.contains(i) {
                CropBoxView(crop: erasureBinding(idx, i, area), imageFrame: frame,
                            color: .red, label: "Erase", tracksPageEdits: true)
            }
            if erasing, let draft = eraseDraft, let r = placed(draft, frame: frame, area: area) {
                eraseMark(r, tap: nil)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    /// White at 85% with a thin red edge. `tap` selects that box; nil lets hits through.
    @ViewBuilder
    private func eraseMark(_ r: CGRect, tap: Int?) -> some View {
        let mark = Rectangle()
            .fill(Color.white.opacity(0.85))
            .overlay(Rectangle().stroke(Color.red, lineWidth: 1))
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .position(x: r.midX, y: r.midY)
        if let tap {
            mark.onTapGesture { model.selectedErasure = tap }
        } else {
            mark.allowsHitTesting(false)
        }
    }

    private func eraseDrawGesture(idx: Int, frame: CGRect, area: CropRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("pageCanvas"))
            .onChanged { value in
                let start = pagePoint(value.startLocation, frame: frame, area: area)
                let boxes = model.pages.indices.contains(idx) ? (model.pages[idx].erasures ?? []) : []
                // A drag that starts on a box selects it (the tap) rather than drawing another.
                if eraseDraft == nil, boxes.contains(where: { covers($0, start) }) { return }
                eraseDraft = span(start, pagePoint(value.location, frame: frame, area: area))
            }
            .onEnded { _ in
                let drawn = eraseDraft
                eraseDraft = nil
                if let drawn { model.addErasure(drawn) }
            }
    }

    private func erasureBinding(_ idx: Int, _ box: Int, _ area: CropRect) -> Binding<CropRect> {
        Binding(get: {
            let boxes = model.pages[idx].erasures ?? []
            let r = boxes.indices.contains(box) ? boxes[box] : .full
            return r.relative(to: area)
        }, set: { model.setErasure($0.absolute(in: area), at: box) })
    }

    /// `box` in the canvas, clipped to the part of the page on show (`area`).
    private func placed(_ box: CropRect, frame: CGRect, area: CropRect) -> CGRect? {
        let x0 = max(box.minX, area.minX), y0 = max(box.minY, area.minY)
        let x1 = min(box.maxX, area.maxX), y1 = min(box.maxY, area.maxY)
        guard x1 > x0, y1 > y0, area.width > 0, area.height > 0, frame.width > 0 else { return nil }
        let rx = (x0 - area.x) / area.width, ry = (y0 - area.y) / area.height
        return CGRect(x: frame.minX + rx * frame.width,
                      y: frame.minY + ry * frame.height,
                      width: (x1 - x0) / area.width * frame.width,
                      height: (y1 - y0) / area.height * frame.height)
    }

    private func pagePoint(_ p: CGPoint, frame: CGRect, area: CropRect) -> (x: Double, y: Double) {
        let rx = (Double(p.x) - frame.minX) / Double(frame.width)
        let ry = (Double(p.y) - frame.minY) / Double(frame.height)
        return (area.x + rx * area.width, area.y + ry * area.height)
    }

    private func span(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> CropRect {
        CropRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func covers(_ box: CropRect, _ p: (x: Double, y: Double)) -> Bool {
        p.x >= box.minX && p.x <= box.maxX && p.y >= box.minY && p.y <= box.maxY
    }

    @ViewBuilder
    private func overlays(for idx: Int, frame: CGRect, area: CropRect) -> some View {
        let page = model.pages[idx]

        // Left / single crop.
        let leftOut = page.isSpread && page.omittedSide == .left
        if model.straightenFocus.side == .left {
            StraightenGrid(crop: page.leftCrop.relative(to: area), imageFrame: frame)
        }
        CropBoxView(crop: leftBinding(idx, area),
                    imageFrame: frame,
                    color: leftOut ? .gray : .blue,
                    label: page.classification == .single ? "Page" : leftOut ? "Left · not exported" : "Left",
                    dimmed: leftOut)

        if page.classification == .spread {
            let rightOut = page.omittedSide == .right
            if model.straightenFocus.side == .right {
                StraightenGrid(crop: page.rightCrop.relative(to: area), imageFrame: frame)
            }
            CropBoxView(crop: rightBinding(idx, area),
                        imageFrame: frame,
                        color: rightOut ? .gray : .green,
                        label: rightOut ? "Right · not exported" : "Right",
                        labelEdge: .trailing,
                        dimmed: rightOut)
            SplitLine(splitX: splitBinding(idx, area), imageFrame: frame)
            // Shared top/bottom margin guides: drag once to move BOTH pages'
            // top (or bottom) crop edge together.
            HGuide(y: topBinding(idx, area), imageFrame: frame, edge: .top)
            HGuide(y: bottomBinding(idx, area), imageFrame: frame, edge: .bottom)
        }
    }

    private func skipOverlay(frame: CGRect) -> some View {
        Rectangle()
            .fill(.black.opacity(0.45))
            .frame(width: frame.width, height: frame.height)
            .overlay(
                Label("Skipped", systemImage: "xmark.circle.fill")
                    .font(.title2).foregroundStyle(.white)
            )
            .position(x: frame.midX, y: frame.midY)
    }

    // MARK: - Bindings into the pages array

    // Each in the terms of `area`, what shows of the page (its trim): a box kept in
    // the view stays inside the trim.

    // A box drag sets the crop here; with Lock sizes on, a spread's other box follows it.
    private func leftBinding(_ idx: Int, _ area: CropRect) -> Binding<CropRect> {
        Binding(get: { model.pages[idx].leftCrop.relative(to: area) },
                set: { model.setSpreadCrop($0.absolute(in: area), on: .left, at: idx, locked: locksSizes) })
    }
    private func rightBinding(_ idx: Int, _ area: CropRect) -> Binding<CropRect> {
        Binding(get: { model.pages[idx].rightCrop.relative(to: area) },
                set: { model.setSpreadCrop($0.absolute(in: area), on: .right, at: idx, locked: locksSizes) })
    }
    private func splitBinding(_ idx: Int, _ area: CropRect) -> Binding<Double> {
        Binding(
            get: { (model.pages[idx].splitX - area.x) / area.width },
            set: { model.moveSplit(at: idx, to: area.x + $0 * area.width, locked: locksSizes) }
        )
    }

    /// Shared TOP edge of both crops. Reading position is the average of the
    /// two current tops; setting it moves both tops together (bottoms fixed).
    private func topBinding(_ idx: Int, _ area: CropRect) -> Binding<Double> {
        Binding(
            get: {
                let l = model.pages[idx].leftCrop, r = model.pages[idx].rightCrop
                return ((l.minY + r.minY) / 2 - area.y) / area.height
            },
            set: { newTop in
                let t = area.y + max(0, min(newTop, 1)) * area.height
                var l = model.pages[idx].leftCrop
                var r = model.pages[idx].rightCrop
                let lBottom = l.maxY, rBottom = r.maxY
                let lt = min(t, lBottom - 0.02)
                let rt = min(t, rBottom - 0.02)
                l.y = lt; l.height = lBottom - lt
                r.y = rt; r.height = rBottom - rt
                l.normalize(); r.normalize()
                model.pages[idx].leftCrop = l
                model.pages[idx].rightCrop = r
            }
        )
    }

    /// Shared BOTTOM edge of both crops; setting it moves both bottoms together.
    private func bottomBinding(_ idx: Int, _ area: CropRect) -> Binding<Double> {
        Binding(
            get: {
                let l = model.pages[idx].leftCrop, r = model.pages[idx].rightCrop
                return ((l.maxY + r.maxY) / 2 - area.y) / area.height
            },
            set: { newBottom in
                let b = area.y + max(0, min(newBottom, 1)) * area.height
                var l = model.pages[idx].leftCrop
                var r = model.pages[idx].rightCrop
                let lTop = l.minY, rTop = r.minY
                let lb = max(b, lTop + 0.02)
                let rb = max(b, rTop + 0.02)
                l.height = lb - lTop
                r.height = rb - rTop
                l.normalize(); r.normalize()
                model.pages[idx].leftCrop = l
                model.pages[idx].rightCrop = r
            }
        )
    }

    // MARK: - Layout

    /// Where a picture of `size` (what shows of the page) fits in the container.
    private func imageFrame(size: CGSize?, in container: CGSize) -> CGRect {
        guard let size, size.width > 0, size.height > 0 else {
            return .zero
        }
        let inset: CGFloat = 24
        let avail = CGSize(width: max(1, container.width - inset * 2),
                           height: max(1, container.height - inset * 2))
        let scale = min(avail.width / size.width, avail.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }
}

/// Vertical draggable gutter indicator for spreads. Its grip sits above the page,
/// clear of the crop labels and handles.
struct SplitLine: View {
    @EnvironmentObject var model: AppModel
    @Binding var splitX: Double
    let imageFrame: CGRect
    var tracksPageEdits = true

    var body: some View {
        let x = imageFrame.minX + splitX * imageFrame.width
        let grip: CGFloat = 18
        VStack(spacing: 0) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 9, weight: .bold))
                .frame(width: grip + 8, height: grip)
                .background(.orange, in: Capsule())
                .foregroundStyle(.white)
            Rectangle()
                .fill(.orange)
                .frame(width: 1.5, height: imageFrame.height + 12)   // clear of the corner handles
                .frame(width: 4)            // a little easier to grab than the line itself
                .contentShape(Rectangle())
        }
        .position(x: x, y: imageFrame.midY - grip / 2)
        .help("Split line: drag to move the fold")
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if tracksPageEdits { model.beginEdit() }
                    let nx = (value.location.x - imageFrame.minX) / imageFrame.width
                    splitX = nx
                }
                .onEnded { _ in if tracksPageEdits { model.endEdit("Move Split") } }
        )
    }
}

/// Horizontal draggable guide that moves a shared top/bottom margin for a spread:
/// a tab in the margin left of the page, and a faint line across it.
struct HGuide: View {
    enum Edge { case top, bottom }
    @EnvironmentObject var model: AppModel
    @Binding var y: Double
    let imageFrame: CGRect
    let edge: Edge
    var tracksPageEdits = true

    var body: some View {
        let yy = imageFrame.minY + y * imageFrame.height
        let tab: CGFloat = 18
        HStack(spacing: 2) {
            Image(systemName: "arrow.up.and.down")
                .font(.system(size: 9, weight: .bold))
                .frame(width: tab, height: tab)
                .background(.purple, in: Circle())
                .foregroundStyle(.white)
            Line()
                .stroke(.purple.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: imageFrame.width, height: 5)
                // Only the tab drags: the line lies on the crops' own top or bottom
                // edges and would take their handles' drags.
                .allowsHitTesting(false)
        }
        .position(x: imageFrame.midX - (tab + 2) / 2, y: yy)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if tracksPageEdits { model.beginEdit() }
                    y = (value.location.y - imageFrame.minY) / imageFrame.height
                }
                .onEnded { _ in if tracksPageEdits { model.endEdit("Move Margin") } }
        )
        .help(edge == .top ? "Shared top margin (both pages)" : "Shared bottom margin (both pages)")
    }
}

/// A horizontal line through the middle of its frame.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

private struct ContentUnavailablePlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.viewfinder").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No page selected").font(.title3)
            Text("Open a PDF, then pick a page from the left.").foregroundStyle(.secondary)
        }
    }
}
