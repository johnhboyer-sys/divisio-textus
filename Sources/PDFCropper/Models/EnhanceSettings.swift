import Foundation

/// Color treatment applied to every output page. Deliberately minimal: the only
/// non-destructive, useful option is desaturating to grayscale, which shrinks
/// color scans with no visible quality loss. (Earlier contrast/binarize options
/// were dropped — they over-processed readable book scans.)
enum EnhanceMode: String, Codable, CaseIterable, Identifiable {
    case color        // leave exactly as scanned
    case grayscale    // desaturate only — smaller files, no sharpening

    var id: String { rawValue }
    var label: String {
        switch self {
        case .color: return "Color"
        case .grayscale: return "Grayscale"
        }
    }
}
