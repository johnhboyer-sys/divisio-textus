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

/// What Export makes: the book split and cropped page by page, or the PDF's own
/// pages left exactly as they are with searchable text added.
enum ExportMode: String, CaseIterable, Identifiable {
    case crop
    case textOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .crop: return "Split and crop"
        case .textOnly: return "Add text only"
        }
    }
}
