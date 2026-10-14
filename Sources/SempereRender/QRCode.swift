import Foundation

/// A QR Code symbol (ISO/IEC 18004:2015, Model 2), encoded in pure Swift.
///
/// Scope: one segment in byte or alphanumeric mode, versions 1 to 40, all
/// four error correction levels, automatic or fixed mask. No ECI, Kanji,
/// structured append or Micro QR. The recovery kit (`RecoveryKit`) prints an
/// age identity with it; tests check it against reference vectors and, where
/// `zbarimg` is installed, by decoding the rendered symbol.
public struct QRCode: Hashable, Sendable {
    /// Error correction level, with the share of codewords that can be restored.
    public enum ErrorCorrection: Int, CaseIterable, Hashable, Sendable {
        /// About 7 %.
        case low
        /// About 15 %.
        case medium
        /// About 25 %.
        case quartile
        /// About 30 %.
        case high

        /// The two format-information bits (ISO 18004 Table 12).
        var formatBits: Int {
            switch self {
            case .low: return 1
            case .medium: return 0
            case .quartile: return 3
            case .high: return 2
            }
        }
    }

    /// Encoding mode of the single data segment.
    public enum Mode: Hashable, Sendable {
        /// Any bytes, 8 bits each.
        case byte
        /// `0-9`, `A-Z`, space and `$%*+-./:`, 5.5 bits per character.
        case alphanumeric
    }

    /// Why a payload cannot be encoded.
    public enum EncodeError: Error, Hashable, Sendable {
        /// The data does not fit the largest allowed version.
        case dataTooLong(bytes: Int, maxVersion: Int)
        /// A character outside the alphanumeric set in alphanumeric mode.
        case notAlphanumeric
        /// A version outside 1...40, or min > max, or a mask outside 0...7.
        case invalidParameter(String)
    }

    /// Version, 1 (21×21 modules) to 40 (177×177).
    public let version: Int
    /// Modules per side: `4 × version + 17`.
    public let size: Int
    /// The error correction level used.
    public let errorCorrection: ErrorCorrection
    /// The data mask pattern used, 0...7.
    public let mask: Int
    /// Row-major, `true` = dark. Excludes the quiet zone.
    public let modules: [Bool]

    /// Whether the module at column `x`, row `y` is dark. Outside the symbol
    /// (the quiet zone) is light.
    public subscript(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        return modules[y * size + x]
    }

    /// The symbol as text rows, `#` dark and `.` light, top row first.
    public var rows: [String] {
        (0..<size).map { y in String((0..<size).map { self[$0, y] ? "#" : "." }) }
    }

    // MARK: - Encoding

    /// Encodes `data` in byte mode at the smallest version that holds it.
    ///
    /// - Parameters:
    ///   - mask: a fixed mask 0...7; nil picks the one with the lowest penalty.
    public static func encode(_ data: [UInt8], correction: ErrorCorrection = .medium, minVersion: Int = 1,
                              maxVersion: Int = 40, mask: Int? = nil) throws -> QRCode {
        try encode(segment: Segment(mode: .byte, count: data.count, bits: byteBits(data)),
                   correction: correction, minVersion: minVersion, maxVersion: maxVersion, mask: mask)
    }

    /// Encodes the UTF-8 bytes of `text` in byte mode.
    public static func encode(text: String, correction: ErrorCorrection = .medium, minVersion: Int = 1,
                              maxVersion: Int = 40, mask: Int? = nil) throws -> QRCode {
        try encode(Array(text.utf8), correction: correction, minVersion: minVersion, maxVersion: maxVersion, mask: mask)
    }

    /// Encodes `text` in alphanumeric mode (uppercase letters, digits and `$%*+-./:` and space).
    public static func encodeAlphanumeric(_ text: String, correction: ErrorCorrection = .medium, minVersion: Int = 1,
                                          maxVersion: Int = 40, mask: Int? = nil) throws -> QRCode {
        var values: [Int] = []
        for ch in text.unicodeScalars {
            guard let i = alphanumericCharset.firstIndex(of: Character(ch)) else { throw EncodeError.notAlphanumeric }
            values.append(alphanumericCharset.distance(from: alphanumericCharset.startIndex, to: i))
        }
        var bits = BitBuffer()
        var i = 0
        while i + 1 < values.count {
            bits.append(values[i] * 45 + values[i + 1], count: 11)
            i += 2
        }
        if i < values.count { bits.append(values[i], count: 6) }
        return try encode(segment: Segment(mode: .alphanumeric, count: values.count, bits: bits),
                          correction: correction, minVersion: minVersion, maxVersion: maxVersion, mask: mask)
    }

