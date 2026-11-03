import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.undoManager) private var undoManager
    // State(initialValue:) rather than @State, for Command Line Tools (see CropBoxView).
    private let railState = State(initialValue: NavigationSplitViewVisibility.all)
    private let savedRail = State(initialValue: NavigationSplitViewVisibility.all)

    /// No rail in Grid view or the Export view.
    private var railHidden: Bool { model.showsExport || model.viewMode == .grid }

    var body: some View {
        Group {
            if model.document == nil {
                WelcomeView()
            } else {
                NavigationSplitView(columnVisibility: railState.projectedValue) {
                    ThumbnailRail()
                        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
                } detail: {
                    if model.showsExport {
                        ExportView()
                    } else {
                        HSplitView {
                            Group {
                                switch model.viewMode {
                                case .grid: GridView()
                                case .page: PageEditorView()
                                case .stack: StackView()
                                }
                            }
                            .frame(minWidth: 380)
                            InspectorView()
                                .frame(minWidth: 260, maxWidth: 340)
                        }
                    }
                }
                // The rail goes, and comes back as the user left it.
                .onChange(of: railHidden, initial: true) { _, hidden in
                    if hidden {
                        savedRail.wrappedValue = railState.wrappedValue
                        railState.wrappedValue = .detailOnly
                    } else {
                        railState.wrappedValue = savedRail.wrappedValue
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
                    Picker("View", selection: Binding(get: { model.viewMode },
                                                      set: { mode in
                                                          // A trim is drawn on the page, so Grid waits for Done or Cancel.
                                                          guard mode != .grid || model.trimmingPage == nil else { return }
                                                          model.viewMode = mode; model.showsExport = false })) {
                        Text("Grid").tag(AppModel.ViewMode.grid)
                        Text("Page").tag(AppModel.ViewMode.page)
                        Text("Stack").tag(AppModel.ViewMode.stack)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .help("Grid view (⌘3), Page view (⌘1) or Stack view (⌘2)")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.isAnalyzing || model.isStraightening {
                        ProgressView().controlSize(.small)
                    }
                    if model.viewMode == .page && !model.showsExport {
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
                            model.showsExport = true
                        } label: {
                            Label("Export…", systemImage: "square.and.arrow.up")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
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
            // Always spinning, so a long wait for Vision doesn't look like a hang.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text(model.exportProgress > 0 ? "Exporting \(Int((model.exportProgress * 100).rounded()))%" : "Starting…")
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
