import Foundation

/// JPEG reading for exports (docs/attachments.md §10): the frame header for
/// PDF passthrough, metadata stripping, and a baseline + progressive Huffman
/// decoder (8-bit, one or three components) for PNG export.
///
/// The decoder follows libjpeg(-turbo)'s default decompression path so its
/// output matches theirs: the "islow" integer IDCT (`jidctint.c`), "fancy"
/// (triangle) upsampling for 2×1, 1×2 and 2×2 chroma (`jdsample.c`), and the
/// fixed-point YCbCr → RGB tables of `jdcolor.c`. DCT scaling (1/2, 1/4, 1/8)
/// decodes a large photo straight to a smaller size.
///
/// Every byte is untrusted (format.md §9): every length, table and code is
/// checked, decoding work is bounded by the pixels the file may claim
/// (`ImageLimits`), and a truncated scan decodes as far as its data goes.
enum JPEG {
    /// What the frame header says.
    struct Info: Equatable {
        var width: Int
        var height: Int
        /// 1 (grey) or 3 (colour).
        var components: Int
        var progressive: Bool
        /// True when three components hold R, G, B rather than Y, Cb, Cr
        /// (an Adobe marker with transform 0, or component ids `R`, `G`, `B`
        /// without a JFIF or Adobe marker): a PDF `DCTDecode` filter then
        /// needs `/ColorTransform 0`.
        var isRGB: Bool
    }

    /// Scans decoded per image; later ones are ignored (as if the file ended).
    static let maxScans = 100

    /// Natural (row-major) index of the k-th coefficient in zigzag order.
    static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    // MARK: - Marker walk

    /// One marker segment or entropy-coded run of the file.
    private enum Part {
        /// A marker with its segment payload range (empty for SOI, EOI, RSTn).
        case marker(UInt8, payload: Range<Int>, whole: Range<Int>)
        /// Entropy-coded data after an SOS or RSTn, up to the next marker.
        case entropy(Range<Int>)
    }

    /// Walks the file from SOI to EOI, or to the end when EOI is missing.
    /// Bytes after EOI are not visited.
    private static func walk(_ d: [UInt8], _ visit: (Part) throws -> Void) throws {
        guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8 else { throw ImageError.notAnImage }
        try visit(.marker(0xD8, payload: 2..<2, whole: 0..<2))
        var pos = 2
        var inScan = false
        while pos < d.count {
            if inScan {
                // Entropy-coded data runs to the next marker that is not a
                // stuffed 0xFF00 or an RSTn (which stays inside the scan).
                var start = pos
                while pos < d.count {
                    if d[pos] == 0xFF, pos + 1 < d.count {
                        let n = d[pos + 1]
                        if n == 0x00 { pos += 2; continue }
                        if n == 0xFF { pos += 1; continue }
                        if (0xD0...0xD7).contains(n) {
                            if pos > start { try visit(.entropy(start..<pos)) }
                            try visit(.marker(n, payload: pos + 2..<pos + 2, whole: pos..<pos + 2))
                            pos += 2
                            start = pos
                            continue
                        }
                        break
                    }
                    pos += 1
                }
                if pos > start { try visit(.entropy(start..<min(pos, d.count))) }
                inScan = false
                continue
            }
            guard d[pos] == 0xFF else { throw ImageError.malformed("expected a marker at byte \(pos)") }
            // Fill bytes: any number of 0xFF before a marker.
            var m = pos + 1
            while m < d.count, d[m] == 0xFF { m += 1 }
            guard m < d.count else { return }
            let code = d[m]
            let markerStart = m - 1
            pos = m + 1
            switch code {
            case 0xD9:
                try visit(.marker(code, payload: pos..<pos, whole: markerStart..<pos))
                return
            case 0xD0...0xD7, 0x01:
                try visit(.marker(code, payload: pos..<pos, whole: markerStart..<pos))
            case 0x00, 0xD8:
                throw ImageError.malformed("unexpected marker \(code)")
            default:
                guard pos + 2 <= d.count else { throw ImageError.truncated }
                let len = Int(d[pos]) << 8 | Int(d[pos + 1])
                guard len >= 2 else { throw ImageError.malformed("segment length \(len)") }
                guard pos + len <= d.count else { throw ImageError.truncated }
                try visit(.marker(code, payload: pos + 2..<pos + len, whole: markerStart..<pos + len))
                pos += len
                if code == 0xDA { inScan = true }
            }
        }
    }

    // MARK: - Info and metadata

    /// Reads the frame header. Throws `.unsupported` for what PDF passthrough
    /// and the decoder do not take (format.md §8.2.5): lossless, hierarchical
    /// or arithmetic coding, precision other than 8, or other than 1 or 3 components.
    static func info(_ data: Data) throws -> Info {
        let d = [UInt8](data)
        var result: Info?
        var jfif = false, adobe: UInt8?
        struct Done: Error {}
        do {
            try walk(d) { part in
                guard case let .marker(code, p, _) = part else { return }
                switch code {
                case 0xE0 where p.count >= 5 && Array(d[p.lowerBound..<p.lowerBound + 5]) == [0x4A, 0x46, 0x49, 0x46, 0]:
                    jfif = true
                case 0xEE where p.count >= 12 && Array(d[p.lowerBound..<p.lowerBound + 5]) == [0x41, 0x64, 0x6F, 0x62, 0x65]:
                    adobe = d[p.lowerBound + 11]
                case 0xC0, 0xC1, 0xC2:
                    let f = try Frame(d, p, progressive: code == 0xC2)
                    let ids = f.components.map(\.id)
                    let rgb = f.components.count == 3
                        && (adobe.map { $0 == 0 } ?? (!jfif && ids == [0x52, 0x47, 0x42]))
                    result = Info(width: f.width, height: f.height, components: f.components.count,
                                  progressive: code == 0xC2, isRGB: rgb)
                    throw Done()
                case 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                    throw ImageError.unsupported("lossless, hierarchical or arithmetic-coded JPEG")
                case 0xDA:
                    throw ImageError.malformed("scan before frame header")
                default:
                    break
                }
            }
        } catch is Done {}
        guard let result else { throw ImageError.malformed("no frame header") }
        return result
    }

