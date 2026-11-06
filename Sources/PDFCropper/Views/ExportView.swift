import SwiftUI

/// Export…: the pages the export will write, made the way it makes them, beside the
/// export's settings and the Export PDF… button. Esc or Back goes back.
struct ExportView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Button { model.showsExport = false } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Text("Esc goes back").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                OutputPages()
                Divider()
                Text("\(model.outputPageCount) output pages from \(model.pages.count) scans.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(6)
            }
            .frame(minWidth: 380)
            Divider()
            ExportOptions()
                .frame(width: 300)
        }
    }
}

/// Every output page, in reading order, each spread's pair side by side. A page
/// left out of the export shows as a dashed outline in its place.
private struct OutputPages: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let flagged = model.flaggedSides
        let firsts = firstNumbers()
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 24)], spacing: 20) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { i, page in
                    OutputGroup(page: page, first: firsts[i], flagged: flagged[page.id] ?? [])
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// Each scan's first output page number.
    private func firstNumbers() -> [Int] {
        var n = 1
        return model.pages.map { page in
            defer { n += page.outputCrops(direction: model.direction).count }
            return n
        }
    }
}

private struct OutputGroup: View {
    @EnvironmentObject var model: AppModel
    let page: BookPage
    let first: Int
    let flagged: [PageStack.Member.Side]

    private let height: CGFloat = 150

    var body: some View {
        let images = model.outputPreview(for: page)
        HStack(alignment: .top, spacing: 4) {
            switch page.classification {
            case .skip:
                leftOut(aspect: aspect(of: nil), caption: "Scan \(page.sourceIndex + 1)")
            case .single:
                if let image = images.first {
                    shown(image, number: first, flag: !flagged.isEmpty)
                }
            case .spread:
                let sides: [BookPage.Side] = model.direction == .leftToRight ? [.left, .right] : [.right, .left]
                let kept = sides.filter { $0 != page.omittedSide }
                ForEach(sides, id: \.self) { side in
                    if side == page.omittedSide {
                        leftOut(aspect: aspect(of: side), caption: "Scan \(page.sourceIndex + 1) \(side.rawValue)")
                    } else if let k = kept.firstIndex(of: side), images.indices.contains(k) {
                        shown(images[k], number: first + k,
                              flag: flagged.contains(.whole) || flagged.contains(side == .left ? .left : .right))
                    }
                }
            }
        }
    }

    private func shown(_ image: CGImage, number: Int, flag: Bool) -> some View {
        VStack(spacing: 4) {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: height * Double(image.width) / Double(max(1, image.height)), height: height)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            caption(flag: flag) { Text("p. \(number)") }
        }
    }

    private func leftOut(aspect: Double, caption text: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: height * aspect, height: height)
                .overlay { Text("Left out").font(.caption.weight(.semibold)) }
            caption(flag: false) { Text(text).foregroundStyle(.secondary) }
        }
    }

    private func caption(flag: Bool, _ text: () -> some View) -> some View {
        HStack(spacing: 4) {
            if flag {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            text()
        }
        .font(.caption.monospacedDigit())
    }

    /// Width over height of a side's crop (or the whole scan), as the page measures.
    private func aspect(of side: BookPage.Side?) -> Double {
        let size = model.displaySize(of: page) ?? CGSize(width: 612, height: 792)
        let crop = side == .left ? page.leftCrop : side == .right ? page.rightCrop : CropRect.full
        return max(0.2, min(3, crop.width * size.width / max(1, crop.height * size.height)))
    }
}

/// How the exported PDF is made, the book's page size, and the Export PDF… button,
/// which turns into the export's progress while it runs.
private struct ExportOptions: View {
    @EnvironmentObject var model: AppModel
    // State(initialValue:) rather than @State, for Command Line Tools (see PageSizeRow).
    private let packsState = State(initialValue: false)

    /// The ticked packs the current reader uses.
    private var applicable: [String] {
        model.ocrPacks.filter { code in
            model.ocrReader == .tesseract || TesseractLanguage.fillsIn(code)
        }
    }

    private func name(_ code: String) -> String {
        TesseractLanguage.all.first { $0.code == code }?.name ?? code
    }

    /// The reader, its languages, and what is wrong with them.
    @ViewBuilder private var readerRows: some View {
        Picker("Reader", selection: $model.ocrReader) {
            Text("Apple").tag(OCRReader.apple)
            Text("Tesseract").tag(OCRReader.tesseract)
        }
        .help("Apple reads accents and mixed languages best. Tesseract is for books mainly in a script Apple can't read.")
        LabeledContent("Languages") {
            HStack {
                Text(applicable.isEmpty ? "None" : applicable.map(name).joined(separator: ", "))
                    .multilineTextAlignment(.trailing)
                Button("Choose…") { packsState.wrappedValue = true }
            }
        }
        let missing = applicable.filter { !model.installedPacks.contains($0) && model.packDownloads[$0] != .downloading }
        if model.ocrReader == .tesseract && applicable.isEmpty {
            Text("No language chosen: Tesseract will read English.").font(.caption).foregroundStyle(.secondary)
        }
        if !missing.isEmpty {
            Text("Not downloaded: \(missing.map(name).joined(separator: ", ")).")
                .font(.caption).foregroundStyle(.orange)
        }
        if TesseractService.executableURL() == nil && (model.ocrReader == .tesseract || !applicable.isEmpty) {
            Text("Tesseract is missing from this copy of the app.").font(.caption).foregroundStyle(.red)
        }
    }

