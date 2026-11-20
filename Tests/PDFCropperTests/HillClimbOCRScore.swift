import Foundation
@testable import PDFCropper

/// Scoring of an OCR text layer against known truth. See Tools/hillclimb/ocr/README.md.
enum HCScore {

    /// Text as compared: NFC, one kind of quote, dash and apostrophe, no ligature or
    /// superscript digits, whitespace collapsed. `joinHyphens` also joins a word the
    /// reader split at a line end ("exam-" / "ple"): the truth holds such words whole.
    static func normalize(_ raw: String, joinHyphens: Bool = false) -> String {
        var s = raw.precomposedStringWithCanonicalMapping
        if joinHyphens {
            s = s.replacingOccurrences(of: "(\\p{L})[-\u{2010}\u{00AD}][ \\t]*\\r?\\n[ \\t]*(?=\\p{Ll})",
                                       with: "$1", options: .regularExpression)
        }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x2018, 0x2019, 0x201B, 0x02BC, 0x1FBD, 0x1FBF, 0x2032, 0x0060, 0x00B4: out.append("'")
            case 0x201C, 0x201D, 0x201E, 0x00AB, 0x00BB: out.append("\"")
            case 0x2010...0x2015, 0x2212: out.append("-")
            case 0x00AD, 0x200B, 0xFEFF: break
            case 0x00B9: out.append("1")
            case 0x00B2: out.append("2")
            case 0x00B3: out.append("3")
            case 0xFB00: out.append("f"); out.append("f")
            case 0xFB01: out.append("f"); out.append("i")
            case 0xFB02: out.append("f"); out.append("l")
            case 0x0387: out.append("\u{00B7}")
            case 0x037E: out.append(";")
            default: out.append(u)
            }
        }
        let words = String(out).precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return words.joined(separator: " ")
    }

    /// Levenshtein distance (insert, delete, substitute), two rows.
    static func distance(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let n = b.count
        var p = UnsafeMutablePointer<Int32>.allocate(capacity: n + 1)
        var c = UnsafeMutablePointer<Int32>.allocate(capacity: n + 1)
        defer { p.deallocate(); c.deallocate() }
        for j in 0...n { p[j] = Int32(j) }
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for i in 1...pa.count {
                    c[0] = Int32(i)
                    let ai = pa[i - 1]
                    for j in 1...n {
                        let cost: Int32 = ai == pb[j - 1] ? 0 : 1
                        c[j] = min(p[j] &+ 1, c[j &- 1] &+ 1, p[j &- 1] &+ cost)
                    }
                    swap(&p, &c)
                }
            }
        }
        return Int(p[n])
    }

    static func scalars(_ s: String, where keep: (Unicode.Scalar) -> Bool = { _ in true }) -> [UInt32] {
        s.unicodeScalars.filter(keep).map(\.value)
    }

    static func isGreek(_ u: Unicode.Scalar) -> Bool { Script.greek.contains(u) }

    static func isLatin(_ u: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value)
            || ((0xC0...0x24F).contains(u.value) && u.value != 0xD7 && u.value != 0xF7)
    }

    /// Errors and truth size for one measure: edits / truth count is its error rate.
    struct Part: Codable {
        var edits = 0
        var length = 0
        var rate: Double? { length > 0 ? Double(edits) / Double(length) : nil }
        static func + (a: Part, b: Part) -> Part { Part(edits: a.edits + b.edits, length: a.length + b.length) }
    }

    struct Page {
        var char = Part()
        var word = Part()
        var greek = Part()
        var latin = Part()
        /// Truth chunks (three words each) found whole in the reading, and how many of
        /// those sit in the truth's own order (longest increasing run).
        var chunks = 0
        var found = 0
        var inOrder = 0
    }

    static func score(truth: String, reading: String) -> Page {
        let t = normalize(truth)
        let r = normalize(reading, joinHyphens: true)
        var page = Page()
        page.char = Part(edits: distance(scalars(t), scalars(r)), length: t.unicodeScalars.count)
        let tw = t.split(separator: " ").map(String.init), rw = r.split(separator: " ").map(String.init)
        var ids: [String: UInt32] = [:]
        func id(_ w: String) -> UInt32 {
            if let i = ids[w] { return i }
            let n = UInt32(ids.count); ids[w] = n; return n
        }
        page.word = Part(edits: distance(tw.map(id), rw.map(id)), length: tw.count)
        for (keep, set) in [(isGreek, \Page.greek), (isLatin, \Page.latin)] as [((Unicode.Scalar) -> Bool, WritableKeyPath<Page, Part>)] {
            let a = scalars(t, where: keep)
            guard !a.isEmpty else { continue }
            page[keyPath: set] = Part(edits: distance(a, scalars(r, where: keep)), length: a.count)
        }
        (page.chunks, page.found, page.inOrder) = order(truth: tw, reading: rw)
        return page
    }

    /// Reading order. Words are cut to lowercase letters and digits. The truth is
    /// split into chunks of three words. A chunk is found when the reading has the same
    /// three words in a row; its place is that first match. Among found chunks, the
    /// longest run whose places rise in truth order is the in-order count, so a column
    /// read before the one beside it, or a footnote read among the body, lowers it.
    static func order(truth: [String], reading: [String]) -> (chunks: Int, found: Int, inOrder: Int) {
        func clean(_ words: [String]) -> [String] {
            words.map { String($0.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
                .filter { !$0.isEmpty }
        }
        let t = clean(truth), r = clean(reading)
        var first: [String: Int] = [:]
        if r.count >= 3 {
            for i in 0...(r.count - 3) {
                let key = r[i...(i + 2)].joined(separator: "|")
                if first[key] == nil { first[key] = i }
            }
        }
        var places: [Int] = [], chunks = 0
        var i = 0
        while i + 3 <= t.count {
            chunks += 1
            if let at = first[t[i...(i + 2)].joined(separator: "|")] { places.append(at) }
            i += 3
        }
        var best = [Int](repeating: 1, count: places.count)
        for a in places.indices {
            for b in 0..<a where places[b] < places[a] { best[a] = max(best[a], best[b] + 1) }
        }
        return (chunks, places.count, best.max() ?? 0)
    }
}
