import SwiftUI

/// Right panel: a switch between this page (in Stack view, this stack) and all
/// pages, each a column of grouped rows. The export's settings are in the Export view.
struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    enum Side: Hashable { case one, all }
    // State(initialValue:) rather than @State, for Command Line Tools (see CropBoxView).
    // Kept across pages: the sidebar stays on the side last chosen.
    private let sideState = State(initialValue: Side.one)

    var body: some View {
        // Trim All Pages is chosen and finished on the All Pages side.
        let choosing = model.trimmingPage != nil && model.trimmingAllPages
        let side = choosing ? .all : sideState.wrappedValue
        VStack(spacing: 0) {
            Picker("Inspector", selection: Binding(get: { side }, set: { sideState.wrappedValue = $0 })) {
                Text(model.showsStack ? "This Stack" : "This Page").tag(Side.one)
                Text("All Pages").tag(Side.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(choosing)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)

            Form {
                switch side {
                case .one:
                    if model.showsStack { StackSections() } else { PageSections() }
                case .all: BookSections()
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 260)
    }
}

/// The selected page: its type, trim, straightening and crops.
private struct PageSections: View {
    @EnvironmentObject var model: AppModel
    // To tell where a drag ended. State(initialValue:) as in CropBoxView; a class, as setting it redraws nothing.
    private let skewProbes = State(initialValue: StraightenRowProbes())

    var body: some View {
        if let page = model.selectedPage, let idx = model.selectedIndex {
            Section {
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
                        Text("Left").tag(BookPage.Side?.some(.right))     // leaves the right out
                        Text("Right").tag(BookPage.Side?.some(.left))
                    }
                    .pickerStyle(.segmented)
                    .help("Choose which page or pages of this spread go in the export: both, the left only or the right only. The page left out keeps its crop.")
                }
                if page.classification == .skip {
                    Text("Left out of the export.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                PageHeader(title: "Page \(page.sourceIndex + 1)", flagged: model.flaggedSides[page.id] != nil)
            }

            if page.classification != .skip {
                TrimSection(allPages: false)

                Section("Straighten") {
                    if page.classification == .spread {
                        skewControl("Left", leftSkewBinding(idx), row: .left)
                        skewControl("Right", rightSkewBinding(idx), row: .right)
                    } else {
                        skewControl("Angle", leftSkewBinding(idx), row: .angle)
                    }
                    Button {
                        model.autoStraightenSelected()
                    } label: {
                        Label("Auto-straighten", systemImage: "level").frame(maxWidth: .infinity)
                    }
                }

                Section("Crop") {
                    cropRows(page)
                }
            }
        } else {
            Text("Select a page in the sidebar.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func cropRows(_ page: BookPage) -> some View {
        let readout = model.displaySize(of: page).map {
            CropSizeReadout(leftCrop: page.leftCrop, rightCrop: page.isSpread ? page.rightCrop : nil, in: $0, unit: RulerUnit())
        }
        HStack {
            Button {
                model.reanalyzeSelected()
            } label: {
                Label("Detect", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .help("Auto-detect this page: its type, split and crops, found again.")
            if page.isSpread {
                MatchMenu(differs: readout?.same == false) { model.matchCropSizes(of: page.id, rightMatchesLeft: $0) }
            }
        }
        if page.isSpread {
            if let readout { SpreadSizeControls(readout: readout) }
            Button {
                model.applyLayoutToAllSpreads()
            } label: {
                Text("Apply layout to all spreads").frame(maxWidth: .infinity)
            }
            .help("Copies the split line and both crops to every spread. The left and right crops stay separate.")
        } else {
            if let readout { LabeledContent("Size") { Text(readout.lengths.first ?? "").monospacedDigit() } }
            Menu {
                Button("To All Single Pages") { model.applySingleCrop(alternate: false) }
                Button("To Alternate Pages") { model.applySingleCrop(alternate: true) }
                    .help("Copies this crop to every other single page, so left-hand and right-hand pages can have different crops.")
            } label: {
                Text("Apply crop").frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .help("Copy this crop to all single pages, or to every other one, so left-hand and right-hand pages can have different crops.")
        }
    }

    /// A row: the side's name, its slider, its angle and a reset to 0°.
    @ViewBuilder
    private func skewControl(_ title: String, _ value: Binding<Double>, row: StraightenFocus.Row) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 42, alignment: .leading)
            Slider(value: value, in: -8...8, step: 0.1) { editing in
                if editing {
                    model.straightenFocus.beginDrag(row)
                } else {
                    model.straightenFocus.endDrag(row, pointerInside: skewProbes.wrappedValue.pointerIsOn(row))
                }
                if editing { model.beginEdit() } else { model.endEdit("Straighten") }
            }
            .labelsHidden()     // else the Form gives it only the value column
            Text(String(format: "%+.1f°", value.wrappedValue))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Button { model.perform("Straighten") { value.wrappedValue = 0 } } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to 0°")
        }
        // On hover as well as in a drag, so the grid stays to judge the page between nudges.
        .onHover { model.straightenFocus.hover(row, inside: $0) }
        .onDisappear { model.straightenFocus.remove(row) }
        .background(StraightenRowProbe(row: row, probes: skewProbes.wrappedValue))
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

/// The sidebar's title line: what it acts on, and "Needs a look" when it does.
private struct PageHeader: View {
    let title: String
    var flagged = false

    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(.primary)
            Spacer()
            if flagged {
                Label("Needs a look", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
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
                    let readout = CropSizeReadout(leftCrop: layout.leftCrop, rightCrop: layout.rightCrop, in: size, unit: RulerUnit())
                    SpreadSizeControls(readout: readout)
                    MatchMenu(differs: readout.same == false) { rightMatchesLeft in
                            var l = model.spreadLayout(for: stack)
                            l.matchSizesMovingSplit(rightMatchesLeft: rightMatchesLeft)
                            model.spreadLayout = l
                            let (moved, other) = rightMatchesLeft ? (l.rightCrop, l.leftCrop) : (l.leftCrop, l.rightCrop)
                            if other.width - moved.width > 1e-6 {
                                model.statusText = SpreadLayout.matchShortfall(rightMatchesLeft: rightMatchesLeft)
                            }
                    }
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

/// Trim: this page's (This Page) or every page's (All Pages). While a trim is drawn,
/// Done and Cancel.
private struct TrimSection: View {
    @EnvironmentObject var model: AppModel
    let allPages: Bool

    var body: some View {
        Section("Trim") {
            if model.trimmingPage != nil {
                if allPages && model.trimmingAllPages { pagesToTrim }
                HStack {
                    Button { model.finishTrim() } label: { Text("Done").frame(maxWidth: .infinity) }
                        .keyboardShortcut(.defaultAction)
                    Button { model.cancelTrim() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                        .keyboardShortcut(.cancelAction)
                }
            } else if allPages {
                HStack {
                    Button { model.beginTrim(allPages: true) } label: {
                        Text("Trim All Pages").frame(maxWidth: .infinity)
                    }
                    .disabled(model.selectedPage == nil || model.isBusy)
                    Button { model.removeAllTrims() } label: {
                        Text("Remove All Trims").frame(maxWidth: .infinity)
                    }
                    .disabled(!model.pages.contains { $0.trim != nil } || model.isBusy)
                }
            } else {
                HStack {
                    Button { model.beginTrim() } label: { Text("Trim").frame(maxWidth: .infinity) }
                        .disabled(model.isBusy)
                        .help("Draw the part of the scan the page is on")
                    Button { model.removeTrim() } label: { Text("Remove Trim").frame(maxWidth: .infinity) }
                        .disabled(model.selectedPage?.trim == nil || model.isBusy)
                }
            }
        }
    }

    /// Trim All Pages: which pages it trims (ticked in the side panel), chosen there.
    @ViewBuilder
    private var pagesToTrim: some View {
        let count = model.pages.count - model.trimExcluded.count
        LabeledContent("Pages to trim") { Text("\(count) of \(model.pages.count)").monospacedDigit() }
        Text("Choose pages in the list on the left.").font(.caption).foregroundStyle(.secondary)
        HStack {
            Button { model.leaveOutOfTrim(true) } label: { Text("Leave Out").frame(maxWidth: .infinity) }
            Button { model.leaveOutOfTrim(false) } label: { Text("Include").frame(maxWidth: .infinity) }
        }
        .disabled(model.trimSelection.isEmpty)
        HStack {
            Button { model.trimExcluded = [] } label: { Text("All").frame(maxWidth: .infinity) }
                .disabled(model.trimExcluded.isEmpty)
            Button { model.trimExcluded = Set(model.pages.map(\.id)) } label: { Text("None").frame(maxWidth: .infinity) }
                .disabled(count == 0)
        }
    }
}

/// All Pages: work on every page at once, the settings that steer detection, and
/// the book's page size.
private struct BookSections: View {
    @EnvironmentObject var model: AppModel

    /// Why the buttons below are greyed out, while they are.
    private var busyNote: String? {
        if model.isAnalyzing { return "Analyzing pages. These come back when it's done." }
        if model.isStraightening { return "Straightening pages. These come back when it's done." }
        if model.isExporting { return "Exporting. These come back when it's done." }
        return nil
    }

    var body: some View {
        Section {
            HStack {
                Button {
                    model.autoDetectAllPages()
                } label: {
                    Label("Detect all", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .help("Auto-detect all pages: finds every page's split, type and crops again, replacing hand edits (⌘Z undoes it). Straightens too when Auto-straighten on import is on.")
                Button {
                    Task { await model.autoStraightenAllPages() }
                } label: {
                    Label("Straighten all", systemImage: "level").frame(maxWidth: .infinity)
                }
                .help("Auto-straighten all pages: finds every page's straightening angle again and keeps its crops (⌘Z undoes it). Skipped pages are left alone.")
            }
            .disabled(model.isBusy)
            CropTargetPicker()
            Toggle("Auto-straighten on import", isOn: $model.autoDeskewEnabled)
        } header: {
            PageHeader(title: model.sourceURL?.deletingPathExtension().lastPathComponent ?? "Whole book")
        } footer: {
            if let busyNote {
                Text(busyNote).font(.caption).foregroundStyle(.secondary)
            }
        }

        TrimSection(allPages: true)

        if let size = model.pageSize {
            Section("Page size") {
                PageSizeRow(size: size)
            }
        }
    }
}

/// What auto-detect crops to, for the whole book.
private struct CropTargetPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Crop to", selection: Binding(get: { model.cropTarget },
                                             set: { model.setCropTarget($0) })) {
            Text(CropTarget.page.label).tag(CropTarget.page)
            Text(CropTarget.text.label).tag(CropTarget.text)
        }
        .pickerStyle(.segmented)
        .disabled(model.isBusy)
        .help("For the whole book. Text block crops close around the printed text. Whole page keeps the sheet with its margins, leaving out the scanner background. Changing this re-detects every page.")
    }
}