    /// The file without metadata (format.md §8.2.5): every APPn segment
    /// except APP0 (JFIF), APP2 (ICC profile) and APP14 (Adobe), every COM
    /// segment, and anything after EOI (where phones append preview images
    /// with their own metadata). Everything else is copied byte for byte, so
    /// the image data is unchanged. A missing EOI is added.
    static func stripMetadata(_ data: Data) throws -> Data {
        let d = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(d.count)
        var sawEOI = false
        try walk(d) { part in
            switch part {
            case let .marker(code, _, whole):
                if (0xE0...0xEF).contains(code) && code != 0xE0 && code != 0xE2 && code != 0xEE { return }
                if code == 0xFE { return }
                if code == 0xD9 { sawEOI = true }
                out.append(contentsOf: d[whole])
            case let .entropy(r):
                out.append(contentsOf: d[r])
            }
        }
        if !sawEOI { out += [0xFF, 0xD9] }
        return Data(out)
    }

    // MARK: - Frame

    struct Component {
        var id: UInt8
        var h: Int
        var v: Int
        var tq: Int
        /// Blocks covering the component's own samples.
        var blocksW = 0, blocksH = 0
        /// Blocks including the padding to whole MCUs (storage size).
        var paddedW = 0, paddedH = 0
        /// Component samples: `ceil(X·h/hmax)` × `ceil(Y·v/vmax)`.
        var samplesW = 0, samplesH = 0
    }

    struct Frame {
        var width: Int
        var height: Int
        var components: [Component]
        var hmax = 1, vmax = 1
        var mcusX = 0, mcusY = 0
        var progressive: Bool

        init(_ d: [UInt8], _ p: Range<Int>, progressive: Bool) throws {
            guard p.count >= 6 else { throw ImageError.malformed("short frame header") }
            let b = p.lowerBound
            guard d[b] == 8 else { throw ImageError.unsupported("\(d[b])-bit JPEG") }
            height = Int(d[b + 1]) << 8 | Int(d[b + 2])
            width = Int(d[b + 3]) << 8 | Int(d[b + 4])
            let n = Int(d[b + 5])
            guard n == 1 || n == 3 else {
                throw ImageError.unsupported(n == 4 ? "CMYK JPEG" : "JPEG with \(n) components")
            }
            guard p.count >= 6 + 3 * n else { throw ImageError.malformed("short frame header") }
            guard width > 0 else { throw ImageError.malformed("zero width") }
            guard height > 0 else { throw ImageError.unsupported("JPEG with a DNL height") }
            self.progressive = progressive
            components = []
            for i in 0..<n {
                let o = b + 6 + 3 * i
                let h = Int(d[o + 1] >> 4), v = Int(d[o + 1] & 15), tq = Int(d[o + 2])
                guard (1...4).contains(h), (1...4).contains(v), tq < 4 else {
                    throw ImageError.malformed("component sampling or table")
                }
                guard !components.contains(where: { $0.id == d[o] }) else {
                    throw ImageError.malformed("duplicate component id")
                }
                components.append(Component(id: d[o], h: h, v: v, tq: tq))
            }
            hmax = components.map(\.h).max() ?? 1
            vmax = components.map(\.v).max() ?? 1
            if n == 1 { components[0].h = 1; components[0].v = 1; hmax = 1; vmax = 1 }
            mcusX = (width + 8 * hmax - 1) / (8 * hmax)
            mcusY = (height + 8 * vmax - 1) / (8 * vmax)
            for i in components.indices {
                let c = components[i]
                components[i].samplesW = (width * c.h + hmax - 1) / hmax
                components[i].samplesH = (height * c.v + vmax - 1) / vmax
                components[i].blocksW = (components[i].samplesW + 7) / 8
                components[i].blocksH = (components[i].samplesH + 7) / 8
                components[i].paddedW = mcusX * c.h
                components[i].paddedH = mcusY * c.v
            }
        }
    }

    // MARK: - Huffman

    struct Huffman {
        /// 9-bit lookahead: `length << 8 | value`, 0 when the code is longer.
        var fast = [UInt16](repeating: 0, count: 512)
        var maxcode = [Int32](repeating: -1, count: 18)
        var valptr = [Int32](repeating: 0, count: 17)
        var mincode = [Int32](repeating: 0, count: 17)
        var values: [UInt8]

        init(counts: [Int], values: [UInt8]) throws {
            self.values = values
            var code: Int32 = 0
            var k: Int32 = 0
            for len in 1...16 {
                let n = Int32(counts[len - 1])
                if n > 0 {
                    valptr[len] = k
                    mincode[len] = code
                    code += n
                    k += n
                    maxcode[len] = code - 1
                    guard code <= Int32(1) << len else { throw ImageError.malformed("Huffman code overflow") }
                }
                code <<= 1
            }
            maxcode[17] = Int32.max
            // Fast table for codes of up to 9 bits.
            var c: Int32 = 0
            var idx = 0
            for len in 1...9 {
                for _ in 0..<counts[len - 1] {
                    let shift = 9 - len
                    let base = Int(c) << shift
                    for j in 0..<(1 << shift) where base + j < 512 {
                        fast[base + j] = UInt16(len) << 8 | UInt16(values[idx])
                    }
                    c += 1
                    idx += 1
                }
                c <<= 1
            }
        }
    }

    // MARK: - Bit reader

    struct BitReader {
        let d: [UInt8]
        var pos: Int
        var acc: UInt32 = 0
        var nbits = 0
        /// The marker that ended the entropy data (`pos` is at its 0xFF), if any.
        var marker: UInt8?
        /// Zero bytes supplied after the data ran out.
        var padded = 0

        init(_ d: [UInt8], at pos: Int) { self.d = d; self.pos = pos }

