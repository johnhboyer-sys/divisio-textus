import SwiftUI
import UniformTypeIdentifiers

/// Full-window empty state shown before a PDF is loaded. A real, clickable
/// open target (the old placeholder image wasn't a button) plus drag-and-drop.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    // Spelled State(initialValue:) rather than @State: in the macOS 27 SDK @State is a
    // macro whose plugin ships only with full Xcode, so Command Line Tools can't build it.
    private let isTargetedState = State(initialValue: false)
    private var isTargeted: Bool {
        get { isTargetedState.wrappedValue }
        nonmutating set { isTargetedState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "book.pages")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Divisio Textus")
                .font(.largeTitle.weight(.semibold))

            Text("Turn scanned two-page spreads into a clean PDF —\none book page per page, cropped to the content.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                model.openPanel()
            } label: {
                Label("Open PDF…", systemImage: "folder")
                    .font(.title3)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o")

            Text("or drag a PDF anywhere in this window")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fills the window, incl. full screen
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25))
                .padding(24)
        )
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            model.load(url: url)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