    static let alphanumericCharset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

    struct Segment {
        var mode: Mode
        var count: Int
        var bits: BitBuffer

        var modeIndicator: Int { mode == .byte ? 0b0100 : 0b0010 }

        func countBits(version: Int) -> Int {
            switch mode {
            case .byte: return version <= 9 ? 8 : 16
            case .alphanumeric: return version <= 9 ? 9 : version <= 26 ? 11 : 13
            }
        }

        /// Total bits at `version`, or nil when the count does not fit its field.
        func totalBits(version: Int) -> Int? {
            let cb = countBits(version: version)
            guard count < 1 << cb else { return nil }
            return 4 + cb + bits.count
        }
    }

    static func byteBits(_ data: [UInt8]) -> BitBuffer {
        var b = BitBuffer()
        for byte in data { b.append(Int(byte), count: 8) }
        return b
    }

    static func encode(segment: Segment, correction: ErrorCorrection, minVersion: Int, maxVersion: Int,
                       mask: Int?) throws -> QRCode {
        guard 1 <= minVersion, minVersion <= maxVersion, maxVersion <= 40 else {
            throw EncodeError.invalidParameter("versions \(minVersion)...\(maxVersion)")
        }
        if let mask, !(0...7).contains(mask) { throw EncodeError.invalidParameter("mask \(mask)") }
        var version = minVersion
        while true {
            let capacity = numDataCodewords(version: version, correction: correction) * 8
            if let used = segment.totalBits(version: version), used <= capacity { break }
            guard version < maxVersion else {
                throw EncodeError.dataTooLong(bytes: (segment.bits.count + 7) / 8, maxVersion: maxVersion)
            }
            version += 1
        }
        var bits = BitBuffer()
        bits.append(segment.modeIndicator, count: 4)
        bits.append(segment.count, count: segment.countBits(version: version))
        bits.append(segment.bits)
        let capacity = numDataCodewords(version: version, correction: correction) * 8
        bits.append(0, count: min(4, capacity - bits.count))    // terminator
        bits.append(0, count: (8 - bits.count % 8) % 8)          // byte align
        var pad = 0xEC
        while bits.count < capacity {
            bits.append(pad, count: 8)
            pad ^= 0xEC ^ 0x11
        }
        let codewords = interleavedCodewords(data: bits.bytes, version: version, correction: correction)
        var m = Matrix(version: version)
        m.drawFunctionPatterns(correction: correction)
        m.drawCodewords(codewords)
        let chosen: Int
        if let mask {
            chosen = mask
        } else {
            var best = 0
            var bestPenalty = Int.max
            for candidate in 0..<8 {
                var trial = m
                trial.applyMask(candidate)
                trial.drawFormatBits(correction: correction, mask: candidate)
                let p = trial.penalty()
                if p < bestPenalty { bestPenalty = p; best = candidate }
            }
            chosen = best
        }
        m.applyMask(chosen)
        m.drawFormatBits(correction: correction, mask: chosen)
        return QRCode(version: version, size: m.size, errorCorrection: correction, mask: chosen, modules: m.modules)
    }

    // MARK: - Capacity tables (ISO 18004 Table 9)