    var body: some View {
        Form {
            Section("Output") {
                Picker("Color", selection: $model.enhanceMode) {
                    ForEach(EnhanceMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                Toggle("Searchable text (OCR)", isOn: $model.ocrEnabled)
                if model.ocrEnabled { readerRows }
                Picker("Reading order", selection: $model.direction) {
                    ForEach(ReadingDirection.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                Toggle("Match scan resolution", isOn: $model.matchScanResolution)
                    .help("Each page keeps its scan's own resolution (kept within 150–600 DPI), so nothing is blurred or blown up.")
                VStack(alignment: .leading) {
                    LabeledContent(model.matchScanResolution ? "Pages without a scan" : "Export resolution") {
                        Text("\(Int(model.exportDPI)) DPI").monospacedDigit()
                    }
                    Slider(value: $model.exportDPI, in: 150...600, step: 50)
                        .labelsHidden()
                }
            }

            if let size = model.pageSize {
                Section("Page size") {
                    PageSizeRow(size: size)
                }
            }

            if model.sourceHasText {
                Section {
                    Label(model.ocrEnabled
                          ? "This PDF already has text. Export makes each page a new image and reads its text again, so the old text is replaced."
                          : "This PDF already has text. Export makes each page a new image, so with Searchable text off, that text is dropped.",
                          systemImage: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Source pages", value: "\(model.pages.count)")
                LabeledContent("Output pages", value: "\(model.outputPageCount)")
            }

            Section {
                if model.isExporting {
                    HStack {
                        // A moving bar until the first page is done: Vision can be slow to start.
                        if model.exportProgress > 0 {
                            ProgressView(value: model.exportProgress)
                            Text("\(Int((model.exportProgress * 100).rounded()))%").monospacedDigit()
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Button("Cancel") { model.cancelExport() }
                    }
                } else {
                    Button {
                        model.exportPanel()
                    } label: {
                        Text("Export PDF…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canExport)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPacks() }
        .sheet(isPresented: packsState.projectedValue) { LanguagePacksView() }
    }
}

/// Whole page: the book's page size. Width and Height to set it by hand with Apply
/// (both empty goes back to the measured size); the measured size (or the largest
/// that fits every page) with Use on All Pages; and what is wrong with either. In the
/// Export view and on the sidebar's All Pages side.
struct PageSizeRow: View {
    @EnvironmentObject var model: AppModel
    let size: AppModel.PageSizeSummary
    // State(initialValue:) rather than @State, for Command Line Tools (see CropBoxView).
    private let widthState = State(initialValue: "")
    private let heightState = State(initialValue: "")
    private let problemState = State<String?>(initialValue: nil)
    private var problem: String? {
        get { problemState.wrappedValue }
        nonmutating set { problemState.wrappedValue = newValue }
    }

    var body: some View {
        Group {
            field("Width", widthState.projectedValue, measured: size.width)
            field("Height", heightState.projectedValue, measured: size.height)
            if let suggested = size.suggested {
                LabeledContent(size.width != nil && size.height != nil ? "Measured" : "Fits every page") {
                    Text("\(Self.describe(suggested)) in").monospacedDigit()
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let disagreement = size.disagreement {
                Text("Stacks differ: \(disagreement)").font(.caption).foregroundStyle(.orange)
            }
            if size.override != nil, size.tooBig > 0 {
                Text("This page size is too large for \(size.tooBig) page\(size.tooBig == 1 ? "" : "s")."
                     + (size.fitsAll.map { " The largest size that fits every page is \(Self.describe($0)) in." } ?? ""))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Apply", action: apply)
                Spacer()
                Button("Use on All Pages") {
                    problem = nil
                    if let suggested = size.suggested { model.setPageSize(suggested) }
                }
                .disabled(size.suggested == nil || size.suggested == size.override)
            }
            .disabled(model.isBusy)
        }
        .help(size.details.joined(separator: "\n"))
        .onAppear(perform: fill)
        .onChange(of: size.override) { _, _ in fill() }
    }

    /// An empty field shows the measured length, which applies while no size is typed.
    private func field(_ name: String, _ text: Binding<String>, measured: Double?) -> some View {
        LabeledContent(name) {
            HStack(spacing: 4) {
                TextField(name, text: text, prompt: Text(measured.map { String(format: "%.2f", $0) } ?? "—"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .onSubmit(apply)
                    .disabled(model.isBusy)
                Text("in")
            }
        }
    }

    /// The fields show the size set by hand, or are empty.
    private func fill() {
        widthState.wrappedValue = size.override.map { String(format: "%.2f", $0.width) } ?? ""
        heightState.wrappedValue = size.override.map { String(format: "%.2f", $0.height) } ?? ""
    }

    /// None for a typed size: a note says only what is wrong (John, 2026-10-27).
    private var note: String? {
        if size.override != nil { return nil }
        if size.width == nil && size.height == nil { return "Not measured: too few pages show their sheet's edges." }
        return "Measured on \(size.measured) of \(size.total) pages."
    }

    private func apply() {
        let number = PageSize.inches
        let w = widthState.wrappedValue.trimmingCharacters(in: .whitespaces)
        let h = heightState.wrappedValue.trimmingCharacters(in: .whitespaces)
        if w.isEmpty && h.isEmpty { problem = nil; model.setPageSize(nil); return }
        let range = "\(Int(PageSize.sensible.lowerBound)) and \(Int(PageSize.sensible.upperBound))"
        guard let width = number(w), let height = number(h) else {
            problem = "Type a width and a height in inches, like 6 and 9."
            return
        }
        let typed = PageSize(width: width, height: height)
        guard typed.isSensible else {
            problem = "Each must be between \(range) inches."
            return
        }
        problem = nil
        model.setPageSize(typed)
    }

    private static func describe(_ p: PageSize) -> String {
        String(format: "%.2f × %.2f", p.width, p.height)
    }
}
