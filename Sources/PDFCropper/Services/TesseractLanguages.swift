import Foundation

/// Scripts that need Tesseract, with their Unicode block ranges.
enum Script: String, CaseIterable {
    case greek, hebrew, syriac, armenian, georgian, ethiopic
    case bengali, gurmukhi, gujarati, oriya, tamil, telugu, kannada, malayalam
    case sinhala, tibetan, khmer, lao, myanmar, thaana, cherokee, canadianAboriginal

    var ranges: [ClosedRange<UInt32>] {
        switch self {
        case .greek: return [0x0370...0x03FF, 0x1F00...0x1FFF]
        case .hebrew: return [0x0590...0x05FF, 0xFB1D...0xFB4F]
        case .syriac: return [0x0700...0x074F, 0x0860...0x086F]
        case .armenian: return [0x0530...0x058F]
        case .georgian: return [0x10A0...0x10FF, 0x1C90...0x1CBF, 0x2D00...0x2D2F]
        case .ethiopic: return [0x1200...0x139F, 0x2D80...0x2DDF, 0xAB00...0xAB2F, 0x1E7E0...0x1E7FF]
        case .bengali: return [0x0980...0x09FF]
        case .gurmukhi: return [0x0A00...0x0A7F]
        case .gujarati: return [0x0A80...0x0AFF]
        case .oriya: return [0x0B00...0x0B7F]
        case .tamil: return [0x0B80...0x0BFF, 0x11FC0...0x11FFF]
        case .telugu: return [0x0C00...0x0C7F]
        case .kannada: return [0x0C80...0x0CFF]
        case .malayalam: return [0x0D00...0x0D7F]
        case .sinhala: return [0x0D80...0x0DFF, 0x111E0...0x111FF]
        case .tibetan: return [0x0F00...0x0FFF]
        case .khmer: return [0x1780...0x17FF, 0x19E0...0x19FF]
        case .lao: return [0x0E80...0x0EFF]
        case .myanmar: return [0x1000...0x109F, 0xA9E0...0xA9FF, 0xAA60...0xAA7F, 0x116D0...0x116FF]
        case .thaana: return [0x0780...0x07BF]
        case .cherokee: return [0x13A0...0x13FF, 0xAB70...0xABBF]
        case .canadianAboriginal: return [0x1400...0x167F, 0x18B0...0x18FF, 0x11AB0...0x11ABF]
        }
    }

    /// True when a scalar lies in one of this script's blocks.
    func contains(_ scalar: Unicode.Scalar) -> Bool {
        ranges.contains { $0.contains(scalar.value) }
    }
}

/// A top-level tessdata_best pack and the script it adds to Apple's reader.
struct TesseractLanguage {
    let code: String
    let name: String
    let appleReads: Bool
    let script: Script?

    /// Under the Apple reader, a pack that fills in a script Apple can't read.
    var fillsIn: Bool { !appleReads && script != nil }

    static func fillsIn(_ code: String) -> Bool { all.first { $0.code == code }?.fillsIn == true }

    /// Marks packs for scripts Apple reads; special-purpose packs can opt out.
    private init(_ code: String, _ name: String, script: Script? = nil, appleReads: Bool = true) {
        self.code = code
        self.name = name
        self.script = script
        self.appleReads = script == nil && appleReads
    }

    /// A stable pack URL, pinned to the tessdata_best commit Tools/build_tesseract.sh uses.
    static func downloadURL(_ code: String) -> URL {
        URL(string: "https://github.com/tesseract-ocr/tessdata_best/raw/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/\(code).traineddata")!
    }