        mutating func fill() {
            while nbits <= 24 {
                var byte: UInt8 = 0
                if marker == nil, pos < d.count {
                    byte = d[pos]
                    if byte == 0xFF {
                        var n = pos + 1
                        while n < d.count, d[n] == 0xFF { n += 1 }
                        let next: UInt8 = n < d.count ? d[n] : 0xD9
                        if next == 0 {
                            pos = n + 1
                        } else {
                            marker = next
                            pos = n - 1
                            byte = 0
                            padded += 1
                        }
                    } else {
                        pos += 1
                    }
                } else {
                    padded += 1
                }
                acc |= UInt32(byte) << UInt32(24 - nbits)
                nbits += 8
            }
        }

        mutating func bits(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            if nbits < n { fill() }
            let v = Int(acc >> UInt32(32 - n))
            acc <<= UInt32(n)
            nbits -= n
            return v
        }

        mutating func bit() -> Int { bits(1) }

        /// `bits(s)` sign-extended as JPEG codes a magnitude category (F.2.2.1).
        mutating func receiveExtend(_ s: Int) -> Int32 {
            guard s > 0 else { return 0 }
            let v = Int32(bits(s))
            return v < Int32(1) << (s - 1) ? v - (Int32(1) << s) + 1 : v
        }

        mutating func decode(_ t: Huffman) throws -> Int {
            if nbits < 16 { fill() }
            let look = Int(acc >> 23)
            let f = t.fast[look]
            if f != 0 {
                let len = Int(f >> 8)
                acc <<= UInt32(len)
                nbits -= len
                return Int(f & 0xFF)
            }
            var code: Int32 = 0
            for len in 1...16 {
                code = code << 1 | Int32(acc >> 31)
                acc <<= 1
                nbits -= 1
                if t.maxcode[len] >= 0, code <= t.maxcode[len], code >= t.mincode[len] {
                    let i = Int(t.valptr[len] + code - t.mincode[len])
                    guard i < t.values.count else { throw ImageError.malformed("Huffman value") }
                    return Int(t.values[i])
                }
            }
            throw ImageError.malformed("bad Huffman code")
        }

        /// Drops buffered bits and skips the RSTn marker that should be next (or
        /// searches forward for one), as libjpeg resynchronises.
        mutating func restart() {
            acc = 0
            nbits = 0
            if let m = marker, (0xD0...0xD7).contains(m) {
                marker = nil
                pos += 2
                return
            }
            if marker != nil { return }   // another marker: leave it, the rest decodes as zeros
            var p = pos
            while p + 1 < d.count {
                if d[p] == 0xFF, (0xD0...0xD7).contains(d[p + 1]) { pos = p + 2; return }
                if d[p] == 0xFF, d[p + 1] != 0, d[p + 1] != 0xFF { pos = p; marker = d[p + 1]; return }
                p += 1
            }
            pos = d.count
        }
    }

    // MARK: - Decoder

    /// Decodes to RGBA at `1/scale` of the size (`scale` 1, 2, 4 or 8;
    /// dimensions rounded up, as libjpeg's DCT scaling does).
    ///
    /// - Throws: `ImageError`; `.tooLarge` beyond `maxPixels` (full size) or
    ///   `ImageLimits.pixelsPerInputByte`.
    static func decode(_ data: Data, scale: Int = 1, maxPixels: Int = ImageLimits.maxPixels) throws -> RGBAImage {
        var dec = Decoder(d: [UInt8](data), scale: [1, 2, 4, 8].contains(scale) ? scale : 1, maxPixels: maxPixels)
        return try dec.run()
    }

    /// The largest DCT scale (1, 2, 4 or 8) at which an image of `width × height`
    /// still has at least `minWidth × minHeight` pixels.
    static func scale(width: Int, height: Int, minWidth: Double, minHeight: Double) -> Int {
        var s = 1
        for c in [2, 4, 8] {
            let w = Double((width + c - 1) / c), h = Double((height + c - 1) / c)
            if w >= minWidth && h >= minHeight { s = c } else { break }
        }
        return s
    }

    private struct Decoder {
        let d: [UInt8]
        let scale: Int
        let maxPixels: Int
        /// Output block side: 8 / scale.
        var bs: Int { 8 / scale }

        var qt = [[Int32]?](repeating: nil, count: 4)
        var dcTables = [Huffman?](repeating: nil, count: 4)
        var acTables = [Huffman?](repeating: nil, count: 4)
        var restartInterval = 0
        var frame: Frame?
        var jfif = false
        var adobe: UInt8?
        /// Progressive: quantized coefficients per component, 64 per block, natural order.
        var coefs: [[Int16]] = []
        /// Baseline: decoded samples per component (padded size, at output scale).
        var planes: [[UInt8]] = []
        var scans = 0
        var eobrun = 0

        init(d: [UInt8], scale: Int, maxPixels: Int) {
            self.d = d; self.scale = scale; self.maxPixels = maxPixels
        }

