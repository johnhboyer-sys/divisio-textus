import SwiftUI

/// Right panel, in two tabs: this page (or, in Stack view, the stack) and the whole
/// book. The export's settings are in the Export view.
struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    enum Tab: Hashable { case page, book }
    // State(initialValue:) rather than @State, for Command Line Tools (see CropBoxView).
    private let tabState = State(initialValue: Tab.page)

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: tabState.projectedValue) {
                Text(model.showsStack ? "Stack" : "Page").tag(Tab.page)
                Text("Book").tag(Tab.book)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)

            Form {
                switch tabState.wrappedValue {
                case .page:
                    if model.showsStack { StackSections() } else { PageSections() }
                case .book: BookSections()
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
    // To tell where a drag ended. State(initialValue:) as in CropBoxView; a class, as setting it redraws nothing.
    private let skewProbes = State(initialValue: StraightenRowProbes())

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
    private func skewControl(_ title: String, _ value: Binding<Double>, row: StraightenFocus.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%+.1f°", value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Slider(value: value, in: -8...8, step: 0.1) { editing in
                    if editing {
                        model.straightenFocus.beginDrag(row)
                    } else {
                        model.straightenFocus.endDrag(row, pointerInside: skewProbes.wrappedValue.pointerIsOn(row))
                    }
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
/// Trim: this page's (Page tab) or every page's (Book tab). While a trim is drawn,
/// Done and Cancel.
private struct TrimSection: View {
    @EnvironmentObject var model: AppModel
    let allPages: Bool

    var body: some View {
        Section("Trim") {
            if model.trimmingPage != nil {
                HStack {
                    Button("Done") { model.finishTrim() }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel") { model.cancelTrim() }
                        .keyboardShortcut(.cancelAction)
                }
                if allPages && model.trimmingAllPages { pagesToTrim }
            } else if allPages {
                Button {
                    model.beginTrim(allPages: true)
                } label: {
                    Label("Trim All Pages", systemImage: "crop")
                }
                .disabled(model.selectedPage == nil || model.isBusy)
                Button("Remove All Trims") { model.removeAllTrims() }
                    .disabled(!model.pages.contains { $0.trim != nil } || model.isBusy)
            } else {
                Button {
                    model.beginTrim()
                } label: {
                    Label("Trim This Page", systemImage: "crop")
                }
                .disabled(model.isBusy)
                Button("Remove Trim") { model.removeTrim() }
                    .disabled(model.selectedPage?.trim == nil || model.isBusy)
            }
        }
    }

    /// Trim All Pages: which pages it trims (ticked in the side panel), chosen there.
    @ViewBuilder
    private var pagesToTrim: some View {
        let count = model.pages.count - model.trimExcluded.count
        Text("Pages to trim: \(count) of \(model.pages.count)")
        Text("Choose pages in the side panel.").font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Leave Out Selected") { model.leaveOutOfTrim(true) }
            Button("Include Selected") { model.leaveOutOfTrim(false) }
        }
        .disabled(model.trimSelection.isEmpty)
        HStack {
            Button("All") { model.trimExcluded = [] }
                .disabled(model.trimExcluded.isEmpty)
            Button("None") { model.trimExcluded = Set(model.pages.map(\.id)) }
                .disabled(count == 0)
        }
    }
}

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

        TrimSection(allPages: true)

        Section("Detection") {
            CropTargetPicker()
            if let size = model.pageSize {
                PageSizeRow(size: size)
            }
            Toggle("Auto-straighten on import", isOn: $model.autoDeskewEnabled)
        }
    }
}

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
