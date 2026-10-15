import SwiftUI

/// A draggable / resizable crop rectangle drawn over the page image.
/// `crop` is normalized (top-left origin); `imageFrame` is where the image is
/// actually drawn inside the editor in view coordinates.
struct CropBoxView: View {
    @Binding var crop: CropRect
    let imageFrame: CGRect
    let color: Color
    let label: String

    // Snapshot of the crop when a drag begins, so deltas are stable.
    @State private var dragStart: CropRect?

    private let handle: CGFloat = 12

    private var viewRect: CGRect {
        CGRect(x: imageFrame.minX + crop.x * imageFrame.width,
               y: imageFrame.minY + crop.y * imageFrame.height,
               width: crop.width * imageFrame.width,
               height: crop.height * imageFrame.height)
    }

    var body: some View {
        let r = viewRect
        ZStack(alignment: .topLeading) {
            // Body: drag to move.
            Rectangle()
                .fill(color.opacity(0.10))
                .overlay(Rectangle().stroke(color, lineWidth: 2))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .gesture(moveGesture)

            // Label chip.
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(color.opacity(0.85))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .offset(x: r.minX + 4, y: r.minY + 4)
                .allowsHitTesting(false)

            // Edge midpoint handles (drag one side at a time).
            edgeHandle(.top, at: CGPoint(x: r.midX, y: r.minY))
            edgeHandle(.bottom, at: CGPoint(x: r.midX, y: r.maxY))
            edgeHandle(.leading, at: CGPoint(x: r.minX, y: r.midY))
            edgeHandle(.trailing, at: CGPoint(x: r.maxX, y: r.midY))

            // Corner resize handles.
            cornerHandle(.topLeading, at: CGPoint(x: r.minX, y: r.minY))
            cornerHandle(.topTrailing, at: CGPoint(x: r.maxX, y: r.minY))
            cornerHandle(.bottomLeading, at: CGPoint(x: r.minX, y: r.maxY))
            cornerHandle(.bottomTrailing, at: CGPoint(x: r.maxX, y: r.maxY))
        }
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                var c = start
                c.x = start.x + value.translation.width / imageFrame.width
                c.y = start.y + value.translation.height / imageFrame.height
                // Move keeps size; clamp position.
                c.x = max(0, min(c.x, 1 - c.width))
                c.y = max(0, min(c.y, 1 - c.height))
                crop = c
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: Edge handles

    private enum Edge { case top, bottom, leading, trailing }

    private func edgeHandle(_ edge: Edge, at point: CGPoint) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(color, lineWidth: 2))
            .frame(width: handle, height: handle)
            .position(x: point.x, y: point.y)
            .gesture(edgeResizeGesture(edge))
    }

    private func edgeResizeGesture(_ edge: Edge) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                let dx = value.translation.width / imageFrame.width
                let dy = value.translation.height / imageFrame.height

                var left = start.minX, top = start.minY
                var right = start.maxX, bottom = start.maxY

                switch edge {
                case .top:      top += dy
                case .bottom:   bottom += dy
                case .leading:  left += dx
                case .trailing: right += dx
                }

                var c = CropRect(x: min(left, right),
                                 y: min(top, bottom),
                                 width: abs(right - left),
                                 height: abs(bottom - top))
                c.normalize()
                crop = c
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: Corner handles

    private enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private func cornerHandle(_ corner: Corner, at point: CGPoint) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(color, lineWidth: 2))
            .frame(width: handle, height: handle)
            .position(x: point.x, y: point.y)
            .gesture(resizeGesture(corner))
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                let dx = value.translation.width / imageFrame.width
                let dy = value.translation.height / imageFrame.height

                var left = start.minX, top = start.minY
                var right = start.maxX, bottom = start.maxY

                switch corner {
                case .topLeading:     left += dx; top += dy
                case .topTrailing:    right += dx; top += dy
                case .bottomLeading:  left += dx; bottom += dy
                case .bottomTrailing: right += dx; bottom += dy
                }

                var c = CropRect(x: min(left, right),
                                 y: min(top, bottom),
                                 width: abs(right - left),
                                 height: abs(bottom - top))
                c.normalize()
                crop = c
            }
            .onEnded { _ in dragStart = nil }
    }
}