        mutating func run() throws -> RGBAImage {
            guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8 else { throw ImageError.notAnImage }
            var pos = 2
            segments: while pos < d.count {
                guard d[pos] == 0xFF else {
                    // Junk between segments (after a scan ended early): find the next marker.
                    pos += 1
                    continue
                }
                var m = pos + 1
                while m < d.count, d[m] == 0xFF { m += 1 }
                guard m < d.count else { break }
                let code = d[m]
                pos = m + 1
                switch code {
                case 0xD9: break segments
                case 0xD0...0xD7, 0x01, 0x00: continue
                case 0xD8: throw ImageError.malformed("nested SOI")
                default: break
                }
                guard pos + 2 <= d.count else { break }
                let len = Int(d[pos]) << 8 | Int(d[pos + 1])
                guard len >= 2, pos + len <= d.count else {
                    if frame != nil && scans > 0 { break segments }
                    throw len < 2 ? ImageError.malformed("segment length") : ImageError.truncated
                }
                let p = pos + 2..<pos + len
                pos += len
                switch code {
                case 0xC0, 0xC1, 0xC2:
                    guard frame == nil else { throw ImageError.malformed("second frame header") }
                    let f = try Frame(d, p, progressive: code == 0xC2)
                    try ImageLimits.check(width: f.width, height: f.height, inputBytes: d.count, maxPixels: maxPixels)
                    frame = f
                    try allocate(f)
                case 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                    throw ImageError.unsupported("lossless, hierarchical or arithmetic-coded JPEG")
                case 0xC4: try readDHT(p)
                case 0xDB: try readDQT(p)
                case 0xDD:
                    guard p.count >= 2 else { throw ImageError.malformed("DRI") }
                    restartInterval = Int(d[p.lowerBound]) << 8 | Int(d[p.lowerBound + 1])
                case 0xDA:
                    // Each scan walks every block again: cap them so work stays
                    // linear in the pixels (real progressive files use ~10–30).
                    guard scans < JPEG.maxScans else { break segments }
                    pos = try scan(p)
                case 0xE0 where p.count >= 5 && Array(d[p.lowerBound..<p.lowerBound + 5]) == [0x4A, 0x46, 0x49, 0x46, 0]:
                    jfif = true
                case 0xEE where p.count >= 12 && Array(d[p.lowerBound..<p.lowerBound + 5]) == [0x41, 0x64, 0x6F, 0x62, 0x65]:
                    adobe = d[p.lowerBound + 11]
                default:
                    break   // APPn, COM, DNL, others: skipped
                }
            }
            guard let f = frame else { throw ImageError.malformed("no frame header") }
            guard scans > 0 else { throw ImageError.truncated }
            if f.progressive { try finishProgressive(f) }
            return try output(f)
        }

        mutating func allocate(_ f: Frame) throws {
            if f.progressive {
                coefs = f.components.map { [Int16](repeating: 0, count: $0.paddedW * $0.paddedH * 64) }
            } else {
                let b = bs
                planes = f.components.map { [UInt8](repeating: 128, count: $0.paddedW * b * $0.paddedH * b) }
            }
        }

        mutating func readDQT(_ p: Range<Int>) throws {
            var i = p.lowerBound
            while i < p.upperBound {
                let pq = Int(d[i] >> 4), tq = Int(d[i] & 15)
                guard pq <= 1, tq < 4 else { throw ImageError.malformed("DQT") }
                let size = pq == 0 ? 64 : 128
                guard i + 1 + size <= p.upperBound else { throw ImageError.malformed("short DQT") }
                var table = [Int32](repeating: 0, count: 64)
                for k in 0..<64 {
                    let v = pq == 0 ? Int32(d[i + 1 + k]) : Int32(d[i + 1 + 2 * k]) << 8 | Int32(d[i + 2 + 2 * k])
                    table[JPEG.zigzag[k]] = v
                }
                qt[tq] = table
                i += 1 + size
            }
        }

        mutating func readDHT(_ p: Range<Int>) throws {
            var i = p.lowerBound
            while i < p.upperBound {
                guard i + 17 <= p.upperBound else { throw ImageError.malformed("short DHT") }
                let tc = Int(d[i] >> 4), th = Int(d[i] & 15)
                guard tc <= 1, th < 4 else { throw ImageError.malformed("DHT class or id") }
                let counts = (0..<16).map { Int(d[i + 1 + $0]) }
                let total = counts.reduce(0, +)
                guard total <= 256, i + 17 + total <= p.upperBound else { throw ImageError.malformed("DHT counts") }
                let values = Array(d[(i + 17)..<(i + 17 + total)])
                let t = try Huffman(counts: counts, values: values)
                if tc == 0 { dcTables[th] = t } else { acTables[th] = t }
                i += 17 + total
            }
        }

        /// Decodes one scan; returns the position of the marker after its data.
        mutating func scan(_ p: Range<Int>) throws -> Int {
            guard let f = frame else { throw ImageError.malformed("scan before frame header") }
            let b = p.lowerBound
            guard p.count >= 1 else { throw ImageError.malformed("SOS") }
            let ns = Int(d[b])
            guard (1...4).contains(ns), p.count >= 1 + 2 * ns + 3 else { throw ImageError.malformed("SOS") }
            var comps: [(index: Int, dc: Int, ac: Int)] = []
            for i in 0..<ns {
                let id = d[b + 1 + 2 * i], t = d[b + 2 + 2 * i]
                guard let ci = f.components.firstIndex(where: { $0.id == id }),
                      !comps.contains(where: { $0.index == ci }) else { throw ImageError.malformed("scan component") }
                comps.append((ci, Int(t >> 4), Int(t & 15)))
            }
            let ss = Int(d[b + 1 + 2 * ns]), se = Int(d[b + 2 + 2 * ns])
            let ah = Int(d[b + 3 + 2 * ns] >> 4), al = Int(d[b + 3 + 2 * ns] & 15)
            if f.progressive {
                guard ss <= se, se <= 63, (ss == 0) == (se == 0), ah <= 13, al <= 13 else {
                    throw ImageError.malformed("progressive scan parameters")
                }
                guard ss == 0 || ns == 1 else { throw ImageError.malformed("interleaved AC scan") }
            } else {
                guard ss == 0, se == 63, ah == 0, al == 0 else { throw ImageError.malformed("sequential scan parameters") }
            }
            if ns > 1 {
                guard comps.reduce(0, { $0 + f.components[$1.index].h * f.components[$1.index].v }) <= 10 else {
                    throw ImageError.malformed("too many blocks per MCU")
                }
            }
            // Tables the scan needs.
            let needDC = !f.progressive || ss == 0 && ah == 0
            let needAC = !f.progressive || ss > 0
            for c in comps {
                if needDC { guard c.dc < 4, dcTables[c.dc] != nil else { throw ImageError.malformed("missing DC table") } }
                if needAC { guard c.ac < 4, acTables[c.ac] != nil else { throw ImageError.malformed("missing AC table") } }
                if !f.progressive { guard qt[f.components[c.index].tq] != nil else { throw ImageError.malformed("missing quantization table") } }
            }

            var r = BitReader(d, at: p.upperBound)
            var pred = [Int32](repeating: 0, count: f.components.count)
            eobrun = 0
            var block = [Int32](repeating: 0, count: 64)
            var sinceRestart = 0


            // Past the end of the data every block decodes from zero bits: stop
            // (the rest stays as it is, like libjpeg's truncated-file warning).
            let exhausted = 1024
            if ns == 1 {
                let c = comps[0]
                let comp = f.components[c.index]
                rows: for by in 0..<comp.blocksH {
                    if r.padded > exhausted { break rows }
                    for bx in 0..<comp.blocksW {
                        try decodeBlock(&r, f, c, bx: bx, by: by, pred: &pred[c.index], ss: ss, se: se, ah: ah, al: al,
                                        block: &block)
                        restartIfDue(&r, &pred, &sinceRestart)
                    }
                }
            } else {
                rows: for my in 0..<f.mcusY {
                    if r.padded > exhausted { break rows }
                    for mx in 0..<f.mcusX {
                        for c in comps {
                            let comp = f.components[c.index]
                            for v in 0..<comp.v {
                                for h in 0..<comp.h {
                                    try decodeBlock(&r, f, c, bx: mx * comp.h + h, by: my * comp.v + v,
                                                    pred: &pred[c.index], ss: ss, se: se, ah: ah, al: al, block: &block)
                                }
                            }
                        }
                        restartIfDue(&r, &pred, &sinceRestart)
                    }
                }
            }
            scans += 1
            if r.marker != nil { return r.pos }
            // The data ran out (or the reader stopped early): find the next marker.
            var q = min(r.pos, d.count)
            while q + 1 < d.count {
                if d[q] == 0xFF, d[q + 1] != 0, d[q + 1] != 0xFF, !(0xD0...0xD7).contains(d[q + 1]) { return q }
                q += 1
            }
            return d.count
        }

