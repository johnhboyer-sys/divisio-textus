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
                Text(model.viewMode == .grid ? "\(model.sidebarTargets.count) Selected"
                     : model.showsStack ? "This Stack" : "This Page").tag(Side.one)
                Text("All Pages").tag(Side.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(choosing)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)

            Form {
                switch side {
                case .one:
                    if model.showsStack { StackSections() }
                    else if model.sidebarTargets.count > 1 { SelectionSections(ids: model.sidebarTargets) }
                    else { PageSections() }
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

/// Grid view with several pages chosen: the same groups as This Page, acting on
/// every one of them. A value they don't share reads "mixed". Apply layout copies
/// from the last page clicked; Trim draws on it and trims them all.
private struct SelectionSections: View {
    @EnvironmentObject var model: AppModel
    let ids: [BookPage.ID]
    private let skewProbes = State(initialValue: StraightenRowProbes())

    private var chosen: [BookPage] { model.pages.filter { ids.contains($0.id) } }

    var body: some View {
        let chosen = self.chosen
        let kept = chosen.filter { $0.classification != .skip }
        let spreads = chosen.filter(\.isSpread)
        let flagged = chosen.filter { model.flaggedSides[$0.id] != nil }.count
        Section {
            Picker("Type", selection: Binding<PageClassification?>(
                get: { chosen.map(\.classification).shared },
                set: { if let c = $0 { model.setClassification(c, for: ids) } })
            ) {
                ForEach(PageClassification.allCases) { c in
                    Text(c.label).tag(PageClassification?.some(c))
                }
            }
            .pickerStyle(.segmented)
            if !spreads.isEmpty {
                Picker("Export", selection: Binding<BookPage.Side??>(
                    get: { spreads.map(\.omittedSide).shared.map { .some($0) } ?? nil },
                    set: { if let side = $0 { model.setOmittedSide(side, for: ids) } })
                ) {
                    Text("Both").tag(BookPage.Side??.some(nil))
                    Text("Left").tag(BookPage.Side??.some(.right))     // leaves the right out
                    Text("Right").tag(BookPage.Side??.some(.left))
                }
                .pickerStyle(.segmented)
                .help("Choose which page or pages of each chosen spread go in the export.")
            }
            Text(Self.numbers(chosen)).font(.caption).foregroundStyle(.secondary)
        } header: {
            PageHeader(title: "\(chosen.count) pages",
                       note: flagged > 0 ? "\(flagged) need\(flagged == 1 ? "s" : "") a look" : nil)
        }

        if !kept.isEmpty {
            Section("Trim") {
                HStack {
                    Button { model.beginTrim(selection: ids) } label: {
                        Label("Trim", systemImage: "crop").frame(maxWidth: .infinity)
                    }
                        .disabled(model.isBusy || model.selectedPage?.classification == .skip)
                        .help("Draw the trim on the last page clicked; Done trims every page chosen")
                    Button { model.removeTrims(ids) } label: { Text("Remove Trim").frame(maxWidth: .infinity) }
                        .disabled(!chosen.contains { $0.trim != nil } || model.isBusy)
                }
            }

            Section("Straighten") {
                if spreads.isEmpty {
                    skewRow("Angle", kept.map(\.leftSkew), side: .left, row: .angle)
                } else {
                    skewRow("Left", kept.map(\.leftSkew), side: .left, row: .left)
                    skewRow("Right", spreads.map(\.rightSkew), side: .right, row: .right)
                }
                Button {
                    model.autoStraighten(ids)
                } label: {
                    Label("Auto-straighten", systemImage: "level").frame(maxWidth: .infinity)
                }
            }

            Section("Crop") {
                let readouts = spreads.compactMap { p in
                    model.displaySize(of: p).map { CropSizeReadout(leftCrop: p.leftCrop, rightCrop: p.rightCrop, in: $0, unit: RulerUnit()) }
                }
                let difference = CropSizeReadout.difference(of: readouts)
                HStack {
                    Button { model.reanalyze(ids) } label: {
                        Label("Detect", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                    .help("Auto-detect each chosen page")
                    if !spreads.isEmpty {
                        MatchMenu(differs: difference.differs) { model.matchCropSizes(of: ids, rightMatchesLeft: $0) }
                    }
                }
                if !readouts.isEmpty {
                    SizeRows(left: readouts.map { $0.lengths[0] }.shared ?? "mixed",
                             right: readouts.map { $0.lengths[1] }.shared ?? "mixed",
                             difference: difference.text, differs: difference.differs)
                    LockSizesToggle()
                }
                if model.selectedPage?.isSpread == true {
                    Button {
                        model.applyLayoutToAllSpreads()
                    } label: {
                        Text("Apply layout to all spreads").frame(maxWidth: .infinity)
                    }
                    .help("Copies the last page clicked's split line and both crops to every spread.")
                }
            }
        }
    }

    /// A slider over several pages: it shows the last page clicked's angle and sets
    /// every page's, "mixed" while they differ.
    private func skewRow(_ title: String, _ values: [Double], side: BookPage.Side, row: StraightenFocus.Row) -> some View {
        let anchor = model.selectedPage.map { side == .left ? $0.leftSkew : $0.rightSkew } ?? values.first ?? 0
        return HStack(spacing: 6) {
            Text(title).frame(width: 42, alignment: .leading)
            Slider(value: Binding(get: { anchor }, set: { model.setSkew($0, side: side, for: ids) }),
                   in: -8...8, step: 0.1) { editing in
                if editing { model.beginEdit(of: ids) } else { model.endEdit(of: ids, "Straighten") }
            }
            .labelsHidden()
            Text(values.shared.map { String(format: "%+.1f°", $0) } ?? "mixed")
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Button { model.perform("Straighten") { model.setSkew(0, side: side, for: ids) } } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset each to 0°")
        }
    }

    /// "Pages 2, 4, 6", the first few and how many more.
    private static func numbers(_ pages: [BookPage]) -> String {
        let shown = pages.prefix(8).map { String($0.sourceIndex + 1) }.joined(separator: ", ")
        return "Pages " + shown + (pages.count > 8 ? " and \(pages.count - 8) more" : "")
    }
}

/// The sidebar's title line: what it acts on, and "Needs a look" when it does.
private struct PageHeader: View {
    let title: String
    var flagged = false
    var note: String? = nil

    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(.primary)
            Spacer()
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if flagged {
                Label("Needs a look", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Stack view, This Stack: the orange draft's sizes, Apply to every page of the
/// stack or only the flagged ones, the flagged pages (in the whole-spread stack,
/// those whose split is far from the rest), and which pages are in the stack.
private struct StackSections: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let stacks = model.stacks
        if let stack = stacks.first(where: { $0.id == model.stackKind }) ?? stacks.first {
            let spreads = stack.id == .spreads
            Section {
                cropRows(stack)
            } header: {
                PageHeader(title: stack.id.label,
                           note: "\(stack.members.count) of \(stack.allMembers.count) in the stack")
            }

            Section(spreads ? "Apply layout" : "Apply crop") {
                HStack {
                    Button { apply(stack, to: stack.members) } label: {
                        Text("To All \(stack.members.count)").frame(maxWidth: .infinity)
                    }
                    Button { apply(stack, to: stack.outliers) } label: {
                        Text("To the \(stack.outliers.count) Flagged").frame(maxWidth: .infinity)
                    }
                    .disabled(stack.outliers.isEmpty)
                }
                .disabled(model.isAnalyzing || stack.members.isEmpty || !model.stackImageReady)
                .help(spreads ? "Set every spread, or only the flagged ones, to the orange split and the blue and green crops"
                              : "Set every page in this stack, or only the flagged ones, to the orange crop")
            }

            flaggedSection(stack)
            pickSection(stack)
        } else {
            Text("No pages to stack.")
                .foregroundStyle(.secondary)
        }
    }

    /// The draft's sizes, once analysis has settled them.
    @ViewBuilder
    private func cropRows(_ stack: PageStack) -> some View {
        if !model.isAnalyzing, let document = model.document,
           let size = StackRenderer.pointSize(of: stack, in: document) {
            if stack.id == .spreads {
                let layout = model.spreadLayout(for: stack)
                let readout = CropSizeReadout(leftCrop: layout.leftCrop, rightCrop: layout.rightCrop, in: size, unit: RulerUnit())
                MatchMenu(differs: readout.same == false) { rightMatchesLeft in
                    var l = model.spreadLayout(for: stack)
                    l.matchSizesMovingSplit(rightMatchesLeft: rightMatchesLeft)
                    model.spreadLayout = l
                    let (moved, other) = rightMatchesLeft ? (l.rightCrop, l.leftCrop) : (l.leftCrop, l.rightCrop)
                    if other.width - moved.width > 1e-6 {
                        model.statusText = SpreadLayout.matchShortfall(rightMatchesLeft: rightMatchesLeft)
                    }
                }
                SpreadSizeControls(readout: readout)
            } else {
                let readout = CropSizeReadout(leftCrop: model.stackDraft(for: stack), rightCrop: nil, in: size, unit: RulerUnit())
                LabeledContent("Size") { Text(readout.lengths.first ?? "").monospacedDigit() }
            }
        } else {
            Text("Waiting for page analysis to finish…")
                .foregroundStyle(.secondary)
        }
    }

    private func apply(_ stack: PageStack, to members: [PageStack.Member]) {
        if stack.id == .spreads {
            model.applySpreadLayout(model.spreadLayout(for: stack), to: members)
        } else {
            model.applyStackCrop(model.stackDraft(for: stack), to: members, in: stack)
        }
    }

    private func flaggedSection(_ stack: PageStack) -> some View {
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
                    LabeledContent {
                        Button("Show") {
                            model.selectedPageID = member.id
                            model.showsStack = false
                        }
                        .help("Open this page in Page view")
                    } label: {
                        Label {
                            Text(member.side == .whole || member.side == .single
                                 ? "p. \(member.page.sourceIndex + 1)"
                                 : "p. \(member.page.sourceIndex + 1) · \(member.side.rawValue)")
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
            }
        } header: {
            Text(model.isAnalyzing ? "Flagged" : "Flagged (\(stack.outliers.count))")
        } footer: {
            if !model.isAnalyzing, !stack.outliers.isEmpty {
                Text(stack.id == .spreads ? "Their splits are far from the usual split."
                                          : "Their crops differ in size from the rest of the stack.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A tick for each page of the stack. An unticked page is out of this stack
    /// only: not blended, judged or changed by Apply, and still exported.
    private func pickSection(_ stack: PageStack) -> some View {
        let pages = stack.allMembers
        return Section {
            HStack {
                Button { model.setAllStackPages(included: true, in: stack) } label: {
                    Text("All").frame(maxWidth: .infinity)
                }
                .disabled(stack.excludedMembers.isEmpty)
                Button { model.setAllStackPages(included: false, in: stack) } label: {
                    Text("None").frame(maxWidth: .infinity)
                }
                .disabled(stack.members.isEmpty)
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
            Text("Pages in this stack")
        } footer: {
            Text("A page left out is not drawn here, counted or changed by Apply. It is still in Page view and the export.")
                .font(.caption).foregroundStyle(.secondary)
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
                        Label("Trim All Pages", systemImage: "crop").frame(maxWidth: .infinity)
                    }
                    .disabled(model.selectedPage == nil || model.isBusy)
                    Button { model.removeAllTrims() } label: {
                        Text("Remove All Trims").frame(maxWidth: .infinity)
                    }
                    .disabled(!model.pages.contains { $0.trim != nil } || model.isBusy)
                }
            } else {
                HStack {
                    Button { model.beginTrim() } label: {
                        Label("Trim", systemImage: "crop").frame(maxWidth: .infinity)
                    }
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
