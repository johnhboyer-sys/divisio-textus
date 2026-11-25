import Foundation

/// CCITT Group 4 (ITU-T T.6) coding of a 1-bit page, as a PDF reads it with
/// `/CCITTFaxDecode` and `/DecodeParms << /K -1 /Columns w /Rows h /BlackIs1 false >>`.
/// Lossless; for print on paper about half the size of Flate. The coding follows libtiff's
/// `Fax3Encode2DRow`.
enum CCITTG4 {

    /// `rows`: packed 1-bit rows, most significant bit first, 1 white and 0 black (as
    /// `PDFExporter.blackAndWhiteBits` makes them); padding bits at a row's end are ignored.
    static func encode(_ rows: UnsafeRawBufferPointer, width: Int, height: Int, rowBytes: Int) -> Data {
        var out = BitWriter()
        guard width > 0, height > 0, rowBytes >= (width + 7) / 8, rows.count >= rowBytes * height else {
            return Data()
        }
        let n = (width + 7) / 8
        // Rows as libtiff holds them: 1 black, padding white (0).
        var ref = [UInt8](repeating: 0, count: n)
        var cur = [UInt8](repeating: 0, count: n)
        let padMask: UInt8 = width % 8 == 0 ? 0xFF : ~(0xFF >> UInt8(width % 8))
        for y in 0..<height {
            let base = y * rowBytes
            for i in 0..<n { cur[i] = ~rows[base + i] }
            cur[n - 1] &= padMask
            cur.withUnsafeBufferPointer { c in
                ref.withUnsafeBufferPointer { r in encodeRow(c, r, width, &out) }
            }
            swap(&ref, &cur)
        }
        // EOFB: two EOLs.
        out.put(0x001, 12)
        out.put(0x001, 12)
        return out.finish()
    }

    // MARK: One row

    private static func pixel(_ row: UnsafeBufferPointer<UInt8>, _ x: Int) -> Int {
        Int(row[x >> 3] >> UInt8(7 - (x & 7))) & 1
    }

    /// The first position at or after `start` (before `end`) whose pixel is not `color`; `end` if none.
    private static func findDiff(_ row: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ color: Int) -> Int {
        var x = start
        guard x < end else { return end }
        let skip: UInt8 = color == 1 ? 0xFF : 0x00
        // Bit by bit to a byte boundary.
        while x < end, x & 7 != 0 {
            if pixel(row, x) != color { return x }
            x += 1
        }
        // Whole bytes of `color`.
        while x + 8 <= end, row[x >> 3] == skip { x += 8 }
        // The byte holding the change.
        while x < end {
            if x & 7 == 0, x + 8 <= end {
                let b = color == 1 ? ~row[x >> 3] : row[x >> 3]
                if b == 0 { x += 8; continue }
                return x + b.leadingZeroBitCount
            }
            if pixel(row, x) != color { return x }
            x += 1
        }
        return end
    }

    private static func encodeRow(_ cur: UnsafeBufferPointer<UInt8>, _ ref: UnsafeBufferPointer<UInt8>,
                                  _ bits: Int, _ out: inout BitWriter) {
        var a0 = 0
        var a1 = pixel(cur, 0) != 0 ? 0 : findDiff(cur, 0, bits, 0)
        var b1 = pixel(ref, 0) != 0 ? 0 : findDiff(ref, 0, bits, 0)
        while true {
            let b2 = b1 >= bits ? bits : findDiff(ref, b1, bits, pixel(ref, b1))
            if b2 >= a1 {
                let d = b1 - a1
                if d < -3 || d > 3 {
                    // Horizontal mode.
                    let a2 = a1 >= bits ? bits : findDiff(cur, a1, bits, pixel(cur, a1))
                    out.put(0b001, 3)
                    if a0 + a1 == 0 || pixel(cur, a0) == 0 {
                        putSpan(a1 - a0, white: true, &out)
                        putSpan(a2 - a1, white: false, &out)
                    } else {
                        putSpan(a1 - a0, white: false, &out)
                        putSpan(a2 - a1, white: true, &out)
                    }
                    a0 = a2
                } else {
                    // Vertical mode, d = b1 - a1.
                    let code = vertical[d + 3]
                    out.put(code.bits, code.length)
                    a0 = a1
                }
            } else {
                out.put(0b0001, 4)      // pass mode
                a0 = b2
            }
            if a0 >= bits { break }
            let color = pixel(cur, a0)
            a1 = findDiff(cur, a0, bits, color)
            b1 = findDiff(ref, a0, bits, 1 - color)
            b1 = findDiff(ref, b1, bits, color)
        }
    }

    /// d = b1 - a1 from -3 to 3: VR3, VR2, VR1, V0, VL1, VL2, VL3.
    private static let vertical: [(bits: UInt32, length: Int)] = [
        (0b0000011, 7), (0b000011, 6), (0b011, 3), (0b1, 1), (0b010, 3), (0b000010, 6), (0b0000010, 7),
    ]

