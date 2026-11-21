import Foundation

/// A baseline JPEG writer for the pictures of a shared note (`WebPageShare`): YCbCr 4:2:0, the standard
/// quantization tables scaled by quality, and Huffman tables built for the image (optimal, at most 16 bits).
/// It writes only the pixels: no EXIF, no comments, no color profile, so a re-encoded picture carries none of
/// the original's metadata (location, camera). Pure Swift, so it runs on Linux and in the app alike.
enum JPEGEncoder {
    /// `image` as a JFIF file. Transparent pixels are composited over white.
    ///
    /// - Parameter quality: 1...100 (libjpeg's scale).
    static func encode(_ image: RGBAImage, quality: Int) -> Data {
        var enc = Encoder(image: image, quality: min(max(quality, 1), 100))
        return enc.run()
    }

    private static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21,
        28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61,
        54, 47, 55, 62, 63,
    ]
    private static let lumaBase: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51,
        87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
    ]
    private static let chromaBase: [Int] = [
        17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99,
    ]
    /// cos((2x + 1) u π / 16), scaled by the DCT's normalization, `[u][x]`.
    private static let dct: [Double] = {
        var t = [Double](repeating: 0, count: 64)
        for u in 0..<8 {
            let c = u == 0 ? (1.0 / 2.0.squareRoot()) : 1.0
            // Rounded to 10 digits so that a libm that differs in the last bit writes the same file (the shared fixtures).
            for x in 0..<8 { t[u * 8 + x] = (0.5 * c * cos(Double(2 * x + 1) * Double(u) * Double.pi / 16) * 1e10).rounded() / 1e10 }
        }
        return t
    }()

    /// A Huffman table: canonical codes from per-length counts and symbols (JPEG Annex C).
    private struct Table {
        var counts = [Int](repeating: 0, count: 17)   // index 1...16
        var symbols: [Int] = []
        var code = [Int](repeating: 0, count: 256)
        var size = [Int](repeating: 0, count: 256)

        /// The optimal table for `freq` (256 symbol counts), limited to 16 bits (Annex K.2).
        init(frequencies freq: [Int]) {
            var f = freq + [1]   // symbol 256 reserves the all-ones code
            var codesize = [Int](repeating: 0, count: 257)
            var others = [Int](repeating: -1, count: 257)
            while true {
                var c1 = -1, v = Int.max
                for i in 0...256 where f[i] > 0 && f[i] <= v { v = f[i]; c1 = i }
                var c2 = -1; v = Int.max
                for i in 0...256 where f[i] > 0 && f[i] <= v && i != c1 { v = f[i]; c2 = i }
                if c2 < 0 { break }
                f[c1] += f[c2]; f[c2] = 0
                codesize[c1] += 1
                while others[c1] >= 0 { c1 = others[c1]; codesize[c1] += 1 }
                others[c1] = c2
                codesize[c2] += 1
                while others[c2] >= 0 { c2 = others[c2]; codesize[c2] += 1 }
            }
            var bits = [Int](repeating: 0, count: 33)
            for i in 0...256 where codesize[i] > 0 { bits[min(codesize[i], 32)] += 1 }
            var i = 32
            while i > 16 {
                while bits[i] > 0 {
                    var j = i - 2
                    while bits[j] == 0 { j -= 1 }
                    bits[i] -= 2; bits[i - 1] += 1; bits[j + 1] += 2; bits[j] -= 1
                }
                i -= 1
            }
            i = 16
            while bits[i] == 0 { i -= 1 }
            bits[i] -= 1   // the reserved symbol's code
            for l in 1...16 { counts[l] = bits[l] }
            for l in 1...32 { for s in 0..<256 where codesize[s] == l { symbols.append(s) } }
            var next = 0, k = 0
            for l in 1...16 {
                for _ in 0..<counts[l] {
                    code[symbols[k]] = next; size[symbols[k]] = l
                    next += 1; k += 1
                }
                next <<= 1
            }
        }
    }

    private struct Encoder {
        let image: RGBAImage
        let quality: Int
        var out = Data()
        var bitBuffer: UInt32 = 0
        var bitCount = 0

        init(image: RGBAImage, quality: Int) { self.image = image; self.quality = quality }

        /// The table scaled by quality (libjpeg), in zigzag order for the header.
        func quant(_ base: [Int]) -> [Int] {
            let scale = quality < 50 ? 5000 / quality : 200 - quality * 2
            return base.map { min(max((($0 * scale) + 50) / 100, 1), 255) }
        }

        mutating func run() -> Data {
            let w = image.width, h = image.height
            let ql = quant(JPEGEncoder.lumaBase), qc = quant(JPEGEncoder.chromaBase)
            // Planes: Y at full size; Cb and Cr averaged 2×2.
            let cw = (w + 1) / 2, ch = (h + 1) / 2
            var yPlane = [Float](repeating: 0, count: w * h)
            var cbPlane = [Float](repeating: 0, count: cw * ch), crPlane = [Float](repeating: 0, count: cw * ch)
            var cbSum = [Float](repeating: 0, count: cw * ch), crSum = [Float](repeating: 0, count: cw * ch)
            var counts = [Float](repeating: 0, count: cw * ch)
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let a = Float(image.pixels[i + 3]) / 255
                    let r = Float(image.pixels[i]) * a + 255 * (1 - a)
                    let g = Float(image.pixels[i + 1]) * a + 255 * (1 - a)
                    let b = Float(image.pixels[i + 2]) * a + 255 * (1 - a)
                    yPlane[y * w + x] = 0.299 * r + 0.587 * g + 0.114 * b
                    let k = (y / 2) * cw + x / 2
                    cbSum[k] += -0.168736 * r - 0.331264 * g + 0.5 * b + 128
                    crSum[k] += 0.5 * r - 0.418688 * g - 0.081312 * b + 128
                    counts[k] += 1
                }
            }
            for k in 0..<(cw * ch) { cbPlane[k] = cbSum[k] / counts[k]; crPlane[k] = crSum[k] / counts[k] }

            // MCU = 16×16 pixels: four Y blocks, one Cb, one Cr.
            let mx = (w + 15) / 16, my = (h + 15) / 16
            var blocks: [[Int16]] = []   // quantized zigzag blocks in scan order, 64 each
            blocks.reserveCapacity(mx * my * 6)
            func block(_ plane: [Float], _ pw: Int, _ ph: Int, _ bx: Int, _ by: Int, _ q: [Int]) -> [Int16] {
                var s = [Double](repeating: 0, count: 64)
                for y in 0..<8 { for x in 0..<8 {
                    s[y * 8 + x] = Double(plane[min(by * 8 + y, ph - 1) * pw + min(bx * 8 + x, pw - 1)]) - 128
                } }
                var tmp = [Double](repeating: 0, count: 64)
                for y in 0..<8 { for u in 0..<8 {
                    var a = 0.0
                    for x in 0..<8 { a += s[y * 8 + x] * JPEGEncoder.dct[u * 8 + x] }
                    tmp[y * 8 + u] = a
                } }
                var res = [Int16](repeating: 0, count: 64)
                for z in 0..<64 {
                    let n = JPEGEncoder.zigzag[z], v = n / 8, u = n % 8
                    var a = 0.0
                    for y in 0..<8 { a += tmp[y * 8 + u] * JPEGEncoder.dct[v * 8 + y] }
                    res[z] = Int16(max(-2047, min(2047, (a / Double(q[n])).rounded())))
                }
                return res
            }
            for j in 0..<my {
                for i in 0..<mx {
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        blocks.append(block(yPlane, w, h, i * 2 + dx, j * 2 + dy, ql))
                    }
                    blocks.append(block(cbPlane, cw, ch, i, j, qc))
                    blocks.append(block(crPlane, cw, ch, i, j, qc))
                }
            }
            // The quantizer is applied in natural order above (q[n]); the table is written in zigzag order.
            // First pass: symbol statistics per table class. Component of block k is 0 (Y) for k % 6 < 4.
            var dcFreq = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 2)
            var acFreq = dcFreq
            var pred = [0, 0, 0]
            func component(_ k: Int) -> Int { k % 6 < 4 ? 0 : (k % 6 == 4 ? 1 : 2) }
            func walk(_ emit: (_ table: Int, _ isDC: Bool, _ symbol: Int, _ extra: Int, _ extraBits: Int) -> Void) {
                pred = [0, 0, 0]
                for (k, b) in blocks.enumerated() {
                    let c = component(k), t = c == 0 ? 0 : 1
                    let diff = Int(b[0]) - pred[c]; pred[c] = Int(b[0])
                    let (cat, bits) = JPEGEncoder.category(diff)
                    emit(t, true, cat, bits, cat)
                    var run = 0
                    for z in 1..<64 {
                        let v = Int(b[z])
                        if v == 0 { run += 1; continue }
                        while run > 15 { emit(t, false, 0xF0, 0, 0); run -= 16 }
                        let (cat, bits) = JPEGEncoder.category(v)
                        emit(t, false, (run << 4) | cat, bits, cat)
                        run = 0
                    }
                    if run > 0 { emit(t, false, 0, 0, 0) }
                }
            }
            walk { t, isDC, s, _, _ in if isDC { dcFreq[t][s] += 1 } else { acFreq[t][s] += 1 } }
            let dcT = [Table(frequencies: dcFreq[0]), Table(frequencies: dcFreq[1])]
            let acT = [Table(frequencies: acFreq[0]), Table(frequencies: acFreq[1])]

            // Header.
            put(0xFFD8)
            put(0xFFE0); put(16); out.append(contentsOf: Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
            for (id, q) in [(0, ql), (1, qc)] {
                put(0xFFDB); put(67); out.append(UInt8(id))
                for z in 0..<64 { out.append(UInt8(q[JPEGEncoder.zigzag[z]])) }
            }
            put(0xFFC0); put(17); out.append(8); put(h); put(w); out.append(3)
            out.append(contentsOf: [1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
            for (cls, tables) in [(0, dcT), (1, acT)] {
                for (id, t) in tables.enumerated() {
                    put(0xFFC4); put(19 + t.symbols.count); out.append(UInt8(cls << 4 | id))
                    for l in 1...16 { out.append(UInt8(t.counts[l])) }
                    out.append(contentsOf: t.symbols.map { UInt8($0) })
                }
            }
            put(0xFFDA); put(12); out.append(3)
            out.append(contentsOf: [1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0])
            // Entropy-coded data.
            walk { t, isDC, s, extra, extraBits in
                let table = isDC ? dcT[t] : acT[t]
                writeBits(table.code[s], table.size[s])
                if extraBits > 0 { writeBits(extra, extraBits) }
            }
            if bitCount > 0 { writeBits(0x7F, 8 - bitCount) }
            put(0xFFD9)
            return out
        }

        mutating func put(_ v: Int) { out.append(UInt8(v >> 8 & 0xFF)); out.append(UInt8(v & 0xFF)) }

        mutating func writeBits(_ value: Int, _ count: Int) {
            bitBuffer = bitBuffer << UInt32(count) | UInt32(value & ((1 << count) - 1))
            bitCount += count
            while bitCount >= 8 {
                let byte = UInt8((bitBuffer >> UInt32(bitCount - 8)) & 0xFF)
                out.append(byte)
                if byte == 0xFF { out.append(0) }
                bitCount -= 8
            }
            bitBuffer &= (1 << UInt32(bitCount)) - 1
        }
    }

    /// A value's size category and its extra bits (JPEG F.1.2.1).
    static func category(_ v: Int) -> (Int, Int) {
        if v == 0 { return (0, 0) }
        let a = abs(v)
        var n = 0
        while (1 << n) <= a { n += 1 }
        return (n, v > 0 ? v : v + (1 << n) - 1)
    }
}
