import SwiftUI

/// Left rail: scrollable list of source pages with classification badges, or only
/// the pages that need a look.
struct ThumbnailRail: View {
    @EnvironmentObject var model: AppModel
    // State(initialValue:) rather than @State, for Command Line Tools (see CropBoxView).
    private let onlyFlaggedState = State(initialValue: false)

    var body: some View {
        let flagged = model.flaggedSides
        // Trim All Pages: the pages are chosen here, as on a Mac, to leave out; all of them shown.
        let choosing = model.trimmingPage != nil && model.trimmingAllPages
        let shown = onlyFlaggedState.wrappedValue && !choosing ? model.pages.filter { flagged[$0.id] != nil } : model.pages
        VStack(spacing: 0) {
            // While choosing for Trim All Pages: All, greyed out; the choice comes back after.
            Picker("Show", selection: Binding(get: { onlyFlaggedState.wrappedValue && !choosing },
                                              set: { onlyFlaggedState.wrappedValue = $0 })) {
                Text("All").tag(false)
                Text(flagged.isEmpty ? "Needs a look" : "Needs a look (\(flagged.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(choosing)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .help("Needs a look: pages whose crop is a different size from the rest of its stack (Go ▸ Next Page Needing a Look)")

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { page in
                            ThumbnailRow(page: page,
                                         isSelected: choosing ? model.trimSelection.contains(page.id) : page.id == model.selectedPageID,
                                         flaggedSides: flagged[page.id] ?? [],
                                         trimmed: choosing ? !model.trimExcluded.contains(page.id) : nil)
                                .id(page.id)
                                .onTapGesture {
                                    guard choosing else { model.selectedPageID = page.id; return }
                                    let keys = NSEvent.modifierFlags
                                    model.chooseForTrim(page.id, keys.contains(.shift) ? .range : keys.contains(.command) ? .toggle : .plain,
                                                        order: shown.map(\.id))
                                }
                                .contextMenu {
                                    if choosing { trimMenu(for: page, order: shown.map(\.id)) } else { classificationMenu(for: page) }
                                }
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
                // And the page chosen for Trim All Pages, as ↑/↓ move it.
                .onChange(of: model.trimSelection) { _, chosen in
                    guard chosen.count == 1, let id = chosen.first else { return }
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
        .frame(minWidth: 170)
    }

    /// Trim All Pages: leave the chosen pages out, or put them back (the page
    /// right-clicked alone, if it isn't chosen).
    @ViewBuilder
    private func trimMenu(for page: BookPage, order: [BookPage.ID]) -> some View {
        Button("Leave Out") { choose(page, order); model.leaveOutOfTrim(true) }
        Button("Include") { choose(page, order); model.leaveOutOfTrim(false) }
    }

    private func choose(_ page: BookPage, _ order: [BookPage.ID]) {
        if !model.trimSelection.contains(page.id) { model.chooseForTrim(page.id, .plain, order: order) }
    }

    /// The page's type, ticked. Skip again on a skipped page brings back the type it had.
    @ViewBuilder
    private func classificationMenu(for page: BookPage) -> some View {
        ForEach(PageClassification.allCases) { c in
            Toggle(isOn: Binding(
                get: { page.classification == c },
                set: { _ in c == .skip ? model.toggleSkip(for: page.id) : model.setClassification(c, for: page.id) })
            ) {
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
    /// Trim All Pages: whether it trims this page (nil: not choosing).
    var trimmed: Bool? = nil

    /// What shows of the page: its trim, or all of it.
    private func trimmed(_ img: NSImage, to trim: CropRect?) -> NSImage {
        guard let trim, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let part = cg.cropping(to: trim.pixelRect(in: CGSize(width: cg.width, height: cg.height)).integral)
        else { return img }
        return NSImage(cgImage: part, size: NSSize(width: part.width, height: part.height))
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let img = model.thumbnail(for: page) {
                    Image(nsImage: trimmed(img, to: page.trim))
                        .resizable().scaledToFit()
                        .frame(maxHeight: 120)
                        .opacity(page.classification == .skip || trimmed == false ? 0.4 : 1)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(height: 90)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if let trimmed {
                    Image(systemName: trimmed ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(trimmed ? Color.accentColor : .secondary)
                        .background(Circle().fill(.background))
                        .padding(4)
                }
            }
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
                Text(page.classification.label + omittedNote)
            }
            .font(.caption)
            .foregroundStyle(page.classification == .skip ? .secondary : .primary)
        }
    }

    /// " · right only" on a spread whose left page is left out, and the like.
    private var omittedNote: String {
        guard page.isSpread, let out = page.omittedSide else { return "" }
        return out == .left ? " · right only" : " · left only"
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
        for stack in PageStack.groups(pages: pages, excluded: stackExclusions) {
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
