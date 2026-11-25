import Foundation
import Compression
import CoreGraphics

/// Stores an exported PDF's 1-bit page images as CCITT Group 4 or lossless JBIG2 instead of
/// Flate (Quartz writes only Flate or JPEG), whichever is smallest: every pixel the same.
/// Works on the PDF as Quartz writes it — one classic xref table, plain objects — and leaves any file it
/// doesn't fully understand exactly as it was.
enum PDFCCITT {

    /// Rewrite the file at `url`; true when it changed.
    @discardableResult
    static func recompress(at url: URL, jbig2: Bool = PDFExporter.storesJBIG2) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let plan = plan(data, jbig2: jbig2) , !plan.replacements.isEmpty else { return false }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".ccitt-\(UUID().uuidString)-" + url.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard write(data, plan, to: tmp),
              let before = CGPDFDocument(url as CFURL), let after = CGPDFDocument(tmp as CFURL),
              before.numberOfPages == after.numberOfPages,
              (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil else { return false }
        return true
    }

    // MARK: Reading

    private struct Object { var number: Int; var offset: Int; var end: Int }
    private struct Plan {
        var objects: [Object]           // in-use objects, in file order
        var entries: [String]           // xref entries as written, by object number
        var xrefOffset: Int
        var trailer: Data               // from "trailer" up to "startxref"
        var replacements: [Int: Data]   // object number → the whole new object
        var jbig2 = false               // some image is now JBIG2, a PDF 1.4 filter
    }

