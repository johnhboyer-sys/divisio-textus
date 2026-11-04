import SwiftUI
import AppKit

/// Grid view: every page with its split and crops drawn on. Click, ⌘-click and
/// ⇧-click choose pages for the sidebar to act on; Return or a double-click opens
/// the last one clicked in Page view.
struct GridView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("gridCellSize") private var cellSize = 200.0
    @FocusState private var focused: Bool

    var body: some View {
        let flagged = model.flaggedSides
        let shown = model.gridPages
        let order = shown.map(\.id)
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $model.showsOnlyFlagged) {
                    Text("All").tag(false)
                    Text(flagged.isEmpty ? "Needs a look" : "Needs a look (\(flagged.count))").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Needs a look: pages whose crop is a different size from the rest of its stack")
                Spacer()
                Text("Size").foregroundStyle(.secondary)
                Slider(value: $cellSize, in: 120...360)
                    .labelsHidden()
                    .frame(width: 140)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize), spacing: 18)], spacing: 18) {
                        ForEach(shown) { page in
                            GridCell(page: page, height: cellSize / 1.45,
                                     flagged: flagged[page.id] != nil,
                                     chosen: model.gridSelection.contains(page.id),
                                     last: page.id == model.selectedPageID)
                                .id(page.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    focused = true
                                    let keys = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags   // the click's own keys
                                    model.chooseInGrid(page.id, keys.contains(.shift) ? .range : keys.contains(.command) ? .toggle : .plain,
                                                       order: order)
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded { model.openInPageView(page.id) })
                        }
                    }
                    .padding(18)
                    if shown.isEmpty {
                        Text(model.isAnalyzing ? "Pages are judged once analysis finishes."
                                               : "Every page's crops match the rest of its stack.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                }
                // Keep the last page chosen in view when ↑/↓ move it.
                .onChange(of: model.selectedPageID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id) }
                }
                .onAppear { if let id = model.selectedPageID { proxy.scrollTo(id, anchor: .center) } }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: shown.map(\.id)) { _, _ in model.keepGridChoiceShown() }
        .onKeyPress(.return) {
            guard let id = model.selectedPageID else { return .ignored }
            model.openInPageView(id)
            return .handled
        }
        .onAppear { focused = true }
    }
}

/// One page: its picture (only its trim) with the crops and split on it, a red dot
/// when it needs a look, its number and its angle. The last page clicked has its
/// number on blue.
private struct GridCell: View {
    @EnvironmentObject var model: AppModel
    let page: BookPage
    let height: CGFloat
    let flagged: Bool
    let chosen: Bool
    let last: Bool

    var body: some View {
        VStack(spacing: 6) {
            picture
                .frame(height: height)
                .frame(maxWidth: .infinity)
            caption
        }
    }

    @ViewBuilder
    private var picture: some View {
        let area = page.bounds
        if let cg = model.gridImage(for: page) {
            let part = cg.cropping(to: area.pixelRect(in: CGSize(width: cg.width, height: cg.height)).integral) ?? cg
            Image(decorative: part, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay { if page.classification != .skip { marks(area) } }
                .opacity(page.classification == .skip ? 0.35 : 1)
                .overlay {
                    if page.classification == .skip {
                        Text("Left out").font(.caption.weight(.semibold))
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(chosen ? Color.accentColor : .clear, lineWidth: 3))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .aspectRatio(1.45, contentMode: .fit)
                .overlay(ProgressView().controlSize(.small))
        }
    }

    /// The crops and split, in the terms of what shows (the trim).
    private func marks(_ area: CropRect) -> some View {
        Canvas { context, size in
            func rect(_ c: CropRect) -> CGRect {
                let r = c.relative(to: area)
                return CGRect(x: r.x * size.width, y: r.y * size.height, width: r.width * size.width, height: r.height * size.height)
            }
            func box(_ c: CropRect, _ color: Color) {
                context.fill(Path(rect(c)), with: .color(color.opacity(0.1)))
                context.stroke(Path(rect(c)), with: .color(color), lineWidth: 1.2)
            }
            if page.isSpread {
                box(page.leftCrop, page.omittedSide == .left ? .gray : .blue)
                box(page.rightCrop, page.omittedSide == .right ? .gray : .green)
                let x = (page.splitX - area.x) / area.width * size.width
                context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.orange))
            } else {
                box(page.leftCrop, .blue)
            }
        }
        .allowsHitTesting(false)
    }

    private var caption: some View {
        HStack(spacing: 4) {
            if flagged {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(last && chosen ? .white : .red)
            }
            Text("\(page.sourceIndex + 1)").fontWeight(.semibold)
            if page.classification != .skip, let tilt {
                Text(tilt).foregroundStyle(last && chosen ? .white : .secondary)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 7).padding(.vertical, 1)
        .background(last && chosen ? Color.accentColor : .clear, in: Capsule())
        .foregroundStyle(last && chosen ? .white : .primary)
    }

    /// The page's straightening, when it has any: one angle, or a spread's two.
    private var tilt: String? {
        let l = page.leftSkew, r = page.rightSkew
        func f(_ v: Double) -> String { String(format: "%+.1f°", v) }
        if !page.isSpread { return abs(l) < 0.05 ? nil : f(l) }
        if abs(l) < 0.05 && abs(r) < 0.05 { return nil }
        return abs(l - r) < 0.05 ? f(l) : "\(f(l)) \(f(r))"
    }
}