        /// Counts one MCU; at the end of a restart interval resynchronises on
        /// the RSTn marker and resets the predictors and the EOB run.
        mutating func restartIfDue(_ r: inout BitReader, _ pred: inout [Int32], _ count: inout Int) {
            guard restartInterval > 0 else { return }
            count += 1
            guard count == restartInterval else { return }
            count = 0
            r.restart()
            for i in pred.indices { pred[i] = 0 }
            eobrun = 0
        }

        mutating func decodeBlock(_ r: inout BitReader, _ f: Frame, _ c: (index: Int, dc: Int, ac: Int),
                                  bx: Int, by: Int, pred: inout Int32, ss: Int, se: Int, ah: Int, al: Int,
                                  block: inout [Int32]) throws {
            let comp = f.components[c.index]
            if !f.progressive {
                for i in 0..<64 { block[i] = 0 }
                let t = try r.decode(dcTables[c.dc]!)
                guard t <= 16 else { throw ImageError.malformed("DC category") }
                pred = pred &+ r.receiveExtend(t)
                block[0] = pred
                var k = 1
                let ac = acTables[c.ac]!
                while k < 64 {
                    let rs = try r.decode(ac)
                    let run = rs >> 4, s = rs & 15
                    if s == 0 {
                        if run == 15 { k += 16; continue }
                        break
                    }
                    k += run
                    guard k < 64 else { break }
                    block[JPEG.zigzag[k]] = r.receiveExtend(s)
                    k += 1
                }
                let q = qt[comp.tq]!
                let b = bs
                let stride = comp.paddedW * b
                planes[c.index].withUnsafeMutableBufferPointer { plane in
                    JPEG.idct(block, q, scale: scale, into: plane, offset: by * b * stride + bx * b, stride: stride)
                }
                return
            }
            let base = (by * comp.paddedW + bx) * 64
            if ss == 0 {
                // DC scans (interleaved or not).
                if ah == 0 {
                    let t = try r.decode(dcTables[c.dc]!)
                    guard t <= 16 else { throw ImageError.malformed("DC category") }
                    pred = pred &+ r.receiveExtend(t)
                    coefs[c.index][base] = clamp16(Int64(pred) << al)
                } else if r.bit() == 1 {
                    coefs[c.index][base] |= Int16(truncatingIfNeeded: 1 << al)
                }
                return
            }
            let ac = acTables[c.ac]!
            if ah == 0 {
                if eobrun > 0 { eobrun -= 1; return }
                var k = ss
                while k <= se {
                    let rs = try r.decode(ac)
                    let run = rs >> 4, s = rs & 15
                    if s == 0 {
                        if run < 15 {
                            eobrun = (1 << run) - 1
                            if run > 0 { eobrun += r.bits(run) }
                            break
                        }
                        k += 16
                        continue
                    }
                    k += run
                    guard k <= 63 else { break }
                    coefs[c.index][base + JPEG.zigzag[k]] = clamp16(Int64(r.receiveExtend(s)) << al)
                    k += 1
                }
                return
            }
            // AC refinement (G.1.2.3), as libjpeg's decode_mcu_AC_refine.
            let p1 = Int16(truncatingIfNeeded: 1 << al), m1 = Int16(truncatingIfNeeded: -1 << al)
            var k = ss
            func refine(_ z: Int, _ r: inout BitReader) {
                let v = coefs[c.index][base + z]
                if r.bit() == 1, v & p1 == 0 {
                    coefs[c.index][base + z] = v >= 0 ? v &+ p1 : v &+ m1
                }
            }
            if eobrun == 0 {
                while k <= se {
                    let rs = try r.decode(ac)
                    var run = rs >> 4
                    var s: Int16 = 0
                    if rs & 15 != 0 {
                        s = r.bit() == 1 ? p1 : m1
                    } else if run != 15 {
                        eobrun = 1 << run
                        if run > 0 { eobrun += r.bits(run) }
                        break
                    }
                    while k <= se {
                        let z = JPEG.zigzag[k]
                        if coefs[c.index][base + z] != 0 {
                            refine(z, &r)
                        } else {
                            if run == 0 { break }
                            run -= 1
                        }
                        k += 1
                    }
                    if s != 0, k <= 63 { coefs[c.index][base + JPEG.zigzag[k]] = s }
                    k += 1
                }
            }
            if eobrun > 0 {
                while k <= se {
                    let z = JPEG.zigzag[k]
                    if coefs[c.index][base + z] != 0 { refine(z, &r) }
                    k += 1
                }
                eobrun -= 1
            }
        }

