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

            Section("Output") {
                Picker("Color", selection: $model.enhanceMode) {
                    ForEach(EnhanceMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
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
