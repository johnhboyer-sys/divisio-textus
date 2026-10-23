import Foundation

/// The View menu's Show Rulers setting.
enum Rulers {
    static let storageKey = "showsRulers"
    static let shownByDefault = false

    static func isShown(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? shownByDefault
    }
}

/// The rulers' unit: inches where the Mac measures in US units, else centimetres.
enum RulerUnit: Equatable {
    case inches, centimeters

    init(locale: Locale = .current) {
        self = locale.measurementSystem == .us ? .inches : .centimeters
    }

    /// PDF points per unit (72 to the inch).
    var points: Double { self == .inches ? 72 : 72 / 2.54 }

    var symbol: String { self == .inches ? "in" : "cm" }

    /// A length as the crop size pills show it: hundredths of an inch, tenths of a centimetre.
    func label(points: Double, locale: Locale = .current) -> String {
        number(points: points, locale: locale) + " " + symbol
    }

    /// The number alone; `digits` defaults to the pills' precision.
    func number(points: Double, locale: Locale = .current, digits: Int? = nil) -> String {
        (points / self.points).formatted(.number.precision(.fractionLength(digits ?? (self == .inches ? 2 : 1)))
            .locale(locale))
    }

    /// Steps finer than one unit, finest first: every one divides one unit.
    fileprivate var fractions: [Double] {
        self == .inches ? [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2] : [0.1, 0.5]
    }
}

/// The crop boxes' sizes under the canvas, and whether a spread's two are the same.
struct CropSizeReadout: Equatable {
    /// Export cuts each crop to whole pixels at 150 to 600 DPI, so boxes closer than one
    /// pixel at 150 DPI can't be told apart in the exported pages.
    static let tolerance = 72.0 / 150

    var sizes: [String]
    var verdict: String?
    var same: Bool?

    /// `left` is the only box on a single page or a one-box stack; sizes in PDF points.
    init(left: CGSize, right: CGSize?, unit: RulerUnit, locale: Locale = .current) {
        func size(_ s: CGSize) -> String {
            "\(unit.number(points: s.width, locale: locale)) × \(unit.number(points: s.height, locale: locale)) \(unit.symbol)"
        }
        guard let right else {
            sizes = [size(left)]
            return
        }
        sizes = ["Left " + size(left), "Right " + size(right)]
        // Differences to hundredths, so one just over the tolerance never reads as zero.
        func difference(_ d: Double, _ more: String, _ less: String) -> String? {
            abs(d) < Self.tolerance ? nil
                : "\(unit.number(points: abs(d), locale: locale, digits: 2)) \(unit.symbol) \(d > 0 ? more : less)"
        }
        let parts = [difference(right.width - left.width, "wider", "narrower"),
                     difference(right.height - left.height, "taller", "shorter")].compactMap { $0 }
        same = parts.isEmpty
        verdict = parts.isEmpty ? "Same size" : "Right is " + parts.joined(separator: " and ")
    }
}

struct RulerTick: Equatable {
    enum Size { case long, medium, short }
    /// On screen, along the ruler, in the same coordinates as `origin`.
    let position: Double
    let size: Size
    let label: String?
}

/// Where a ruler's ticks fall for a page drawn `screenPerPoint` screen points per
/// PDF point: as fine as stays readable, labelled in whole units.
struct RulerScale {
    let unit: RulerUnit
    let screenPerPoint: Double

    /// Least room between two ticks, and between two labels, in screen points.
    static let minTickSpacing = 5.0
    static let minLabelSpacing = 22.0
    private static let labelSteps: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000]

    private var unitLength: Double { unit.points * screenPerPoint }

    /// Units between labels.
    var labelStep: Double {
        Self.labelSteps.first { $0 * unitLength >= Self.minLabelSpacing } ?? Self.labelSteps.last!
    }

    /// Units between ticks: the finest step that divides `labelStep` and keeps ticks apart.
    var tickStep: Double {
        let label = labelStep
        let steps = unit.fractions + Self.labelSteps.filter { $0 <= label && label.truncatingRemainder(dividingBy: $0) == 0 }
        return steps.first { $0 * unitLength >= Self.minTickSpacing } ?? label
    }

    /// The ticks for a page edge `length` PDF points long whose start is drawn at `origin`.
    func ticks(length: Double, origin: Double) -> [RulerTick] {
        guard unitLength.isFinite, unitLength > 0, length.isFinite, length >= 0, origin.isFinite else { return [] }
        let step = tickStep, label = labelStep
        let count = Int((length / unit.points / step + 1e-9).rounded(.down))
        guard count < 100_000 else { return [] }
        let perLabel = Int((label / step).rounded())
        return (0...count).map { i in
            let value = Double(i) * step
            let size: RulerTick.Size = i % perLabel == 0 ? .long
                : perLabel % 2 == 0 && i % (perLabel / 2) == 0 ? .medium : .short
            return RulerTick(position: origin + value * unit.points * screenPerPoint, size: size,
                             label: size == .long ? String(Int(value.rounded())) : nil)
        }
    }
}
