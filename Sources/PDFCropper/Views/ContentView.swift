import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if model.document == nil {
                WelcomeView()
            } else {
                NavigationSplitView {
                    ThumbnailRail()
                        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
                } detail: {
                    HSplitView {
                        Group {
                            if model.showsStack { StackView() }
                            else { PageEditorView() }
                        }
                        .frame(minWidth: 380)
                        InspectorView()
                            .frame(minWidth: 260, maxWidth: 340)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
                    model.load(url: url)
                    return true
                }
            }
        }
        // The status line lives in the title bar, under the file's name.
        .navigationTitle(model.sourceURL?.lastPathComponent ?? "Divisio Textus")
        .navigationSubtitle(model.statusText)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.openPanel()
                } label: {
                    Label("Open PDF", systemImage: "folder")
                }
                .help("Open PDF (⌘O)")
            }
            if model.document != nil {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $model.showsStack) {
                        Text("Page").tag(false)
                        Text("Stack").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .help("Page view (⌘1) or Stack view (⌘2)")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.isAnalyzing || model.isStraightening {
                        ProgressView().controlSize(.small)
                    }
                    if !model.showsStack {
                        ControlGroup {
                            Button { model.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                                .help("Zoom Out (⌘−)")
                            Button { model.zoomToFit() } label: { Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                                .help("Zoom to Fit (⌘0)")
                            Button { model.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                                .help("Zoom In (⌘=)")
                        }
                    }
                    if model.isExporting {
                        ExportReadout()
                    } else {
                        Button {
                            model.exportPanel()
                        } label: {
                            Label("Export…", systemImage: "square.and.arrow.up")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canExport)
                        .help("Export PDF (⌘E)")
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, newValue in model.undoManager = newValue }
    }
}

/// Stands in for the Export button while an export runs: how far it has got, and a
/// way to stop it.
private struct ExportReadout: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: model.exportProgress)
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text("Exporting \(Int((model.exportProgress * 100).rounded()))%")
                .monospacedDigit()
            Button {
                model.cancelExport()
            } label: {
                Label("Cancel Export", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Cancel Export (⌘.)")
        }
        .padding(.horizontal, 6)
    }
}
