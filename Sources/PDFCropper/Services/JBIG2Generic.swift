import Foundation

/// Lossless JBIG2 (ITU-T T.88) of a 1-bit page, as a PDF reads it with `/Filter /JBIG2Decode`
/// and no globals: a page information segment, one immediate generic region (arithmetic
/// coded, template 0 with its nominal AT pixels, typical prediction on); no end of page
/// segment, which poppler doesn't know and the page's height makes needless. No symbol
/// coding, so every pixel stays as it was; for print, smaller than Group 4.
enum JBIG2Generic {

    /// `rows`: packed 1-bit rows, most significant bit first, 1 white and 0 black (as
    /// `CCITTG4.encode` takes them); padding bits at a row's end are ignored. Empty on bad input.
    static func encode(_ rows: UnsafeRawBufferPointer, width: Int, height: Int, rowBytes: Int,
                       typicalPrediction: Bool = true) -> Data {
        guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max),
              rowBytes >= (width + 7) / 8, rows.count >= rowBytes * height else { return Data() }
        let coded = region(rows, width: width, height: height, rowBytes: rowBytes, tpgd: typicalPrediction)
        var out = Data()
        // Page information: size, unknown resolution, eventually lossless, not striped.
        var page = Data()
        page.be32(width); page.be32(height); page.be32(0); page.be32(0)
        page.append(0x01); page.append(contentsOf: [0, 0])
        out.segment(number: 0, type: 48, page)
        // Immediate generic region: the whole page, combined by OR.
        var region = Data()
        region.be32(width); region.be32(height); region.be32(0); region.be32(0)
        region.append(0)
        region.append(typicalPrediction ? 0x08 : 0x00)             // MMR 0, template 0
        region.append(contentsOf: [3, 0xFF, 0xFD, 0xFF, 2, 0xFE, 0xFE, 0xFE])  // AT (3,-1) (-3,-1) (2,-2) (-2,-2)
        region.append(contentsOf: coded)
        out.segment(number: 1, type: 38, region)
        return out
    }

    // MARK: Generic region (T.88 6.2, coded rather than decoded)

    private static func region(_ rows: UnsafeRawBufferPointer, width: Int, height: Int, rowBytes: Int,
                               tpgd: Bool) -> [UInt8] {
        let n = (width + 7) / 8
        let stride = n + 2      // a zero byte past the row for the look-ahead pixels
        // Rows as JBIG2 holds them: 1 black, padding 0; two blank rows above the first.
        let img = UnsafeMutablePointer<UInt8>.allocate(capacity: stride * (height + 2))
        img.initialize(repeating: 0, count: stride * (height + 2))
        defer { img.deallocate() }
        let padMask: UInt8 = width % 8 == 0 ? 0xFF : ~(0xFF >> UInt8(width % 8))
        for y in 0..<height {
            let src = y * rowBytes, dst = img + (y + 2) * stride
            for i in 0..<n { dst[i] = ~rows[src + i] }
            dst[n - 1] &= padMask
        }
        let s = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        s.initialize(repeating: 0, count: 65536)
        defer { s.deallocate() }
        var coder = MQEncoder(capacity: n * height / 8 + 64)
        var ltp = false
        for y in 0..<height {
            let cur = img + (y + 2) * stride
            let r1 = cur - stride, r2 = r1 - stride
            if tpgd {
                // A row the same as the one above is coded as one bit.
                let typical = memcmp(cur, r1, n) == 0
                coder.encode(s + 0x9B25, typical != ltp ? 1 : 0)
                ltp = typical
                if typical { continue }
            }
            // The context: row y-2 pixels x-2…x+2 in bits 15…11, y-1 x-3…x+3 in 10…4,
            // y x-4…x-1 in 3…0. Each step shifts all three left and brings in one pixel each.
            var cx = UInt32(r2[0] >> 5) << 11 | UInt32(r1[0] >> 4) << 4
            for k in 0..<n {
                let c = UInt32(cur[k])
                let v1 = UInt32(r1[k]) << 8 | UInt32(r1[k + 1])
                let v2 = UInt32(r2[k]) << 8 | UInt32(r2[k + 1])
                let count = UInt32(min(8, width - k * 8))
                var j: UInt32 = 0
                while j < count {
                    let pixel = (c >> (7 - j)) & 1
                    coder.encode(s + Int(cx), pixel)
                    cx = (cx << 1) & 0xF7EE | ((v2 >> (12 - j)) & 1) << 11 | ((v1 >> (11 - j)) & 1) << 4 | pixel
                    j += 1
                }
            }
        }
        return coder.flush()
    }

    // MARK: MQ coder (T.88 Annex E)

    /// One entry per context state `index << 1 | mps`: its Qe and the states after an MPS and an LPS.
    nonisolated(unsafe) private static let table: UnsafePointer<UInt32> = {
        let rows: [(UInt32, Int, Int, Int)] = [
            (0x5601, 1, 1, 1), (0x3401, 2, 6, 0), (0x1801, 3, 9, 0), (0x0AC1, 4, 12, 0),
            (0x0521, 5, 29, 0), (0x0221, 38, 33, 0), (0x5601, 7, 6, 1), (0x5401, 8, 14, 0),
            (0x4801, 9, 14, 0), (0x3801, 10, 14, 0), (0x3001, 11, 17, 0), (0x2401, 12, 18, 0),
            (0x1C01, 13, 20, 0), (0x1601, 29, 21, 0), (0x5601, 15, 14, 1), (0x5401, 16, 14, 0),
            (0x5101, 17, 15, 0), (0x4801, 18, 16, 0), (0x3801, 19, 17, 0), (0x3401, 20, 18, 0),
            (0x3001, 21, 19, 0), (0x2801, 22, 19, 0), (0x2401, 23, 20, 0), (0x2201, 24, 21, 0),
            (0x1C01, 25, 22, 0), (0x1801, 26, 23, 0), (0x1601, 27, 24, 0), (0x1401, 28, 25, 0),
            (0x1201, 29, 26, 0), (0x1101, 30, 27, 0), (0x0AC1, 31, 28, 0), (0x09C1, 32, 29, 0),
            (0x08A1, 33, 30, 0), (0x0521, 34, 31, 0), (0x0441, 35, 32, 0), (0x02A1, 36, 33, 0),
            (0x0221, 37, 34, 0), (0x0141, 38, 35, 0), (0x0111, 39, 36, 0), (0x0085, 40, 37, 0),
            (0x0049, 41, 38, 0), (0x0025, 42, 39, 0), (0x0015, 43, 40, 0), (0x0009, 44, 41, 0),
            (0x0005, 45, 42, 0), (0x0001, 45, 43, 0), (0x5601, 46, 46, 0),
        ]
        // Packed: Qe in the low 16 bits, the next state after an MPS above, after an LPS on top.
        let t = UnsafeMutablePointer<UInt32>.allocate(capacity: 2 * rows.count)
        for (i, (qe, nmps, nlps, sw)) in rows.enumerated() {
            for mps in 0...1 {
                t[2 * i + mps] = qe | UInt32(nmps << 1 | mps) << 16 | UInt32(nlps << 1 | (mps ^ sw)) << 24
            }
        }
        return UnsafePointer(t)     // kept for the life of the app
    }()

    private struct MQEncoder {
        var out: [UInt8] = []
        var a: UInt32 = 0x8000, c: UInt32 = 0, ct: UInt32 = 12, b: UInt32 = 0
        var started = false
        let t = JBIG2Generic.table

        init(capacity: Int) { out.reserveCapacity(capacity) }

        @inline(__always) mutating func encode(_ cx: UnsafeMutablePointer<UInt8>, _ bit: UInt32) {
            let s = Int(cx.pointee)
            let e = t[s]
            let q = e & 0xFFFF
            a &-= q
            if bit == UInt32(s & 1) {
                if a & 0x8000 != 0 { c &+= q; return }
                if a < q { a = q } else { c &+= q }
                cx.pointee = UInt8(truncatingIfNeeded: e >> 16)
            } else {
                if a < q { c &+= q } else { a = q }
                cx.pointee = UInt8(truncatingIfNeeded: e >> 24)
            }
            // Shift until A's top bit is set, a byte out each time CT runs down.
            var n = UInt32(a.leadingZeroBitCount - 16)
            while n >= ct {
                a <<= ct; c <<= ct; n -= ct
                byteOut()
            }
            a <<= n; c <<= n; ct -= n
        }

        private mutating func emit() { if started { out.append(UInt8(truncatingIfNeeded: b)) }; started = true }

        @inline(never) private mutating func byteOut() {
            if b == 0xFF {
                emit(); b = c >> 20; c &= 0xFFFFF; ct = 7
                return
            }
            if c >= 0x8000000 {
                b += 1
                if b == 0xFF {
                    c &= 0x7FFFFFF
                    emit(); b = c >> 20; c &= 0xFFFFF; ct = 7
                    return
                }
            }
            emit(); b = c >> 19; c &= 0x7FFFF; ct = 8
        }

        /// The coded bytes, ended with the 0xFF 0xAC marker.
        mutating func flush() -> [UInt8] {
            let temp = c &+ a
            c |= 0xFFFF
            if c >= temp { c -= 0x8000 }
            c <<= ct; byteOut()
            c <<= ct; byteOut()
            emit()
            if b != 0xFF { out.append(0xFF) }
            out.append(0xAC)
            return out
        }
    }
}

private extension Data {
    mutating func be32(_ v: Int) {
        let u = UInt32(truncatingIfNeeded: v)
        append(contentsOf: [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
    }

    /// A segment header (T.88 7.2: no referred-to segments, page 1) and its data.
    mutating func segment(number: Int, type: UInt8, _ data: Data) {
        be32(number)
        append(type)            // one-byte page association, retained
        append(0)               // no referred-to segments
        append(1)               // page 1
        be32(data.count)
        append(data)
    }
}
