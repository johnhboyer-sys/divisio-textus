import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        // The status line sits below the content rather than in a safe-area inset:
        // the split views ignore insets, so it covered the bottom of every pane.
        VStack(spacing: 0) {
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
                                .frame(minWidth: 240, maxWidth: 320)
                        }
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
                        model.load(url: url)
                        return true
                    }
                }
            }
            Divider()
            HStack {
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.openPanel()
                } label: {
                    Label("Open PDF", systemImage: "folder")
                }
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.showsStack) {
                    Text("Page").tag(false)
                    Text("Stack").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.exportPanel()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.canExport)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, newValue in model.undoManager = newValue }
    }
}