        mutating func finishProgressive(_ f: Frame) throws {
            let b = bs
            planes = []
            var block = [Int32](repeating: 0, count: 64)
            for (ci, comp) in f.components.enumerated() {
                guard let q = qt[comp.tq] else { throw ImageError.malformed("missing quantization table") }
                let stride = comp.paddedW * b
                var plane = [UInt8](repeating: 128, count: stride * comp.paddedH * b)
                plane.withUnsafeMutableBufferPointer { out in
                    for by in 0..<comp.paddedH {
                        for bx in 0..<comp.paddedW {
                            let base = (by * comp.paddedW + bx) * 64
                            for i in 0..<64 { block[i] = Int32(coefs[ci][base + i]) }
                            JPEG.idct(block, q, scale: scale, into: out, offset: by * b * stride + bx * b, stride: stride)
                        }
                    }
                }
                coefs[ci] = []
                planes.append(plane)
            }
        }

        /// Upsamples and colour-converts the planes into the RGBA output.
        func output(_ f: Frame) throws -> RGBAImage {
            let ow = (f.width + scale - 1) / scale, oh = (f.height + scale - 1) / scale
            var px = [UInt8](repeating: 255, count: ow * oh * 4)
            let b = bs
            if f.components.count == 1 {
                let stride = f.components[0].paddedW * b
                let plane = planes[0]
                for y in 0..<oh {
                    for x in 0..<ow {
                        let v = plane[y * stride + x]
                        let o = (y * ow + x) * 4
                        px[o] = v; px[o + 1] = v; px[o + 2] = v
                    }
                }
                return try RGBAImage(width: ow, height: oh, pixels: px)
            }
            // Full-resolution rows of each component.
            var full: [[UInt8]] = []
            for (ci, comp) in f.components.enumerated() {
                let fh = f.hmax / comp.h, fv = f.vmax / comp.v
                guard f.hmax % comp.h == 0, f.vmax % comp.v == 0 else {
                    throw ImageError.unsupported("non-integral chroma subsampling")
                }
                let stride = comp.paddedW * b
                // Samples of this component at the output scale (libjpeg's downsampled size).
                let cw = max((comp.samplesW + scale - 1) / scale, 1), ch = max((comp.samplesH + scale - 1) / scale, 1)
                full.append(JPEG.upsample(planes[ci], stride: stride, width: cw, height: ch, fh: fh, fv: fv,
                                          outWidth: ow, outHeight: oh, fancy: scale < 8))
            }
            let ids = f.components.map(\.id)
            let rgb = adobe.map { $0 == 0 } ?? (!jfif && ids == [0x52, 0x47, 0x42])
            for i in 0..<(ow * oh) {
                let o = i * 4
                if rgb {
                    px[o] = full[0][i]; px[o + 1] = full[1][i]; px[o + 2] = full[2][i]
                } else {
                    let (r, g, bb) = JPEG.ycc(full[0][i], full[1][i], full[2][i])
                    px[o] = r; px[o + 1] = g; px[o + 2] = bb
                }
            }
            return try RGBAImage(width: ow, height: oh, pixels: px)
        }
    }

    private static func clamp16(_ v: Int64) -> Int16 { Int16(clamping: v) }

    // MARK: - IDCT (libjpeg jidctint.c, "islow")

    private static let constBits: Int32 = 13
    private static let pass1Bits: Int32 = 2
    private static let f0298631336: Int32 = 2446
    private static let f0390180644: Int32 = 3196
    private static let f0541196100: Int32 = 4433
    private static let f0765366865: Int32 = 6270
    private static let f0899976223: Int32 = 7373
    private static let f1175875602: Int32 = 9633
    private static let f1501321110: Int32 = 12299
    private static let f1847759065: Int32 = 15137
    private static let f1961570560: Int32 = 16069
    private static let f2053119869: Int32 = 16819
    private static let f2562915447: Int32 = 20995
    private static let f3072711026: Int32 = 25172

    @inline(__always)
    private static func descale(_ x: Int32, _ n: Int32) -> Int32 { (x &+ (1 << (n - 1))) >> n }

    @inline(__always)
    private static func limit(_ v: Int32) -> UInt8 { UInt8(clamping: v &+ 128) }