    private static func plan(_ d: Data, jbig2: Bool) -> Plan? {
        let bytes = [UInt8](d.suffix(64))
        guard let tail = String(bytes: bytes, encoding: .isoLatin1),
              let r = tail.range(of: "startxref", options: .backwards) else { return nil }
        let digits = tail[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0.isNumber }
        guard let xref = Int(digits), xref > 0, xref < d.count else { return nil }
        // The xref table: "xref", one subsection "0 N", N entries of 20 bytes.
        guard let head = text(d, xref, min(d.count, xref + 64)), head.hasPrefix("xref") else { return nil }
        var pos = xref + 4
        while pos < d.count, isSpace(d[d.startIndex + pos]) { pos += 1 }
        guard let line = text(d, pos, min(d.count, pos + 32)),
              let nl = line.firstIndex(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
        let sub = line[..<nl].split(separator: " ")
        guard sub.count == 2, sub[0] == "0", let count = Int(sub[1]), count > 0 else { return nil }
        pos += line.distance(from: line.startIndex, to: nl)
        while pos < d.count, d[d.startIndex + pos] == 0x0A || d[d.startIndex + pos] == 0x0D { pos += 1 }
        var entries: [String] = []
        var objects: [Object] = []
        for k in 0..<count {
            guard pos + 20 <= d.count, let e = text(d, pos, pos + 20) else { return nil }
            let f = e.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, f[0].count == 10, f[1].count == 5, let off = Int(f[0]) else { return nil }
            entries.append(String(e.prefix(18)))
            if f[2].hasPrefix("n") {
                guard off > 0, off < xref else { return nil }
                objects.append(Object(number: k, offset: off, end: 0))
            }
            pos += 20
        }
        guard let rest = text(d, pos, d.count), rest.hasPrefix("trailer"),
              let sx = rest.range(of: "startxref", options: .backwards) else { return nil }
        let trailer = d.subdata(in: d.startIndex + pos ..< d.startIndex + pos + rest.utf8.distance(from: rest.startIndex, to: sx.lowerBound))
        guard !String(decoding: trailer, as: UTF8.self).contains("/Prev") else { return nil }
        objects.sort { $0.offset < $1.offset }
        for i in objects.indices { objects[i].end = i + 1 < objects.count ? objects[i + 1].offset : xref }
        var plan = Plan(objects: objects, entries: entries, xrefOffset: xref, trailer: trailer, replacements: [:])
        let byNumber = Dictionary(uniqueKeysWithValues: objects.map { ($0.number, $0) })
        // Each image on its own: they share only the read-only file.
        var made = [Data?](repeating: nil, count: objects.count)
        made.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: objects.count) { i in
                autoreleasepool { out[i] = recoded(d, objects[i], byNumber, jbig2: jbig2) }
            }
        }
        for (i, o) in objects.enumerated() {
            guard let new = made[i] else { continue }
            plan.replacements[o.number] = new
            if new.prefix(1024).range(of: Data("/JBIG2Decode".utf8)) != nil { plan.jbig2 = true }
        }
        return plan
    }

    /// The object as CCITT G4 or JBIG2, when it is a 1-bit Flate image that comes out smaller.
    private static func recoded(_ d: Data, _ o: Object, _ objects: [Int: Object], jbig2: Bool) -> Data? {
        // Header and dictionary: up to the stream keyword.
        let scan = min(o.end, o.offset + 2048)
        guard let start = text(d, o.offset, scan), start.contains("/Image"),
              let s = start.range(of: "stream") else { return nil }
        let header = start[..<s.lowerBound]
        guard let objKey = header.range(of: " obj"),
              header[..<objKey.lowerBound].split(separator: " ").first.flatMap({ Int($0) }) == o.number,
              let open = header.range(of: "<<"), let close = header.range(of: ">>", options: .backwards),
              open.lowerBound < close.lowerBound else { return nil }
        let dict = String(header[open.upperBound..<close.lowerBound])
        guard header[close.upperBound...].allSatisfy({ $0.isWhitespace }),
              !dict.contains("<<"), !dict.contains("["), !dict.contains("("),
              value(dict, "Subtype") == "/Image", value(dict, "BitsPerComponent") == "1",
              value(dict, "Filter") == "/FlateDecode",
              value(dict, "ImageMask").map({ $0 == "false" }) ?? true,
              value(dict, "DecodeParms") == nil, value(dict, "Decode") == nil,
              value(dict, "SMask") == nil, value(dict, "Mask") == nil,
              let w = value(dict, "Width").flatMap({ Int($0) }), let h = value(dict, "Height").flatMap({ Int($0) }),
              w > 0, h > 0, let lengthText = value(dict, "Length") else { return nil }
        var length: Int?
        if let n = Int(lengthText) { length = n }
        else if lengthText.hasSuffix(" R"), let ref = Int(lengthText.split(separator: " ")[0]),
                let lo = objects[ref], let body = text(d, lo.offset, min(lo.end, lo.offset + 64)),
                let r = body.range(of: "obj") {
            length = Int(body[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix { $0.isNumber })
        }
        // The stream's bytes: after "stream" and its end of line.
        var dataStart = o.offset + start.utf8.distance(from: start.startIndex, to: s.upperBound)
        if dataStart < o.end, d[d.startIndex + dataStart] == 0x0D { dataStart += 1 }
        guard dataStart < o.end, d[d.startIndex + dataStart] == 0x0A else { return nil }
        dataStart += 1
        guard let length, length > 2, dataStart + length <= o.end,
              let after = text(d, dataStart + length, min(o.end, dataStart + length + 16)),
              after.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("endstream") else { return nil }
        // Inflate: a zlib header, then raw deflate.
        let rowBytes = (w + 7) / 8
        let expected = rowBytes * h
        guard d[d.startIndex + dataStart] & 0x0F == 8 else { return nil }
        var raw = [UInt8](repeating: 0, count: expected + 1)
        let got = d.withUnsafeBytes { src -> Int in
            let p = src.baseAddress!.advanced(by: dataStart + 2).assumingMemoryBound(to: UInt8.self)
            return compression_decode_buffer(&raw, raw.count, p, length - 2, nil, COMPRESSION_ZLIB)
        }
        guard got == expected else { return nil }
        // The smallest of the stream as it is, Group 4 and JBIG2.
        var best: (bytes: Data, filter: String)?
        let g4 = raw.withUnsafeBytes { CCITTG4.encode($0, width: w, height: h, rowBytes: rowBytes) }
        if !g4.isEmpty, g4.count < length {
            best = (g4, "/Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns \(w) /Rows \(h) /BlackIs1 false >>")
        }
        if jbig2 {
            // JBIG2 1 is black, read through DeviceGray as 0: no /Decode needed.
            let jb = raw.withUnsafeBytes { JBIG2Generic.encode($0, width: w, height: h, rowBytes: rowBytes) }
            if !jb.isEmpty, jb.count < (best?.bytes.count ?? length) { best = (jb, "/Filter /JBIG2Decode") }
        }
        guard let best else { return nil }
        // The dictionary as written, its filter and length replaced.
        var kept = dict
        for key in ["Filter", "Length"] { kept = removing(kept, key) }
        let newDict = kept.trimmingCharacters(in: .whitespacesAndNewlines) + " \(best.filter) /Length \(best.bytes.count)"
        var out = Data("\(o.number) 0 obj\n<< \(newDict) >>\nstream\n".utf8)
        out.append(best.bytes)
        out.append(Data("\nendstream\nendobj\n".utf8))
        return out
    }

    /// The text of a key's value in a flat dictionary (`/Key value /Next …`): a name, a
    /// number, `true`/`false`, or `n g R`. Nil when absent.
    private static func value(_ dict: String, _ key: String) -> String? {
        let tokens = tokenize(dict)
        guard let i = tokens.firstIndex(of: "/" + key), i + 1 < tokens.count else { return nil }
        if i + 3 < tokens.count, tokens[i + 3] == "R", Int(tokens[i + 1]) != nil, Int(tokens[i + 2]) != nil {
            return tokens[i + 1...i + 3].joined(separator: " ")
        }
        return tokens[i + 1]
    }

    private static func removing(_ dict: String, _ key: String) -> String {
        var tokens = tokenize(dict)
        guard let i = tokens.firstIndex(of: "/" + key), i + 1 < tokens.count else { return dict }
        let isRef = i + 3 < tokens.count && tokens[i + 3] == "R"
        tokens.removeSubrange(i...(isRef ? i + 3 : i + 1))
        return tokens.joined(separator: " ")
    }

    /// Names, numbers and words of a flat dictionary; a name ends where the next begins.
    private static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in s {
            if ch.isWhitespace { if !cur.isEmpty { out.append(cur); cur = "" }; continue }
            if ch == "/" , !cur.isEmpty { out.append(cur); cur = "" }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func text(_ d: Data, _ from: Int, _ to: Int) -> String? {
        guard from >= 0, to <= d.count, from <= to else { return nil }
        return String(data: d.subdata(in: d.startIndex + from ..< d.startIndex + to), encoding: .isoLatin1)
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }

    // MARK: Writing

    /// A byte offset as the xref table's ten digits; nil past what ten digits hold.
    static func offsetField(_ offset: Int) -> String? {
        let digits = String(offset)
        guard offset >= 0, digits.count <= 10 else { return nil }
        return String(repeating: "0", count: 10 - digits.count) + digits
    }

    private static func write(_ d: Data, _ plan: Plan, to url: URL) -> Bool {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let out = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? out.close() }
        var offsets = plan.entries.map { _ in -1 }
        var written = 0
        func put(_ chunk: Data) throws { try out.write(contentsOf: chunk); written += chunk.count }
        do {
            let first = plan.objects.first?.offset ?? plan.xrefOffset
            var head = d.subdata(in: d.startIndex ..< d.startIndex + first)
            // Quartz writes 1.3; JBIG2 needs 1.4, the same length.
            let v13 = Data("%PDF-1.3".utf8)
            if plan.jbig2, head.starts(with: v13) { head.replaceSubrange(0..<v13.count, with: Data("%PDF-1.4".utf8)) }
            try put(head)
            for o in plan.objects {
                offsets[o.number] = written
                if let new = plan.replacements[o.number] {
                    try put(new)
                } else {
                    try put(d.subdata(in: d.startIndex + o.offset ..< d.startIndex + o.end))
                }
            }
            let xref = written
            var table = "xref\n0 \(plan.entries.count)\n"
            for (k, e) in plan.entries.enumerated() {
                if offsets[k] >= 0 {
                    guard let field = offsetField(offsets[k]) else { return false }
                    table += field + e.dropFirst(10) + " \n"
                }
                else { table += e + " \n" }
            }
            try put(Data(table.utf8))
            try put(plan.trailer)
            try put(Data("startxref\n\(xref)\n%%EOF\n".utf8))
            return true
        } catch {
            return false
        }
    }
}