    private static func putSpan(_ run: Int, white: Bool, _ out: inout BitWriter) {
        var r = run
        while r >= 2560 {
            put(ext[(2560 - 1792) / 64], &out)
            r -= 2560
        }
        if r >= 64 {
            let m = r / 64 * 64
            if m >= 1792 { put(ext[(m - 1792) / 64], &out) }
            else { put((white ? wM : bM)[m / 64 - 1], &out) }
            r -= m
        }
        put((white ? wT : bT)[r], &out)
    }

    private typealias Code = (bits: UInt32, length: Int)
    private static func put(_ code: Code, _ out: inout BitWriter) { out.put(code.bits, code.length) }
    private static func codes(_ list: [String]) -> [Code] { list.map { (UInt32($0, radix: 2)!, $0.count) } }
    private static let wT = codes(whiteTerminating), wM = codes(whiteMakeup)
    private static let bT = codes(blackTerminating), bM = codes(blackMakeup), ext = codes(extended)

    // MARK: Code tables (ITU-T T.4)

    private static let whiteTerminating = [
        "00110101", "000111", "0111", "1000", "1011", "1100", "1110", "1111",
        "10011", "10100", "00111", "01000", "001000", "000011", "110100", "110101",
        "101010", "101011", "0100111", "0001100", "0001000", "0010111", "0000011", "0000100",
        "0101000", "0101011", "0010011", "0100100", "0011000", "00000010", "00000011", "00011010",
        "00011011", "00010010", "00010011", "00010100", "00010101", "00010110", "00010111", "00101000",
        "00101001", "00101010", "00101011", "00101100", "00101101", "00000100", "00000101", "00001010",
        "00001011", "01010010", "01010011", "01010100", "01010101", "00100100", "00100101", "01011000",
        "01011001", "01011010", "01011011", "01001010", "01001011", "00110010", "00110011", "00110100",
    ]
    /// 64, 128, … 1728.
    private static let whiteMakeup = [
        "11011", "10010", "010111", "0110111", "00110110", "00110111", "01100100", "01100101",
        "01101000", "01100111", "011001100", "011001101", "011010010", "011010011", "011010100", "011010101",
        "011010110", "011010111", "011011000", "011011001", "011011010", "011011011", "010011000", "010011001",
        "010011010", "011000", "010011011",
    ]
    private static let blackTerminating = [
        "0000110111", "010", "11", "10", "011", "0011", "0010", "00011",
        "000101", "000100", "0000100", "0000101", "0000111", "00000100", "00000111", "000011000",
        "0000010111", "0000011000", "0000001000", "00001100111", "00001101000", "00001101100", "00000110111", "00000101000",
        "00000010111", "00000011000", "000011001010", "000011001011", "000011001100", "000011001101", "000001101000", "000001101001",
        "000001101010", "000001101011", "000011010010", "000011010011", "000011010100", "000011010101", "000011010110", "000011010111",
        "000001101100", "000001101101", "000011011010", "000011011011", "000001010100", "000001010101", "000001010110", "000001010111",
        "000001100100", "000001100101", "000001010010", "000001010011", "000000100100", "000000110111", "000000111000", "000000100111",
        "000000101000", "000001011000", "000001011001", "000000101011", "000000101100", "000001011010", "000001100110", "000001100111",
    ]
    /// 64, 128, … 1728.
    private static let blackMakeup = [
        "0000001111", "000011001000", "000011001001", "000001011011", "000000110011", "000000110100", "000000110101", "0000001101100",
        "0000001101101", "0000001001010", "0000001001011", "0000001001100", "0000001001101", "0000001110010", "0000001110011", "0000001110100",
        "0000001110101", "0000001110110", "0000001110111", "0000001010010", "0000001010011", "0000001010100", "0000001010101", "0000001011010",
        "0000001011011", "0000001100100", "0000001100101",
    ]
    /// 1792, 1856, … 2560, either colour.
    private static let extended = [
        "00000001000", "00000001100", "00000001101", "000000010010", "000000010011", "000000010100", "000000010101",
        "000000010110", "000000010111", "000000011100", "000000011101", "000000011110", "000000011111",
    ]

    // MARK: Bits

    private struct BitWriter {
        var bytes: [UInt8] = []
        var acc: UInt64 = 0
        var count = 0

        mutating func put(_ code: UInt32, _ length: Int) {
            acc = (acc << UInt64(length)) | UInt64(code & ((1 << UInt32(length)) - 1))
            count += length
            while count >= 8 {
                count -= 8
                bytes.append(UInt8(truncatingIfNeeded: acc >> UInt64(count)))
            }
            acc &= (1 << UInt64(count)) - 1
        }

        mutating func finish() -> Data {
            if count > 0 { bytes.append(UInt8(truncatingIfNeeded: acc << UInt64(8 - count))) }
            count = 0; acc = 0
            return Data(bytes)
        }
    }
}
