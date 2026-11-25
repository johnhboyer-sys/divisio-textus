import SwiftUI
import AppKit

/// The Stack sidebar's page list: one thumbnail for each page of the stack, showing
/// that page's own crop. A tap ticks it in or out of the stack. A short stack takes
/// only the height it needs; a long one scrolls.
struct StackThumbList: View {
    @EnvironmentObject var model: AppModel
    let stack: PageStack
    let pages: [PageStack.Member]

    // Spelled State(initialValue:) rather than @State: see WelcomeView.
    private let contentHeightState = State(initialValue: CGFloat(90))
    private var contentHeight: CGFloat {
        get { contentHeightState.wrappedValue }
        nonmutating set { contentHeightState.wrappedValue = newValue }
    }

    private struct HeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    /// The part of the member's scan its thumbnail shows: the left page's crop for a
    /// left side (or a single page), the right page's for a right side, and the
    /// trimmed scan for a whole spread.
    static func cropRect(for member: PageStack.Member) -> CropRect {
        switch member.side {
        case .left, .single: return member.page.leftCrop
        case .right: return member.page.rightCrop
        case .whole: return member.limits
        }
    }

    /// The member's thumbnail: its page straightened as the editor shows it (crops are
    /// drawn on the straightened page), cut to its crop.
    @MainActor
    static func image(for member: PageStack.Member, in model: AppModel) -> NSImage? {
        guard let page = model.gridImage(for: member.page) else { return nil }
        return cropped(page, to: cropRect(for: member))
    }

    /// `cg` cut to `crop`, a share of the whole image from its top left.
    static func cropped(_ cg: CGImage, to crop: CropRect) -> NSImage? {
        let w = Double(cg.width), h = Double(cg.height)
        let rect = CGRect(x: crop.x * w, y: crop.y * h, width: crop.width * w, height: crop.height * h)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width >= 1, rect.height >= 1, let piece = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: piece, size: NSSize(width: piece.width, height: piece.height))
    }

    private let columns = [GridItem(.adaptive(minimum: 48), spacing: 8, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(pages) { member in
                    ThumbCell(member: member, on: included(member))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
        }
        .onPreferenceChange(HeightKey.self) { if $0 > 0 { contentHeight = $0 } }
        .frame(height: min(180, contentHeight))
    }

    private func included(_ member: PageStack.Member) -> Binding<Bool> {
        Binding(get: { !(model.stackExclusions[stack.id]?.contains(member.id) ?? false) },
                set: { model.setStackPage(member.id, included: $0, in: stack.id) })
    }
}

private struct ThumbCell: View {
    @EnvironmentObject var model: AppModel
    let member: PageStack.Member
    @Binding var on: Bool

    var body: some View {
        let n = member.page.sourceIndex + 1
        Button { on.toggle() } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let img = StackThumbList.image(for: member, in: model) {
                            Image(nsImage: img).resizable().scaledToFit()
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.15))
                        }
                    }
                    .frame(width: 44, height: 58)
                    .border(Color.secondary.opacity(0.4), width: 0.5)
                    .opacity(on ? 1 : 0.3)
                    if !on {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.red)
                            .font(.system(size: 14))
                            .offset(x: 4, y: -4)
                    }
                }
                Text("\(n)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(n)")
        .accessibilityValue(on ? "included" : "left out")
    }
}