    /// Dequantizes and inverse-transforms one block (natural order) into
    /// `out`, at `8 / scale` samples per side. Arithmetic wraps like C's on
    /// hostile coefficients instead of trapping.
    static func idct(_ coef: [Int32], _ q: [Int32], scale: Int, into out: UnsafeMutableBufferPointer<UInt8>,
                     offset: Int, stride: Int) {
        if scale == 8 {
            // jidctred 1×1: the DC term alone.
            out[offset] = limit(descale(coef[0] &* q[0], 3))
            return
        }
        var ws = [Int32](repeating: 0, count: 64)
        // Pass 1: columns.
        for col in 0..<8 {
            if coef[8 + col] == 0, coef[16 + col] == 0, coef[24 + col] == 0, coef[32 + col] == 0,
               coef[40 + col] == 0, coef[48 + col] == 0, coef[56 + col] == 0 {
                let dc = (coef[col] &* q[col]) << pass1Bits
                for r in 0..<8 { ws[r * 8 + col] = dc }
                continue
            }
            var z2 = coef[16 + col] &* q[16 + col], z3 = coef[48 + col] &* q[48 + col]
            var z1 = (z2 &+ z3) &* f0541196100
            var tmp2 = z1 &+ z3 &* -f1847759065
            var tmp3 = z1 &+ z2 &* f0765366865
            z2 = coef[col] &* q[col]; z3 = coef[32 + col] &* q[32 + col]
            var tmp0 = (z2 &+ z3) << constBits
            var tmp1 = (z2 &- z3) << constBits
            let tmp10 = tmp0 &+ tmp3, tmp13 = tmp0 &- tmp3, tmp11 = tmp1 &+ tmp2, tmp12 = tmp1 &- tmp2
            tmp0 = coef[56 + col] &* q[56 + col]; tmp1 = coef[40 + col] &* q[40 + col]
            tmp2 = coef[24 + col] &* q[24 + col]; tmp3 = coef[8 + col] &* q[8 + col]
            z1 = tmp0 &+ tmp3; z2 = tmp1 &+ tmp2; z3 = tmp0 &+ tmp2
            var z4 = tmp1 &+ tmp3
            let z5 = (z3 &+ z4) &* f1175875602
            tmp0 = tmp0 &* f0298631336; tmp1 = tmp1 &* f2053119869
            tmp2 = tmp2 &* f3072711026; tmp3 = tmp3 &* f1501321110
            z1 = z1 &* -f0899976223; z2 = z2 &* -f2562915447; z3 = z3 &* -f1961570560; z4 = z4 &* -f0390180644
            z3 = z3 &+ z5; z4 = z4 &+ z5
            tmp0 = tmp0 &+ z1 &+ z3; tmp1 = tmp1 &+ z2 &+ z4; tmp2 = tmp2 &+ z2 &+ z3; tmp3 = tmp3 &+ z1 &+ z4
            let n = constBits - pass1Bits
            ws[col] = descale(tmp10 &+ tmp3, n); ws[56 + col] = descale(tmp10 &- tmp3, n)
            ws[8 + col] = descale(tmp11 &+ tmp2, n); ws[48 + col] = descale(tmp11 &- tmp2, n)
            ws[16 + col] = descale(tmp12 &+ tmp1, n); ws[40 + col] = descale(tmp12 &- tmp1, n)
            ws[24 + col] = descale(tmp13 &+ tmp0, n); ws[32 + col] = descale(tmp13 &- tmp0, n)
        }
        // Pass 2: rows.
        var full = [UInt8](repeating: 0, count: 64)
        let n2 = constBits + pass1Bits + 3
        for row in 0..<8 {
            let w = row * 8
            if ws[w + 1] == 0, ws[w + 2] == 0, ws[w + 3] == 0, ws[w + 4] == 0, ws[w + 5] == 0, ws[w + 6] == 0,
               ws[w + 7] == 0 {
                let v = limit(descale(ws[w], pass1Bits + 3))
                for i in 0..<8 { full[w + i] = v }
                continue
            }
            var z2 = ws[w + 2], z3 = ws[w + 6]
            var z1 = (z2 &+ z3) &* f0541196100
            var tmp2 = z1 &+ z3 &* -f1847759065
            var tmp3 = z1 &+ z2 &* f0765366865
            var tmp0 = (ws[w] &+ ws[w + 4]) << constBits
            var tmp1 = (ws[w] &- ws[w + 4]) << constBits
            let tmp10 = tmp0 &+ tmp3, tmp13 = tmp0 &- tmp3, tmp11 = tmp1 &+ tmp2, tmp12 = tmp1 &- tmp2
            tmp0 = ws[w + 7]; tmp1 = ws[w + 5]; tmp2 = ws[w + 3]; tmp3 = ws[w + 1]
            z1 = tmp0 &+ tmp3; z2 = tmp1 &+ tmp2; z3 = tmp0 &+ tmp2
            var z4 = tmp1 &+ tmp3
            let z5 = (z3 &+ z4) &* f1175875602
            tmp0 = tmp0 &* f0298631336; tmp1 = tmp1 &* f2053119869
            tmp2 = tmp2 &* f3072711026; tmp3 = tmp3 &* f1501321110
            z1 = z1 &* -f0899976223; z2 = z2 &* -f2562915447; z3 = z3 &* -f1961570560; z4 = z4 &* -f0390180644
            z3 = z3 &+ z5; z4 = z4 &+ z5
            tmp0 = tmp0 &+ z1 &+ z3; tmp1 = tmp1 &+ z2 &+ z4; tmp2 = tmp2 &+ z2 &+ z3; tmp3 = tmp3 &+ z1 &+ z4
            full[w] = limit(descale(tmp10 &+ tmp3, n2)); full[w + 7] = limit(descale(tmp10 &- tmp3, n2))
            full[w + 1] = limit(descale(tmp11 &+ tmp2, n2)); full[w + 6] = limit(descale(tmp11 &- tmp2, n2))
            full[w + 2] = limit(descale(tmp12 &+ tmp1, n2)); full[w + 5] = limit(descale(tmp12 &- tmp1, n2))
            full[w + 3] = limit(descale(tmp13 &+ tmp0, n2)); full[w + 4] = limit(descale(tmp13 &- tmp0, n2))
        }
        if scale == 1 {
            for r in 0..<8 {
                for c in 0..<8 { out[offset + r * stride + c] = full[r * 8 + c] }
            }
            return
        }
        // 1/2 and 1/4: average the full-size block's samples.
        let side = 8 / scale, area = scale * scale
        for r in 0..<side {
            for c in 0..<side {
                var sum = 0
                for dy in 0..<scale {
                    for dx in 0..<scale { sum += Int(full[(r * scale + dy) * 8 + c * scale + dx]) }
                }
                out[offset + r * stride + c] = UInt8((sum + area / 2) / area)
            }
        }
    }

    // MARK: - Upsampling (libjpeg-turbo jdsample.c)