    /// Error correction codewords per block, indexed `[level][version]`.
    static let eccCodewordsPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30,
         30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28,
         28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30,
         30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30,
         30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]

    /// Number of error correction blocks, indexed `[level][version]`.
    static let eccBlocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18,
         19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29,
         31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40,
         43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45,
         48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]

    /// Modules available for data and error correction (everything but
    /// function patterns and format/version information).
    static func numRawDataModules(version v: Int) -> Int {
        var result = (16 * v + 128) * v + 64
        if v >= 2 {
            let numAlign = v / 7 + 2
            result -= (25 * numAlign - 10) * numAlign - 55
            if v >= 7 { result -= 36 }
        }
        return result
    }

    /// Data codewords (8-bit) a symbol of this version and level holds.
    static func numDataCodewords(version: Int, correction: ErrorCorrection) -> Int {
        numRawDataModules(version: version) / 8
            - eccCodewordsPerBlock[correction.rawValue][version] * eccBlocks[correction.rawValue][version]
    }

    /// Byte-mode capacity in bytes (what `encode` accepts at this version).
    public static func byteCapacity(version: Int, correction: ErrorCorrection) -> Int {
        let countBits = version <= 9 ? 8 : 16
        return min((numDataCodewords(version: version, correction: correction) * 8 - 4 - countBits) / 8,
                   (1 << countBits) - 1)
    }

    /// Splits data into blocks, appends Reed-Solomon codewords to each and
    /// interleaves them (ISO 18004 §7.6).
    static func interleavedCodewords(data: [UInt8], version: Int, correction: ErrorCorrection) -> [UInt8] {
        let numBlocks = eccBlocks[correction.rawValue][version]
        let eccLen = eccCodewordsPerBlock[correction.rawValue][version]
        let rawCodewords = numRawDataModules(version: version) / 8
        let numShortBlocks = numBlocks - rawCodewords % numBlocks
        let shortBlockLen = rawCodewords / numBlocks
        let divisor = ReedSolomon.generator(degree: eccLen)
        var blocks: [[UInt8]] = []
        var k = 0
        for i in 0..<numBlocks {
            let len = shortBlockLen - eccLen + (i < numShortBlocks ? 0 : 1)
            var block = Array(data[k..<k + len])
            k += len
            let ecc = ReedSolomon.remainder(block, divisor: divisor)
            if i < numShortBlocks { block.append(0) }   // placeholder, skipped below
            blocks.append(block + ecc)
        }
        var out: [UInt8] = []
        out.reserveCapacity(rawCodewords)
        for i in 0..<blocks[0].count {
            for (j, b) in blocks.enumerated() where i != shortBlockLen - eccLen || j >= numShortBlocks {
                out.append(b[i])
            }
        }
        return out
    }

    /// Positions of alignment pattern centres along one axis.
    static func alignmentPositions(version v: Int) -> [Int] {
        guard v > 1 else { return [] }
        let numAlign = v / 7 + 2
        let step = (v * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4) * 2
        var result = [6]
        var pos = 4 * v + 17 - 7
        while result.count < numAlign {
            result.insert(pos, at: 1)
            pos -= step
        }
        return result
    }

    /// The 15 format bits (level, mask, BCH(15,5), XOR 0x5412).
    static func formatBits(correction: ErrorCorrection, mask: Int) -> Int {
        let data = correction.formatBits << 3 | mask
        var rem = data
        for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
        return (data << 10 | rem) ^ 0x5412
    }

    /// The 18 version bits (version, BCH(18,6)); only drawn for version ≥ 7.
    static func versionBits(_ v: Int) -> Int {
        var rem = v
        for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
        return v << 12 | rem
    }
}

/// An append-only bit sequence, most significant bit first.
struct BitBuffer: Hashable {
    private(set) var bits: [Bool] = []
    var count: Int { bits.count }

    mutating func append(_ value: Int, count n: Int) {
        for i in stride(from: n - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
    }

    mutating func append(_ other: BitBuffer) { bits += other.bits }

    /// Packs the bits into bytes; `count` must be a multiple of 8.
    var bytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (i, b) in bits.enumerated() where b { out[i >> 3] |= 0x80 >> UInt8(i & 7) }
        return out
    }
}

/// Reed-Solomon over GF(2^8) with the QR polynomial 0x11D.
enum ReedSolomon {
    static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> i) & 1) * Int(x)
        }
        return UInt8(z)
    }

    /// Generator polynomial coefficients (highest degree first, leading 1 dropped).
    static func generator(degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    /// The error correction codewords of `data` for `divisor`.
    static func remainder(_ data: [UInt8], divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for b in data {
            let factor = b ^ result.removeFirst()
            result.append(0)
            for i in result.indices { result[i] ^= multiply(divisor[i], factor) }
        }
        return result
    }
}

/// The module grid under construction.
struct Matrix {
    let version: Int
    let size: Int
    var modules: [Bool]
    var isFunction: [Bool]

    init(version: Int) {
        self.version = version
        size = 4 * version + 17
        modules = [Bool](repeating: false, count: size * size)
        isFunction = modules
    }

    subscript(x: Int, y: Int) -> Bool { modules[y * size + x] }

    mutating func setFunction(_ x: Int, _ y: Int, _ dark: Bool) {
        modules[y * size + x] = dark
        isFunction[y * size + x] = true
    }

