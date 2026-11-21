import Foundation

/// Color treatment applied to every output page. Deliberately minimal:
/// desaturating to grayscale, which shrinks color scans with no visible quality
/// loss, or black and white judged against the paper around each pixel
/// (`BlackAndWhite`), which keeps faint print and drops shadows. Pages holding a
/// picture stay grayscale in black and white. (Earlier contrast/binarize options
/// were dropped — they over-processed readable book scans.)
enum EnhanceMode: String, Codable, CaseIterable, Identifiable {
    case color        // leave exactly as scanned
    case grayscale    // desaturate only — smaller files, no sharpening
    case blackAndWhite // 1 bit, ink against the paper around it

    var id: String { rawValue }
    var label: String {
        switch self {
        case .color: return "Color"
        case .grayscale: return "Grayscale"
        case .blackAndWhite: return "Black and white"
        }
    }
}