    /// A component's samples (`width × height` valid in a plane of `stride`)
    /// expanded by `fh × fv` and cut to `outWidth × outHeight`. 2×1, 1×2 and
    /// 2×2 use libjpeg's fancy (triangle) filters; other factors replicate.
    static func upsample(_ plane: [UInt8], stride: Int, width: Int, height: Int, fh: Int, fv: Int,
                         outWidth: Int, outHeight: Int, fancy: Bool = true) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: outWidth * outHeight)
        func s(_ x: Int, _ y: Int) -> Int32 { Int32(plane[min(y, height - 1) * stride + min(x, width - 1)]) }
        if fh == 1 && fv == 1 {
            for y in 0..<outHeight { for x in 0..<outWidth { out[y * outWidth + x] = UInt8(s(x, y)) } }
            return out
        }
        // libjpeg-turbo filters only when scaled blocks are larger than one
        // sample, and 2×n only when the component is wider than 2 samples.
        let fancy2 = fancy && width > 2
        if fh == 2 && fv == 1 && fancy2 {
            for y in 0..<outHeight {
                for x in 0..<outWidth {
                    let c = x / 2
                    let v: Int32
                    if x % 2 == 0 { v = c == 0 ? s(0, y) : (s(c, y) * 3 + s(c - 1, y) + 1) >> 2 }
                    else { v = c == width - 1 ? s(c, y) : (s(c, y) * 3 + s(c + 1, y) + 2) >> 2 }
                    out[y * outWidth + x] = UInt8(clamping: v)
                }
            }
            return out
        }
        if fh == 1 && fv == 2 && fancy {
            for y in 0..<outHeight {
                let r = y / 2
                let other = y % 2 == 0 ? max(r - 1, 0) : min(r + 1, height - 1)
                let bias: Int32 = y % 2 == 0 ? 1 : 2
                for x in 0..<outWidth {
                    out[y * outWidth + x] = UInt8(clamping: (s(x, r) * 3 + s(x, other) + bias) >> 2)
                }
            }
            return out
        }
        if fh == 2 && fv == 2 && fancy2 {
            var colsum = [Int32](repeating: 0, count: width)
            for y in 0..<outHeight {
                let r = y / 2
                let other = y % 2 == 0 ? max(r - 1, 0) : min(r + 1, height - 1)
                for c in 0..<width { colsum[c] = s(c, r) * 3 + s(c, other) }
                for x in 0..<outWidth {
                    let c = x / 2
                    let v: Int32
                    if x % 2 == 0 {
                        v = c == 0 ? (colsum[0] * 4 + 8) >> 4 : (colsum[c] * 3 + colsum[c - 1] + 8) >> 4
                    } else {
                        v = c == width - 1 ? (colsum[c] * 4 + 7) >> 4 : (colsum[c] * 3 + colsum[c + 1] + 7) >> 4
                    }
                    out[y * outWidth + x] = UInt8(clamping: v)
                }
            }
            return out
        }
        for y in 0..<outHeight {
            for x in 0..<outWidth { out[y * outWidth + x] = UInt8(s(x / fh, y / fv)) }
        }
        return out
    }

    // MARK: - Colour (libjpeg jdcolor.c)

    private static let crR: [Int32] = (0..<256).map { (Int32(91881) * Int32($0 - 128) + 32768) >> 16 }
    private static let cbB: [Int32] = (0..<256).map { (Int32(116130) * Int32($0 - 128) + 32768) >> 16 }
    private static let crG: [Int32] = (0..<256).map { -Int32(46802) * Int32($0 - 128) }
    private static let cbG: [Int32] = (0..<256).map { -Int32(22554) * Int32($0 - 128) + 32768 }

    @inline(__always)
    static func ycc(_ y: UInt8, _ cb: UInt8, _ cr: UInt8) -> (UInt8, UInt8, UInt8) {
        let yy = Int32(y)
        return (UInt8(clamping: yy + crR[Int(cr)]),
                UInt8(clamping: yy + ((cbG[Int(cb)] + crG[Int(cr)]) >> 16)),
                UInt8(clamping: yy + cbB[Int(cb)]))
    }
}

extension JPEG {
    /// The EXIF orientation (1–8) in the first APP1 `Exif` segment's IFD0, or
    /// nil when there is none or it is out of range. Every offset is checked
    /// against the segment (format.md §9); a malformed EXIF block reads as nil.
    static func exifOrientation(_ data: Data) -> Int? {
        let d = [UInt8](data)
        var found: Int?
        struct Done: Error {}
        do {
            try walk(d) { part in
                guard case let .marker(code, p, _) = part else { return }
                if code == 0xDA { throw Done() }
                guard code == 0xE1, p.count >= 14,
                      Array(d[p.lowerBound..<p.lowerBound + 6]) == [0x45, 0x78, 0x69, 0x66, 0, 0] else { return }
                found = tiffOrientation(Array(d[(p.lowerBound + 6)..<p.upperBound]))
                throw Done()
            }
        } catch {}
        return found
    }

    /// Tag 0x0112 of IFD0 of a TIFF structure (an EXIF payload).
    static func tiffOrientation(_ t: [UInt8]) -> Int? {
        guard t.count >= 8 else { return nil }
        let little: Bool
        switch (t[0], t[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func u16(_ i: Int) -> Int? {
            guard i >= 0, i + 2 <= t.count else { return nil }
            return little ? Int(t[i]) | Int(t[i + 1]) << 8 : Int(t[i]) << 8 | Int(t[i + 1])
        }
        func u32(_ i: Int) -> Int? {
            guard i >= 0, i + 4 <= t.count else { return nil }
            let b = (Int(t[i]), Int(t[i + 1]), Int(t[i + 2]), Int(t[i + 3]))
            return little ? b.0 | b.1 << 8 | b.2 << 16 | b.3 << 24 : b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3
        }
        guard u16(2) == 42, let ifd = u32(4), let count = u16(ifd) else { return nil }
        for e in 0..<count {
            let at = ifd + 2 + 12 * e
            guard let tag = u16(at) else { return nil }
            guard tag == 0x0112 else { continue }
            guard u16(at + 2) == 3, let v = u16(at + 8), (1...8).contains(v) else { return nil }
            return v
        }
        return nil
    }
}
