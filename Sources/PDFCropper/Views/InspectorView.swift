import SwiftUI

/// Right panel: per-page controls + document-wide export settings.
struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            if let page = model.selectedPage, let idx = model.selectedIndex {
                Section("Page \(page.sourceIndex + 1)") {
                    Picker("Type", selection: Binding(
                        get: { model.pages[idx].classification },
                        set: { model.setClassification($0, for: page.id) })
                    ) {
                        ForEach(PageClassification.allCases) { c in
                            Label(c.label, systemImage: c.symbol).tag(c)
                        }
                    }

                    Button {
                        model.reanalyzeSelected()
                    } label: {
                        Label("Auto-detect this page", systemImage: "wand.and.stars")
                    }

                    switch page.classification {
                    case .spread:
                        Button {
                            model.applyLayoutToAllSpreads()
                        } label: {
                            Label("Apply layout to all spreads", systemImage: "rectangle.on.rectangle")
                        }
                        .help("Copies the split line and both crops to every spread. The left and right crops stay separate.")
                    case .single:
                        Button {
                            model.applySingleCrop(alternate: false)
                        } label: {
                            Label("Apply crop to all single pages", systemImage: "rectangle.on.rectangle")
                        }
                        Button {
                            model.applySingleCrop(alternate: true)
                        } label: {
                            Label("Apply crop to alternate pages", systemImage: "rectangle.split.2x1")
                        }
                        .help("Copies this crop to every other single page, so left-hand and right-hand pages can have different crops.")
                    case .skip:
                        EmptyView()
                    }

                    if page.classification != .skip {
                        Button {
                            model.autoStraightenSelected()
                        } label: {
                            Label("Auto-straighten", systemImage: "wand.and.stars")
                        }
                        if page.classification == .spread {
                            skewControl("Straighten left", leftSkewBinding(idx))
                            skewControl("Straighten right", rightSkewBinding(idx))
                        } else {
                            skewControl("Straighten", leftSkewBinding(idx))
                        }
                    }
                }
            }

            if model.document != nil {
                Section("Whole book") {
                    Button {
                        model.autoDetectAllPages()
                    } label: {
                        Label("Auto-detect all pages", systemImage: "wand.and.stars")
                    }
                    .help("Finds every page's split, type and crops again, replacing hand edits (⌘Z undoes it). Straightens too when Auto-straighten on import is on.")
                    Button {
                        Task { await model.autoStraightenAllPages() }
                    } label: {
                        Label("Auto-straighten all pages", systemImage: "wand.and.stars")
                    }
                    .help("Finds every page's straightening angle again and keeps its crops (⌘Z undoes it). Skipped pages are left alone.")
                }
                .disabled(model.isBusy)
            }

            Section("Output") {
                Picker("Color", selection: $model.enhanceMode) {
                    ForEach(EnhanceMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                Picker("Crop to", selection: Binding(get: { model.cropTarget },
                                                     set: { model.setCropTarget($0) })) {
                    ForEach(CropTarget.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .disabled(model.isBusy)
                .help("Text block crops close around the printed text. Whole page keeps the sheet with its margins, leaving out the scanner background. Changing this re-detects every page.")
                if let size = model.pageSize {
                    PageSizeRow(size: size)
                }
                Toggle("Auto-straighten on import", isOn: $model.autoDeskewEnabled)
                Toggle("Searchable text (OCR)", isOn: $model.ocrEnabled)

                Picker("Reading order", selection: $model.direction) {
                    ForEach(ReadingDirection.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }

                Toggle("Match scan resolution", isOn: $model.matchScanResolution)
                    .help("Each page keeps its scan's own resolution (kept within 150–600 DPI), so nothing is blurred or blown up.")
                VStack(alignment: .leading) {
                    Text(model.matchScanResolution
                         ? "Pages without a scan: \(Int(model.exportDPI)) DPI"
                         : "Export resolution: \(Int(model.exportDPI)) DPI")
                    Slider(value: $model.exportDPI, in: 150...600, step: 50)
                }

                LabeledContent("Source pages", value: "\(model.pages.count)")
                LabeledContent("Output pages", value: "\(model.outputPageCount)")
            }

            Section {
                Button {
                    model.exportPanel()
                } label: {
                    Label("Export PDF…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canExport)

                if model.isExporting {
                    HStack {
                        ProgressView(value: model.exportProgress)
                        Button("Cancel") { model.cancelExport() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 240)
    }

    @ViewBuilder
    private func skewControl(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%+.1f°", value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Slider(value: value, in: -8...8, step: 0.1) { editing in
                    if editing { model.beginEdit() } else { model.endEdit("Straighten") }
                }
                Button { model.perform("Straighten") { value.wrappedValue = 0 } } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset to 0°")
            }
        }
    }

    private func leftSkewBinding(_ idx: Int) -> Binding<Double> {
        Binding(get: { model.pages[idx].leftSkew },
                set: { model.pages[idx].leftSkew = $0 })
    }
    private func rightSkewBinding(_ idx: Int) -> Binding<Double> {
        Binding(get: { model.pages[idx].rightSkew },
                set: { model.pages[idx].rightSkew = $0 })
    }
}

/// Whole page: the book's page size, as measured or as typed in ("6 × 9"; empty
/// goes back to the measured size).
private struct PageSizeRow: View {
    @EnvironmentObject var model: AppModel
    let size: AppModel.PageSizeSummary
    // State(initialValue:) rather than @State, for Command Line Tools (see CropBoxView).
    private let entryState = State(initialValue: "")
    private var entry: String {
        get { entryState.wrappedValue }
        nonmutating set { entryState.wrappedValue = newValue }
    }
    private let problemState = State<String?>(initialValue: nil)
    private var problem: String? {
        get { problemState.wrappedValue }
        nonmutating set { problemState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Page size: \(Self.describe(shown)) in")
            Text(note).font(.caption).foregroundStyle(.secondary)
            if let disagreement = size.disagreement {
                Text("Stacks differ: \(disagreement)").font(.caption).foregroundStyle(.orange)
            }
            TextField("Width × height, in inches", text: entryState.projectedValue)
                .onSubmit(commit)
                .disabled(model.isBusy)
                .help("Type the book's page size, e.g. 6 × 9, to place every page analysis set at that size. Leave it empty to use the measured size.")
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .help(size.details.joined(separator: "\n"))
        .onAppear { entry = size.override.map(Self.describe) ?? "" }
        .onChange(of: size.override) { _, new in entry = new.map(Self.describe) ?? "" }
    }

    private var shown: (Double?, Double?) {
        if let o = size.override { return (o.width, o.height) }
        return (size.width, size.height)
    }

    private var note: String {
        if size.override != nil { return "(set by you)" }
        if size.width == nil && size.height == nil { return "(not measured: too few pages show their sheet's edges)" }
        return "(measured on \(size.measured) of \(size.total) pages)"
    }

    private func commit() {
        let text = entry.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { problem = nil; model.setPageSize(nil); return }
        guard let typed = PageSize(parsing: text) else {
            problem = "“\(text)” isn't a page size. Type width × height in inches, each between "
                + "\(Int(PageSize.sensible.lowerBound)) and \(Int(PageSize.sensible.upperBound)), like 6 × 9."
            return
        }
        problem = nil
        model.setPageSize(typed)
    }

    private static func describe(_ v: (Double?, Double?)) -> String {
        func f(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "—" }
        return "\(f(v.0)) × \(f(v.1))"
    }

    private static func describe(_ p: PageSize) -> String { describe((p.width, p.height)) }
}
