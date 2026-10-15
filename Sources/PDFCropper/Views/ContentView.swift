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
                        PageEditorView()
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
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.openPanel()
                } label: {
                    Label("Open PDF", systemImage: "folder")
                }
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
                .disabled(model.document == nil || model.isBusy)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, newValue in model.undoManager = newValue }
    }
}
