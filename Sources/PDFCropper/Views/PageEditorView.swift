import SwiftUI

/// The central canvas: shows the selected source page with editable crop boxes
/// and (for spreads) a draggable gutter / split line.
struct PageEditorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let idx = model.selectedIndex {
            editor(for: idx)
        } else {
            ContentUnavailablePlaceholder()
        }
    }

    /// Live pinch amount, applied on top of model.zoom until the gesture ends.
    @GestureState private var pinch: CGFloat = 1

    @ViewBuilder
    private func editor(for idx: Int) -> some View {
        let page = model.pages[idx]
        GeometryReader { geo in
            let image = model.previewImage(for: page, zoom: model.zoom)
            let fit = imageFrame(image: image, in: geo.size)
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
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    } else {
                        ProgressView()
                    }

                    if page.classification == .skip {
                        skipOverlay(frame: frame)
                    } else if frame.width > 0 {
                        overlays(for: idx, frame: frame)
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
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
    }

    @ViewBuilder
    private func overlays(for idx: Int, frame: CGRect) -> some View {
        let page = model.pages[idx]

        // Left / single crop.
        CropBoxView(crop: leftBinding(idx),
                    imageFrame: frame,
                    color: .blue,
                    label: page.classification == .single ? "Page" : "Left")

        if page.classification == .spread {
            CropBoxView(crop: rightBinding(idx),
                        imageFrame: frame,
                        color: .green,
                        label: "Right",
                        labelEdge: .trailing)
            SplitLine(splitX: splitBinding(idx), imageFrame: frame)
            // Shared top/bottom margin guides: drag once to move BOTH pages'
            // top (or bottom) crop edge together.
            HGuide(y: topBinding(idx), imageFrame: frame, edge: .top)
            HGuide(y: bottomBinding(idx), imageFrame: frame, edge: .bottom)
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

    private func leftBinding(_ idx: Int) -> Binding<CropRect> {
        Binding(get: { model.pages[idx].leftCrop },
                set: { model.pages[idx].leftCrop = $0 })
    }
    private func rightBinding(_ idx: Int) -> Binding<CropRect> {
        Binding(get: { model.pages[idx].rightCrop },
                set: { model.pages[idx].rightCrop = $0 })
    }
    private func splitBinding(_ idx: Int) -> Binding<Double> {
        Binding(
            get: { model.pages[idx].splitX },
            set: { newValue in
                let clamped = max(0.05, min(newValue, 0.95))
                model.pages[idx].splitX = clamped
                // Tie inner crop edges to the gutter.
                var l = model.pages[idx].leftCrop
                if clamped > l.minX + 0.02 { l.width = clamped - l.minX }
                l.normalize(); model.pages[idx].leftCrop = l
                var r = model.pages[idx].rightCrop
                if clamped < r.maxX - 0.02 {
                    let right = r.maxX
                    r.x = clamped; r.width = right - clamped
                }
                r.normalize(); model.pages[idx].rightCrop = r
            }
        )
    }

    /// Shared TOP edge of both crops. Reading position is the average of the
    /// two current tops; setting it moves both tops together (bottoms fixed).
    private func topBinding(_ idx: Int) -> Binding<Double> {
        Binding(
            get: {
                let l = model.pages[idx].leftCrop, r = model.pages[idx].rightCrop
                return (l.minY + r.minY) / 2
            },
            set: { newTop in
                let t = max(0, min(newTop, 1))
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
    private func bottomBinding(_ idx: Int) -> Binding<Double> {
        Binding(
            get: {
                let l = model.pages[idx].leftCrop, r = model.pages[idx].rightCrop
                return (l.maxY + r.maxY) / 2
            },
            set: { newBottom in
                let b = max(0, min(newBottom, 1))
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

    private func imageFrame(image: NSImage?, in container: CGSize) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return .zero
        }
        let inset: CGFloat = 24
        let avail = CGSize(width: max(1, container.width - inset * 2),
                           height: max(1, container.height - inset * 2))
        let scale = min(avail.width / image.size.width, avail.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }
}

/// Vertical draggable gutter indicator for spreads. Its grip sits above the page,
/// clear of the crop labels and handles.
private struct SplitLine: View {
    @EnvironmentObject var model: AppModel
    @Binding var splitX: Double
    let imageFrame: CGRect

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
                    model.beginEdit()
                    let nx = (value.location.x - imageFrame.minX) / imageFrame.width
                    splitX = nx
                }
                .onEnded { _ in model.endEdit("Move Split") }
        )
    }
}

/// Horizontal draggable guide that moves a shared top/bottom margin for a spread:
/// a tab in the margin left of the page, and a faint line across it.
private struct HGuide: View {
    enum Edge { case top, bottom }
    @EnvironmentObject var model: AppModel
    @Binding var y: Double
    let imageFrame: CGRect
    let edge: Edge

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
                    model.beginEdit()
                    y = (value.location.y - imageFrame.minY) / imageFrame.height
                }
                .onEnded { _ in model.endEdit("Move Margin") }
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
