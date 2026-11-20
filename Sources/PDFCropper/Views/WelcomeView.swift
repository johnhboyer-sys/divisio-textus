import SwiftUI
import UniformTypeIdentifiers
import PDFKit

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
        // Thirds: the logo block sits in the middle one, the recent PDFs in the last.
        GeometryReader { geo in
            VStack(spacing: 0) {
                Color.clear.frame(height: geo.size.height / 3)

                VStack(spacing: 10) {
                    Image(nsImage: model.appIcon ?? NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 116, height: 116)
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 9)

                    nameSplit

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
                }
                .frame(height: geo.size.height / 3)

                ScrollView {
                    // Rows of as many cards as fit (at most 8), each row centred.
                    let perRow = max(1, min(RecentFiles.shown, Int((geo.size.width - 80 + 12) / 144)))
                    VStack(spacing: 12) {
                        ForEach(Array(stride(from: 0, to: model.recents.count, by: perRow)), id: \.self) { start in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(model.recents[start..<min(start + perRow, model.recents.count)]) { RecentCard(recent: $0) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
                .frame(height: geo.size.height / 3, alignment: .top)
                .opacity(model.recents.isEmpty ? 0 : 1)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 40).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fills the window, incl. full screen
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25))
                .padding(24)
        )
        .contentShape(Rectangle())
        .onAppear { model.refreshRecents() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            model.load(url: url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    /// The name as on the product site: each word on its own side of a dashed split line.
    private var nameSplit: some View {
        let word = Font.system(size: 64, weight: .heavy)
        return HStack(spacing: 0) {
            Text("Divisio").font(word).tracking(-2.5)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Rectangle().fill(.clear).frame(width: 24)
            Text("Textus").font(word).tracking(-2.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 760)
        .overlay {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 100))
            }
            .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
            .frame(width: 3, height: 100)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Divisio Textus")
    }
}

/// One recent PDF: first-page thumbnail, name, when it was opened. Click opens it.
private struct RecentCard: View {
    @EnvironmentObject var model: AppModel
    let recent: RecentPDF
    private let thumbnail = State<NSImage?>(initialValue: nil)
    private let hover = State(initialValue: false)

    var body: some View {
        Button { model.load(url: recent.url) } label: {
            VStack(spacing: 4) {
                Group {
                    if let image = thumbnail.wrappedValue {
                        Image(nsImage: image).resizable().scaledToFit()
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 120, height: 110)

                Text(recent.url.deletingPathExtension().lastPathComponent)
                    .font(.caption)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                    .frame(width: 120, height: 30, alignment: .top)
                Text(recent.opened, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(6)
            .background(hover.wrappedValue ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .help(recent.url.path)
        .task(id: recent.url) {
            let url = recent.url
            thumbnail.wrappedValue = await Task.detached(priority: .utility) { RecentCard.firstPage(of: url) }.value
        }
    }

    nonisolated private static func firstPage(of url: URL) -> NSImage? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        return page.thumbnail(of: CGSize(width: 240, height: 220), for: .mediaBox)
    }
}
