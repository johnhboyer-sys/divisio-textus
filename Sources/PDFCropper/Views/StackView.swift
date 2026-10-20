import SwiftUI

/// Review the common crop and the pages whose edges differ from it.
struct StackView: View {
    @EnvironmentObject var model: AppModel
    private let imageState = State<CGImage?>(initialValue: nil)
    private let loadingState = State<Bool>(initialValue: false)
    private let refreshState = State<Int>(initialValue: 0)
    private let lastRefreshState = State<Int>(initialValue: 0)
    // Which stack and PDF the image on screen belongs to.
    private let imageKindState = State<PageStack.Kind?>(initialValue: nil)
    private let imageDocumentState = State<ObjectIdentifier?>(initialValue: nil)
    private var imageKind: PageStack.Kind? {
        get { imageKindState.wrappedValue }
        nonmutating set { imageKindState.wrappedValue = newValue }
    }
    private var imageDocument: ObjectIdentifier? {
        get { imageDocumentState.wrappedValue }
        nonmutating set { imageDocumentState.wrappedValue = newValue }
    }

    private var stacks: [PageStack] { PageStack.groups(pages: model.pages) }
    private var stack: PageStack? { stacks.first { $0.id == model.stackKind } ?? stacks.first }

    /// The orange box: the user's draft for this stack, or else the stack's usual crop.
    private func draft(_ stack: PageStack) -> Binding<CropRect> {
        Binding(get: { model.stackCrops[stack.id] ?? stack.medianCrop.normalized() },
                set: { model.stackCrops[stack.id] = $0 })
    }

    private struct Request: Equatable {
        let document: ObjectIdentifier?
        let kind: PageStack.Kind?
        let geometry: [PageStack.Geometry]
        let refresh: Int
        let analyzing: Bool
    }
    private var request: Request {
        Request(document: model.document.map { ObjectIdentifier($0) }, kind: stack?.id,
                geometry: stack?.geometry ?? [], refresh: refreshState.wrappedValue,
                analyzing: model.isAnalyzing)
    }

    var body: some View {
        VStack {
            HStack {
                Picker("Stack", selection: $model.stackKind) {
                    ForEach(stacks) { stack in
                        Text("\(stack.id.label) (\(stack.members.count))").tag(stack.id)
                    }
                }
                .fixedSize()
                Button { refreshState.wrappedValue += 1 } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .help("Rebuild the stack image")
                .disabled(stack == nil || loadingState.wrappedValue)
                Spacer()
                if let stack {
                    Menu("Apply Crop") {
                        Button("To All \(stack.members.count) Pages") {
                            model.applyStackCrop(draft(stack).wrappedValue, to: stack.members)
                        }
                        Button("To the \(stack.outliers.count) Flagged Pages") {
                            model.applyStackCrop(draft(stack).wrappedValue, to: stack.outliers)
                        }
                        .disabled(stack.outliers.isEmpty)
                    }
                    .fixedSize()
                    .disabled(model.isAnalyzing || imageState.wrappedValue == nil)
                    .help("Set every page in this stack, or only the flagged ones, to the orange crop")
                }
            }
            .padding([.horizontal, .top])
            if let stack {
                HSplitView {
                    canvas(stack)
                        .frame(minWidth: 240, minHeight: 240)
                    VStack(alignment: .leading, spacing: 0) {
                        // Until analysis is done the crops are placeholders, so judging them misleads.
                        if !model.isAnalyzing {
                            Text(stack.outliers.isEmpty ? "No page differs in size"
                                 : "\(stack.outliers.count) differ in size")
                                .font(.headline).padding(8)
                                .help("Pages whose crop is a different size from the rest of this stack")
                            List(stack.outliers) { member in
                                Button("p. \(member.page.sourceIndex + 1) · \(member.side.rawValue)") {
                                    model.selectedPageID = member.id
                                    model.showsStack = false
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: 110, idealWidth: 130, maxWidth: 170)
                }
            } else {
                Text("No pages to stack.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .task(id: request) {
            let requested = request
            // Analysis moves splits and skews page by page; build the blend once it settles.
            guard let stack, !requested.analyzing else {
                imageState.wrappedValue = nil
                loadingState.wrappedValue = false
                return
            }
            model.stackKind = stack.id
            // Another stack or PDF needs a new picture; a straightened page or Refresh
            // only adjusts this one, so keep showing it while the new one builds.
            if imageKind != requested.kind || imageDocument != requested.document { imageState.wrappedValue = nil }
            loadingState.wrappedValue = true
            let refresh = requested.refresh != lastRefreshState.wrappedValue
            lastRefreshState.wrappedValue = requested.refresh
            // A dragged Straighten slider changes the stack many times a second: wait
            // for it to rest. A newer request cancels this one, sleep included.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let image = await model.stackImage(for: stack, refresh: refresh)
            guard !Task.isCancelled, request == requested else { return }
            imageState.wrappedValue = image
            imageKind = requested.kind
            imageDocument = requested.document
            loadingState.wrappedValue = false
        }
    }

    private func canvas(_ stack: PageStack) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                if let image = imageState.wrappedValue {
                    let frame = imageFrame(image, in: geo.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    let flagged = Set(stack.outliers.map(\.id))
                    ForEach(stack.members) { member in
                        outline(member.crop, in: frame, color: flagged.contains(member.id) ? .red : .blue,
                                width: flagged.contains(member.id) ? 2 : 1,
                                opacity: flagged.contains(member.id) ? 0.8 : 0.18)
                    }
                    CropBoxView(crop: draft(stack), imageFrame: frame,
                                color: .orange, label: "Stack crop", tracksPageEdits: false)
                    outline(stack.medianCrop, in: frame, color: .primary, width: 1, opacity: 0.8, dashed: true)
                } else if model.isAnalyzing {
                    Text("Waiting for page analysis to finish…")
                        .foregroundStyle(.secondary)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if loadingState.wrappedValue {
                    ProgressView().frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Text("Could not build the stack. Press Refresh to try again.")
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .clipped()
        }
    }

    private func outline(_ crop: CropRect, in frame: CGRect, color: Color,
                         width: CGFloat, opacity: Double, dashed: Bool = false) -> some View {
        Rectangle()
            .stroke(color.opacity(opacity), style: StrokeStyle(lineWidth: width, dash: dashed ? [6, 4] : []))
            .frame(width: max(0, crop.width * frame.width), height: max(0, crop.height * frame.height))
            .position(x: frame.minX + (crop.x + crop.width / 2) * frame.width,
                      y: frame.minY + (crop.y + crop.height / 2) * frame.height)
            .allowsHitTesting(false)
    }

    private func imageFrame(_ image: CGImage, in size: CGSize) -> CGRect {
        let scale = min(max(1, size.width - 48) / Double(image.width),
                        max(1, size.height - 48) / Double(image.height))
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}
