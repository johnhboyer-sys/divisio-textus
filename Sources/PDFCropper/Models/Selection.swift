import Foundation

extension Collection where Element: Equatable {
    /// The one value every element has, or nil when they differ (the sidebar shows
    /// "mixed") or there are none.
    var shared: Element? {
        guard let first, allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

extension CropSizeReadout {
    /// The Difference row for several spreads: one's own, "Equal" when every one's
    /// boxes match, else on how many they don't.
    static func difference(of readouts: [CropSizeReadout]) -> (text: String, differs: Bool) {
        if readouts.count == 1, let one = readouts.first { return (one.difference ?? "", one.same == false) }
        let unequal = readouts.filter { $0.same == false }.count
        if unequal == 0 { return ("Equal", false) }
        return (unequal == readouts.count ? "Unequal on all \(unequal)" : "Unequal on \(unequal) of \(readouts.count)", true)
    }
}