    // All 125 top-level packs; no script/ packs.
    static let all: [TesseractLanguage] = [
        .init("afr", "Afrikaans"),
        .init("amh", "Amharic", script: .ethiopic),
        .init("ara", "Arabic"),
        .init("asm", "Assamese", script: .bengali),
        .init("aze", "Azerbaijani"),
        .init("aze_cyrl", "Azerbaijani (Cyrillic)"),
        .init("bel", "Belarusian"),
        .init("ben", "Bengali", script: .bengali),
        .init("bod", "Tibetan", script: .tibetan),
        .init("bos", "Bosnian"),
        .init("bre", "Breton"),
        .init("bul", "Bulgarian"),
        .init("cat", "Catalan"),
        .init("ceb", "Cebuano"),
        .init("ces", "Czech"),
        .init("chi_sim", "Chinese (Simplified)"),
        .init("chi_sim_vert", "Chinese (Simplified, vertical)"),
        .init("chi_tra", "Chinese (Traditional)"),
        .init("chi_tra_vert", "Chinese (Traditional, vertical)"),
        .init("chr", "Cherokee", script: .cherokee),
        .init("cos", "Corsican"),
        .init("cym", "Welsh"),
        .init("dan", "Danish"),
        .init("deu", "German"),
        .init("deu_latf", "German (Fraktur)"),
        .init("div", "Divehi", script: .thaana),
        .init("dzo", "Dzongkha", script: .tibetan),
        .init("ell", "Modern Greek", script: .greek),
        .init("eng", "English"),
        .init("enm", "Middle English"),
        .init("epo", "Esperanto"),
        .init("equ", "Math and equations", appleReads: false),
        .init("est", "Estonian"),
        .init("eus", "Basque"),
        .init("fao", "Faroese"),
        .init("fas", "Persian"),
        .init("fil", "Filipino"),
        .init("fin", "Finnish"),
        .init("fra", "French"),
        .init("frm", "Middle French"),
        .init("fry", "Western Frisian"),
        .init("gla", "Scottish Gaelic"),
        .init("gle", "Irish"),
        .init("glg", "Galician"),
        .init("grc", "Ancient Greek", script: .greek),
        .init("guj", "Gujarati", script: .gujarati),
        .init("hat", "Haitian Creole"),
        .init("heb", "Hebrew", script: .hebrew),
        .init("hin", "Hindi"),
        .init("hrv", "Croatian"),
        .init("hun", "Hungarian"),
        .init("hye", "Armenian", script: .armenian),
        .init("iku", "Inuktitut", script: .canadianAboriginal),
        .init("ind", "Indonesian"),
        .init("isl", "Icelandic"),
        .init("ita", "Italian"),
        .init("ita_old", "Old Italian"),
        .init("jav", "Javanese (Latin)"),
        .init("jpn", "Japanese"),
        .init("jpn_vert", "Japanese (vertical)"),
        .init("kan", "Kannada", script: .kannada),
        .init("kat", "Georgian", script: .georgian),
        .init("kat_old", "Old Georgian", script: .georgian),
        .init("kaz", "Kazakh"),
        .init("khm", "Khmer", script: .khmer),
        .init("kir", "Kyrgyz"),
        .init("kmr", "Kurmanji Kurdish (Latin)"),
        .init("kor", "Korean"),
        .init("kor_vert", "Korean (vertical)"),
        .init("lao", "Lao", script: .lao),
        .init("lat", "Latin"),
        .init("lav", "Latvian"),
        .init("lit", "Lithuanian"),
        .init("ltz", "Luxembourgish"),
        .init("mal", "Malayalam", script: .malayalam),
        .init("mar", "Marathi"),
        .init("mkd", "Macedonian"),
        .init("mlt", "Maltese"),
        .init("mon", "Mongolian (Cyrillic)"),
        .init("mri", "Maori"),
        .init("msa", "Malay"),
        .init("mya", "Burmese", script: .myanmar),
        .init("nep", "Nepali"),
        .init("nld", "Dutch"),
        .init("nor", "Norwegian"),
        .init("oci", "Occitan"),
        .init("ori", "Odia (Oriya)", script: .oriya),
        .init("osd", "Orientation and script detection", appleReads: false),
        .init("pan", "Punjabi", script: .gurmukhi),
        .init("pol", "Polish"),
        .init("por", "Portuguese"),
        .init("pus", "Pashto"),
        .init("que", "Quechua"),
        .init("ron", "Romanian"),
        .init("rus", "Russian"),
        .init("san", "Sanskrit"),
        .init("sin", "Sinhala", script: .sinhala),
        .init("slk", "Slovak"),
        .init("slv", "Slovenian"),
        .init("snd", "Sindhi"),
        .init("spa", "Spanish"),
        .init("spa_old", "Old Spanish"),
        .init("sqi", "Albanian"),
        .init("srp", "Serbian (Cyrillic)"),
        .init("srp_latn", "Serbian (Latin)"),
        .init("sun", "Sundanese (Latin)"),
        .init("swa", "Swahili"),
        .init("swe", "Swedish"),
        .init("syr", "Syriac", script: .syriac),
        .init("tam", "Tamil", script: .tamil),
        .init("tat", "Tatar"),
        .init("tel", "Telugu", script: .telugu),
        .init("tgk", "Tajik"),
        .init("tha", "Thai"),
        .init("tir", "Tigrinya", script: .ethiopic),
        .init("ton", "Tongan"),
        .init("tur", "Turkish"),
        .init("uig", "Uyghur"),
        .init("ukr", "Ukrainian"),
        .init("urd", "Urdu"),
        .init("uzb", "Uzbek (Latin)"),
        .init("uzb_cyrl", "Uzbek (Cyrillic)"),
        .init("vie", "Vietnamese"),
        .init("yid", "Yiddish", script: .hebrew),
        .init("yor", "Yoruba"),
    ]
}
