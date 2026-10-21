import SwiftUI

/// Left rail: scrollable list of source pages with classification badges, or only
/// the pages that need a look.
struct ThumbnailRail: View {
    @EnvironmentObject var model: AppModel
    // State(initialValue:) rather than @State, for Command Line Tools (see CropBoxView).
    private let onlyFlaggedState = State(initialValue: false)

    var body: some View {
        let flagged = model.flaggedSides
        let shown = onlyFlaggedState.wrappedValue ? model.pages.filter { flagged[$0.id] != nil } : model.pages
        VStack(spacing: 0) {
            Picker("Show", selection: onlyFlaggedState.projectedValue) {
                Text("All").tag(false)
                Text(flagged.isEmpty ? "Needs a look" : "Needs a look (\(flagged.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8).padding(.vertical, 6)
            .help("Needs a look: pages whose crop is a different size from the rest of its stack (Go ▸ Next Page Needing a Look)")

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { page in
                            ThumbnailRow(page: page,
                                         isSelected: page.id == model.selectedPageID,
                                         flaggedSides: flagged[page.id] ?? [])
                                .id(page.id)
                                .onTapGesture { model.selectedPageID = page.id }
                                .contextMenu { classificationMenu(for: page) }
                        }
                        if shown.isEmpty {
                            Text(model.isAnalyzing ? "Pages are judged once analysis finishes."
                                                   : "Every page's crops match the rest of its stack.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 20)
                        }
                    }
                    .padding(8)
                }
                // Keep the selected page in view when ↑/↓ moves past the visible rows.
                .onChange(of: model.selectedPageID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(minWidth: 170)
    }

    @ViewBuilder
    private func classificationMenu(for page: BookPage) -> some View {
        ForEach(PageClassification.allCases) { c in
            Button {
                model.setClassification(c, for: page.id)
            } label: {
                Label(c.label, systemImage: c.symbol)
            }
        }
    }
}

private struct ThumbnailRow: View {
    @EnvironmentObject var model: AppModel
    let page: BookPage
    let isSelected: Bool
    let flaggedSides: [PageStack.Member.Side]

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let img = model.thumbnail(for: page) {
                    Image(nsImage: img)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 120)
                        .opacity(page.classification == .skip ? 0.4 : 1)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(height: 90)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(4)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
            )

            HStack(spacing: 4) {
                if !flaggedSides.isEmpty {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .help(flagHelp)
                }
                Text("\(page.sourceIndex + 1)")
                    .monospacedDigit()
                    .fontWeight(.semibold)
                Text("·").foregroundStyle(.secondary)
                Image(systemName: page.classification.symbol)
                Text(page.classification.label)
            }
            .font(.caption)
            .foregroundStyle(page.classification == .skip ? .secondary : .primary)
        }
    }

    private var flagHelp: String {
        let sides = flaggedSides.map(\.rawValue).joined(separator: " and ")
        return flaggedSides == [.single]
            ? "This crop is a different size from the other single pages'."
            : "The \(sides) crop is a different size from the rest of its stack."
    }
}

extension AppModel {
    /// The sides of each page whose crop differs in size from the rest of its stack
    /// (see PageStack.outliers). Empty while analysis runs, as its crops are
    /// placeholders until it finishes.
    var flaggedSides: [BookPage.ID: [PageStack.Member.Side]] {
        guard !isAnalyzing else { return [:] }
        var sides: [BookPage.ID: [PageStack.Member.Side]] = [:]
        for stack in PageStack.groups(pages: pages) {
            for member in stack.outliers { sides[member.id, default: []].append(member.side) }
        }
        return sides
    }

    /// Selects the next page that needs a look after the selected one, wrapping
    /// round to the first.
    func selectNextFlaggedPage() {
        let flagged = flaggedSides
        guard !flagged.isEmpty else { return }
        let start = (selectedIndex ?? -1) + 1
        let order = Array(pages[min(start, pages.count)...]) + Array(pages[..<min(start, pages.count)])
        if let next = order.first(where: { flagged[$0.id] != nil }) {
            selectedPageID = next.id
            showsStack = false
        }
    }
}