    mutating func drawFunctionPatterns(correction: QRCode.ErrorCorrection) {
        for i in 0..<size {
            setFunction(6, i, i % 2 == 0)
            setFunction(i, 6, i % 2 == 0)
        }
        drawFinder(3, 3)
        drawFinder(size - 4, 3)
        drawFinder(3, size - 4)
        let pos = QRCode.alignmentPositions(version: version)
        let n = pos.count
        for i in 0..<n {
            for j in 0..<n where !(i == 0 && j == 0) && !(i == 0 && j == n - 1) && !(i == n - 1 && j == 0) {
                for dy in -2...2 {
                    for dx in -2...2 { setFunction(pos[i] + dx, pos[j] + dy, max(abs(dx), abs(dy)) != 1) }
                }
            }
        }
        // Reserve the format areas (overwritten after masking).
        drawFormatBits(correction: correction, mask: 0)
        if version >= 7 {
            let bits = QRCode.versionBits(version)
            for i in 0..<18 {
                let dark = (bits >> i) & 1 == 1
                let a = size - 11 + i % 3, b = i / 3
                setFunction(a, b, dark)
                setFunction(b, a, dark)
            }
        }
    }

    private mutating func drawFinder(_ x: Int, _ y: Int) {
        for dy in -4...4 {
            for dx in -4...4 {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, xx < size, yy >= 0, yy < size else { continue }
                let dist = max(abs(dx), abs(dy))
                setFunction(xx, yy, dist != 2 && dist != 4)
            }
        }
    }

    mutating func drawFormatBits(correction: QRCode.ErrorCorrection, mask: Int) {
        let bits = QRCode.formatBits(correction: correction, mask: mask)
        func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
        for i in 0...5 { setFunction(8, i, bit(i)) }
        setFunction(8, 7, bit(6))
        setFunction(8, 8, bit(7))
        setFunction(7, 8, bit(8))
        for i in 9..<15 { setFunction(14 - i, 8, bit(i)) }
        for i in 0..<8 { setFunction(size - 1 - i, 8, bit(i)) }
        for i in 8..<15 { setFunction(8, size - 15 + i, bit(i)) }
        setFunction(8, size - 8, true)   // the dark module
    }

    /// Places codeword bits in the zigzag order of ISO 18004 §7.7.3.
    mutating func drawCodewords(_ data: [UInt8]) {
        var i = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vert in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = (right + 1) & 2 == 0
                    let y = upward ? size - 1 - vert : vert
                    if !isFunction[y * size + x] && i < data.count * 8 {
                        modules[y * size + x] = (data[i >> 3] >> (7 - UInt8(i & 7))) & 1 == 1
                        i += 1
                    }
                }
            }
            right -= 2
        }
    }

    /// XORs the data modules with mask pattern `mask` (ISO 18004 Table 10).
    mutating func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size where !isFunction[y * size + x] {
                let invert: Bool
                switch mask {
                case 0: invert = (x + y) % 2 == 0
                case 1: invert = y % 2 == 0
                case 2: invert = x % 3 == 0
                case 3: invert = (x + y) % 3 == 0
                case 4: invert = (x / 3 + y / 2) % 2 == 0
                case 5: invert = x * y % 2 + x * y % 3 == 0
                case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                }
                if invert { modules[y * size + x].toggle() }
            }
        }
    }

    /// The mask evaluation penalty of ISO 18004 §7.8.3.
    func penalty() -> Int {
        let n1 = 3, n2 = 3, n3 = 40, n4 = 10
        var result = 0
        for horizontal in [true, false] {
            for a in 0..<size {
                var runColor = false
                var runLength = 0
                var history = [Int](repeating: 0, count: 7)
                for b in 0..<size {
                    let dark = horizontal ? self[b, a] : self[a, b]
                    if dark == runColor {
                        runLength += 1
                        if runLength == 5 { result += n1 } else if runLength > 5 { result += 1 }
                    } else {
                        addHistory(runLength, &history)
                        if !runColor { result += countFinderLike(history) * n3 }
                        runColor = dark
                        runLength = 1
                    }
                }
                if runColor {
                    addHistory(runLength, &history)
                    runLength = 0
                }
                runLength += size   // light border
                addHistory(runLength, &history)
                result += countFinderLike(history) * n3
            }
        }
        for y in 0..<size - 1 {
            for x in 0..<size - 1 {
                let c = self[x, y]
                if c == self[x + 1, y] && c == self[x, y + 1] && c == self[x + 1, y + 1] { result += n2 }
            }
        }
        let dark = modules.reduce(0) { $0 + ($1 ? 1 : 0) }
        let total = size * size
        let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
        result += k * n4
        return result
    }

    private func addHistory(_ length: Int, _ history: inout [Int]) {
        var length = length
        if history[0] == 0 { length += size }   // light border before the first run
        history.removeLast()
        history.insert(length, at: 0)
    }

    private func countFinderLike(_ h: [Int]) -> Int {
        let n = h[1]
        let core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n
        return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0)
    }
}
