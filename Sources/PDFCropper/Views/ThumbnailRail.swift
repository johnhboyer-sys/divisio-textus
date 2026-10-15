import SwiftUI

/// Left rail: scrollable list of source pages with classification badges.
struct ThumbnailRail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.pages) { page in
                    ThumbnailRow(page: page,
                                 isSelected: page.id == model.selectedPageID)
                        .onTapGesture { model.selectedPageID = page.id }
                        .contextMenu { classificationMenu(for: page) }
                }
            }
            .padding(8)
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

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let img = model.previewImage(for: page) {
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
            .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )

            HStack(spacing: 4) {
                Text("\(page.sourceIndex + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: page.classification.symbol)
                    .font(.caption2)
                Text(page.classification.label).font(.caption2)
            }
            .foregroundStyle(badgeColor)
        }
    }

    private var badgeColor: Color {
        switch page.classification {
        case .spread: return .primary
        case .single: return .blue
        case .skip:   return .secondary
        }
    }
}
