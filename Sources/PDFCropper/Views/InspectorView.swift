import SwiftUI

/// Right panel, in three tabs: this page (or, in Stack view, the stack), the whole
/// book, and the export.
struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    enum Tab: Hashable { case page, book, export }
    // State(initialValue:) rather than @State, for Command Line Tools (see CropBoxView).
    private let tabState = State(initialValue: Tab.page)

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: tabState.projectedValue) {
                Text(model.showsStack ? "Stack" : "Page").tag(Tab.page)
                Text("Book").tag(Tab.book)
                Text("Export").tag(Tab.export)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)

            Form {
                switch tabState.wrappedValue {
                case .page:
                    if model.showsStack { StackSections() } else { PageSections() }
                case .book: BookSections()
                case .export: ExportSections()
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 260)
    }
}

/// The selected page's type, straightening and detection.
private struct PageSections: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let page = model.selectedPage, let idx = model.selectedIndex {
            Section("Page \(page.sourceIndex + 1)") {
                Picker("Type", selection: Binding(
                    get: { model.pages[idx].classification },
                    set: { model.setClassification($0, for: page.id) })
                ) {
                    ForEach(PageClassification.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                if page.classification == .spread {
                    Picker("Export", selection: Binding(
                        get: { model.pages[idx].omittedSide },
                        set: { model.setOmittedSide($0, for: page.id) })
                    ) {
                        Text("Both").tag(BookPage.Side?.none)
                        Text("Left only").tag(BookPage.Side?.some(.right))     // leaves the right out
                        Text("Right only").tag(BookPage.Side?.some(.left))
                    }
                    .pickerStyle(.segmented)
                    .help("Choose which page or pages of this spread go in the export. The page left out keeps its crop.")
                }
                if page.classification == .skip {
                    Text("Left out of the export.")
                        .foregroundStyle(.secondary)
                }
            }

            if page.classification != .skip {
                Section("Trim") {
                    if model.trimmingPage == page.id {
                        HStack {
                            Button("Done") { model.finishTrim() }
                                .keyboardShortcut(.defaultAction)
                            Button("Cancel") { model.cancelTrim() }
                                .keyboardShortcut(.cancelAction)
                        }
                    } else {
                        Button {
                            model.beginTrim()
                        } label: {
                            Label("Trim", systemImage: "crop")
                        }
                        .help("Draw the part of the page to keep")
                        .disabled(model.isBusy)
                        Button("Remove Trim") { model.removeTrim() }
                            .disabled(page.trim == nil || model.isBusy)
                        Button("Trim All Pages Like This") { model.trimAllPagesLikeThis() }
                            .disabled(page.trim == nil || model.isBusy)
                    }
                }

                Section("Straighten") {
                    if page.classification == .spread {
                        skewControl("Left", leftSkewBinding(idx))
                        skewControl("Right", rightSkewBinding(idx))
                    } else {
                        skewControl("Angle", leftSkewBinding(idx))
                    }
                    Button {
                        model.autoStraightenSelected()
                    } label: {
                        Label("Auto-straighten", systemImage: "level")
                    }
                }
            }

            Section("Crops") {
                CropTargetPicker()
                Button {
                    model.reanalyzeSelected()
                } label: {
                    Label("Auto-detect this page", systemImage: "wand.and.stars")
                }
                switch page.classification {
                case .spread:
                    if let size = model.displaySize(of: page) {
                        SpreadSizeControls(
                            readout: CropSizeReadout(leftCrop: page.leftCrop, rightCrop: page.rightCrop, in: size, unit: RulerUnit()),
                            match: { model.matchCropSizes(of: page.id, rightMatchesLeft: $0) })
                    }
                    Button {
                        model.applyLayoutToAllSpreads()
                    } label: {
                        Label("Apply layout to all spreads", systemImage: "rectangle.on.rectangle")
                    }
                    .help("Copies the split line and both crops to every spread. The left and right crops stay separate.")
                case .single:
                    Menu {
                        Button("To All Single Pages") { model.applySingleCrop(alternate: false) }
                        Button("To Alternate Pages") { model.applySingleCrop(alternate: true) }
                            .help("Copies this crop to every other single page, so left-hand and right-hand pages can have different crops.")
                    } label: {
                        Label("Apply crop", systemImage: "rectangle.on.rectangle")
                    }
                    .help("Copy this crop to all single pages, or to every other one, so left-hand and right-hand pages can have different crops.")
                case .skip:
                    EmptyView()
                }
            }
        } else {
            Text("Select a page in the sidebar.")
                .foregroundStyle(.secondary)
        }
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
                .labelsHidden()     // else the Form gives it only the value column
                Button { model.perform("Straighten") { value.wrappedValue = 0 } } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
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

/// Stack view: the pages in the stack on show whose crop differs in size, or in
/// the whole-spread stack, whose split is far from the rest.
private struct StackSections: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let stacks = model.stacks
        if let stack = stacks.first(where: { $0.id == model.stackKind }) ?? stacks.first {
            // The orange draft's two boxes, once analysis has settled them.
            if stack.id == .spreads, !model.isAnalyzing, let document = model.document,
               let size = StackRenderer.pointSize(of: stack, in: document) {
                Section("Crops") {
                    let layout = model.spreadLayout(for: stack)
                    SpreadSizeControls(
                        readout: CropSizeReadout(leftCrop: layout.leftCrop, rightCrop: layout.rightCrop, in: size, unit: RulerUnit()),
                        match: { rightMatchesLeft in
                            var l = model.spreadLayout(for: stack)
                            l.matchSizesMovingSplit(rightMatchesLeft: rightMatchesLeft)
                            model.spreadLayout = l
                            let (moved, other) = rightMatchesLeft ? (l.rightCrop, l.leftCrop) : (l.leftCrop, l.rightCrop)
                            if other.width - moved.width > 1e-6 {
                                model.statusText = SpreadLayout.matchShortfall(rightMatchesLeft: rightMatchesLeft)
                            }
                        })
                }
            }
            Section {
                // Until analysis is done the crops are placeholders, so judging them misleads.
                if model.isAnalyzing {
                    Text("Waiting for page analysis to finish…")
                        .foregroundStyle(.secondary)
                } else if stack.outliers.isEmpty {
                    Text(stack.id == .spreads ? "No split is far from the rest." : "No page differs in size.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stack.outliers) { member in
                        Button {
                            model.selectedPageID = member.id
                            model.showsStack = false
                        } label: {
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text("p. \(member.page.sourceIndex + 1) · \(member.side == .whole ? "split at \(Int((member.page.splitX * 100).rounded()))%" : member.side.rawValue)")
                                Spacer()
                                Text("Show").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open this page in Page view")
                    }
                }
            } header: {
                Text("\(stack.id.label) (\(stack.members.count))")
            } footer: {
                if !model.isAnalyzing, !stack.outliers.isEmpty, stack.id == .spreads {
                    Text("\(stack.outliers.count) \(stack.outliers.count == 1 ? "spread's split is" : "spreads' splits are") over \(Int(PageStack.splitTolerance * 100))% of the scan's width from the usual split. Apply Layout above the stack sets them to the orange split and the blue and green boxes.")
                        .foregroundStyle(.secondary)
                } else if !model.isAnalyzing, !stack.outliers.isEmpty {
                    Text("\(stack.outliers.count) \(stack.outliers.count == 1 ? "page differs" : "pages differ") in size from the rest of this stack. Apply Crop above the stack sets them to the orange box.")
                        .foregroundStyle(.secondary)
                }
            }
            pickSection(stack)
        } else {
            Text("No pages to stack.")
                .foregroundStyle(.secondary)
        }
    }

    /// A tick for each page of the stack. An unticked page is out of this stack
    /// only: not blended, judged or changed by Apply, and still exported.
    private func pickSection(_ stack: PageStack) -> some View {
        let pages = stack.allMembers
        return Section {
            HStack {
                Button("All") { model.setAllStackPages(included: true, in: stack) }
                    .disabled(stack.excludedMembers.isEmpty)
                Button("None") { model.setAllStackPages(included: false, in: stack) }
                    .disabled(stack.members.isEmpty)
                Spacer()
            }
            // A long book has hundreds of pages: scroll the list rather than grow the sidebar.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(pages) { member in
                        Toggle("p. \(member.page.sourceIndex + 1)", isOn: Binding(
                            get: { !(model.stackExclusions[stack.id]?.contains(member.id) ?? false) },
                            set: { model.setStackPage(member.id, included: $0, in: stack.id) }))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(180, Double(pages.count) * 24 + 4))
        } header: {
            Text("Pages in this stack (\(stack.members.count) of \(pages.count))")
        } footer: {
            Text("A page left out is not drawn here, counted or changed by Apply. It is still in Page view and the export.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Work on every page at once, and the settings that steer detection.
private struct BookSections: View {
    @EnvironmentObject var model: AppModel

    /// Why the buttons below are greyed out, while they are.
    private var busyNote: String? {
        if model.isAnalyzing { return "Analyzing pages. These and Crop to come back when it's done." }
        if model.isStraightening { return "Straightening pages. These and Crop to come back when it's done." }
        if model.isExporting { return "Exporting. These and Crop to come back when it's done." }
        return nil
    }

    var body: some View {
        Section {
            Button {
                model.autoDetectAllPages()
            } label: {
                Label("Auto-detect all pages", systemImage: "wand.and.stars")
            }
            .help("Finds every page's split, type and crops again, replacing hand edits (⌘Z undoes it). Straightens too when Auto-straighten on import is on.")
            Button {
                Task { await model.autoStraightenAllPages() }
            } label: {
                Label("Auto-straighten all pages", systemImage: "level")
            }
            .help("Finds every page's straightening angle again and keeps its crops (⌘Z undoes it). Skipped pages are left alone.")
        } header: {
            Text("Whole book")
        } footer: {
            if let busyNote {
                Text(busyNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(model.isBusy)

        Section("Detection") {
            CropTargetPicker()
            if let size = model.pageSize {
                PageSizeRow(size: size)
            }
            Toggle("Auto-straighten on import", isOn: $model.autoDeskewEnabled)
        }
    }
}

/// How the exported PDF is made, and the Export button.
/// What auto-detect crops to, for the whole book. In the Page tab beside
/// Auto-detect as well as in the Book tab.
private struct CropTargetPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Crop to", selection: Binding(get: { model.cropTarget },
                                             set: { model.setCropTarget($0) })) {
            ForEach(CropTarget.allCases) { t in
                Text(t.label).tag(t)
            }
        }
        .disabled(model.isBusy)
        .help("For the whole book. Text block crops close around the printed text. Whole page keeps the sheet with its margins, leaving out the scanner background. Changing this re-detects every page.")
    }
}

private struct ExportSections: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.sourceHasText {
            Section {
                Label(model.ocrEnabled
                      ? "This PDF already has text. Export makes each page a new image and reads its text again, so the old text is replaced."
                      : "This PDF already has text. Export makes each page a new image, so with Searchable text off, that text is dropped.",
                      systemImage: "text.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
        }

        Section("Output") {
            Picker("Color", selection: $model.enhanceMode) {
                ForEach(EnhanceMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
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
                    .labelsHidden()
            }
        }

        Section {
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
            Text(shown.0 == nil && shown.1 == nil ? "Page size" : "Page size: \(Self.describe(shown)) in")
            Text(note).font(.caption).foregroundStyle(.secondary)
            if let disagreement = size.disagreement {
                Text("Stacks differ: \(disagreement)").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("Size (in)")
                TextField("Page size", text: entryState.projectedValue, prompt: Text("e.g. 6 × 9"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                    .disabled(model.isBusy)
                    .help("Type the book's page size, e.g. 6 × 9, to place every page analysis set at that size. Leave it empty to use the measured size.")
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if size.override != nil, size.tooBig > 0 {
                Text("This page size is too large for \(size.tooBig) page\(size.tooBig == 1 ? "" : "s")."
                     + (size.fitsAll.map { " The largest size that fits every page is \(Self.describe($0)) in." } ?? ""))
                    .font(.caption).foregroundStyle(.orange)
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
        if size.override != nil { return "Set by you. Clear the field to use the measured size." }
        if size.width == nil && size.height == nil { return "Not measured: too few pages show their sheet's edges." }
        return "Measured on \(size.measured) of \(size.total) pages. Type a size to override it."
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
