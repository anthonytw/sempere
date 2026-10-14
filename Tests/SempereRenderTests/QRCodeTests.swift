import Foundation
import FuzzSupport
import XCTest
@testable import SempereRender

final class QRCodeTests: XCTestCase {
    private struct Vector: Decodable {
        var mode: String
        var text: String
        var ecc: String
        var mask: Int
        var version: Int
        var chosenMask: Int
        var modules: String
    }

    private static let levels: [String: QRCode.ErrorCorrection] = ["L": .low, "M": .medium, "Q": .quartile, "H": .high]

    private func unpack(_ hex: String, size: Int) -> [Bool] {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return (0..<size * size).map { bytes[$0 >> 3] & (0x80 >> UInt8($0 & 7)) != 0 }
    }

    // MARK: - Building blocks against values from ISO/IEC 18004

    /// "HELLO WORLD", 1-M: the worked example of thonky.com's QR tutorial
    /// (data codewords and Reed-Solomon codewords).
    func testHelloWorldCodewords() {
        var bits = BitBuffer()
        bits.append(0b0010, count: 4)
        bits.append(11, count: 9)
        let values = "HELLO WORLD".map { QRCode.alphanumericCharset.firstIndex(of: $0)! }
            .map { QRCode.alphanumericCharset.distance(from: QRCode.alphanumericCharset.startIndex, to: $0) }
        for k in stride(from: 0, to: 10, by: 2) { bits.append(values[k] * 45 + values[k + 1], count: 11) }
        bits.append(values[10], count: 6)
        bits.append(0, count: 4)
        bits.append(0, count: (8 - bits.count % 8) % 8)
        var pad = 0xEC
        while bits.count < 16 * 8 { bits.append(pad, count: 8); pad ^= 0xEC ^ 0x11 }
        XCTAssertEqual(bits.bytes, [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17])
        let ecc = ReedSolomon.remainder(bits.bytes, divisor: ReedSolomon.generator(degree: 10))
        XCTAssertEqual(ecc, [196, 35, 39, 119, 235, 215, 231, 226, 93, 23])
        XCTAssertEqual(QRCode.interleavedCodewords(data: bits.bytes, version: 1, correction: .medium),
                       bits.bytes + ecc)
    }

    func testFormatAndVersionBits() {
        // ISO 18004 Annex C, Table C.1 (after the 0x5412 mask) and Annex D, Table D.1.
        XCTAssertEqual(QRCode.formatBits(correction: .low, mask: 0), 0b111011111000100)
        XCTAssertEqual(QRCode.formatBits(correction: .medium, mask: 0), 0b101010000010010)
        XCTAssertEqual(QRCode.formatBits(correction: .quartile, mask: 0), 0b011010101011111)
        XCTAssertEqual(QRCode.formatBits(correction: .high, mask: 0), 0b001011010001001)
        XCTAssertEqual(QRCode.formatBits(correction: .low, mask: 4), 0b110011000101111)
        XCTAssertEqual(QRCode.versionBits(7), 0b000111110010010100)
        XCTAssertEqual(QRCode.versionBits(40), 0b101000110001101001)
    }

    func testAlignmentPositions() {
        XCTAssertEqual(QRCode.alignmentPositions(version: 1), [])
        XCTAssertEqual(QRCode.alignmentPositions(version: 2), [6, 18])
        XCTAssertEqual(QRCode.alignmentPositions(version: 7), [6, 22, 38])
        XCTAssertEqual(QRCode.alignmentPositions(version: 32), [6, 34, 60, 86, 112, 138])
        XCTAssertEqual(QRCode.alignmentPositions(version: 36), [6, 24, 50, 76, 102, 128, 154])
        XCTAssertEqual(QRCode.alignmentPositions(version: 40), [6, 30, 58, 86, 114, 142, 170])
    }

    func testCapacityTable() {
        // Byte-mode capacities from ISO 18004 Table 7.
        let expected: [(Int, QRCode.ErrorCorrection, Int)] = [
            (1, .low, 17), (1, .medium, 14), (1, .quartile, 11), (1, .high, 7),
            (5, .medium, 84), (6, .quartile, 74), (10, .medium, 213), (16, .medium, 450), (18, .medium, 560),
            (40, .low, 2953), (40, .medium, 2331), (40, .quartile, 1663), (40, .high, 1273),
        ]
        for (v, l, n) in expected { XCTAssertEqual(QRCode.byteCapacity(version: v, correction: l), n, "\(v)-\(l)") }
        // Every block layout fills the symbol exactly.
        for l in QRCode.ErrorCorrection.allCases {
            for v in 1...40 {
                let raw = QRCode.numRawDataModules(version: v) / 8
                let blocks = QRCode.eccBlocks[l.rawValue][v]
                XCTAssertGreaterThan(QRCode.numDataCodewords(version: v, correction: l), 0)
                XCTAssertGreaterThanOrEqual(raw / blocks, QRCode.eccCodewordsPerBlock[l.rawValue][v] + 1)
            }
        }
    }

    // MARK: - Whole symbols against an independent implementation

    /// Module-for-module equality with Project Nayuki's qrcodegen (see
    /// generate_qr_vectors.py), versions 1 to 39, every level and mask.
    func testMatchesReferenceVectors() throws {
        let data = try Data(contentsOf: try T.fixtureURL("qr-vectors.json"))
        let vectors = try JSONDecoder().decode([Vector].self, from: data)
        XCTAssertGreaterThanOrEqual(vectors.count, 21)
        XCTAssertTrue(vectors.contains { $0.text.hasPrefix("AGE-SECRET-KEY-PQ-1") && $0.ecc == "Q" && $0.version == 7 },
                      "a post-quantum identity (77 characters) needs version 7 at level Q")
        for v in vectors {
            let level = try XCTUnwrap(Self.levels[v.ecc])
            let mask = v.mask < 0 ? nil : v.mask
            let code = v.mode == "byte"
                ? try QRCode.encode(text: v.text, correction: level, mask: mask)
                : try QRCode.encodeAlphanumeric(v.text, correction: level, mask: mask)
            let label = "\(v.mode) \(v.ecc) \(v.text.prefix(20))… (\(v.text.count))"
            XCTAssertEqual(code.version, v.version, label)
            XCTAssertEqual(code.mask, v.chosenMask, label)
            XCTAssertEqual(code.size, 4 * v.version + 17, label)
            XCTAssertEqual(code.modules, unpack(v.modules, size: code.size), label)
        }
    }

    // MARK: - Structure

    func testAgeKeyStructure() throws {
        let key = "AGE-SECRET-KEY-1JQ4L7CGCHC2TE7JUJ7YG4Y4DREUWFD7Y6U5XKFZ3EYTNY62Z5PES6MWJVN"
        let code = try QRCode.encode(text: key, correction: .quartile)
        XCTAssertEqual(code.version, 6)
        XCTAssertEqual(code.size, 41)
        // Finder patterns: dark 7x7 ring, light ring, dark 3x3 core; separators light.
        for (ox, oy) in [(0, 0), (code.size - 7, 0), (0, code.size - 7)] {
            for d in 0..<7 {
                XCTAssertTrue(code[ox + d, oy]); XCTAssertTrue(code[ox + d, oy + 6])
                XCTAssertTrue(code[ox, oy + d]); XCTAssertTrue(code[ox + 6, oy + d])
            }
            for d in 1..<6 { XCTAssertFalse(code[ox + d, oy + 1]); XCTAssertFalse(code[ox + 1, oy + d]) }
            for dx in 2..<5 { for dy in 2..<5 { XCTAssertTrue(code[ox + dx, oy + dy]) } }
        }
        // Timing patterns alternate.
        for i in 8..<(code.size - 8) {
            XCTAssertEqual(code[i, 6], i % 2 == 0)
            XCTAssertEqual(code[6, i], i % 2 == 0)
        }
        // The dark module, and the quiet zone reads light.
        XCTAssertTrue(code[8, code.size - 8])
        XCTAssertFalse(code[-1, 0])
        XCTAssertFalse(code[code.size, 3])
        // Both copies of the format information agree with level and mask.
        let bits = QRCode.formatBits(correction: .quartile, mask: code.mask)
        var first = 0, second = 0
        let firstCells = (0...5).map { (8, $0) } + [(8, 7), (8, 8), (7, 8)] + (9..<15).map { (14 - $0, 8) }
        for (i, c) in firstCells.enumerated() where code[c.0, c.1] { first |= 1 << i }
        let secondCells = (0..<8).map { (code.size - 1 - $0, 8) } + (8..<15).map { (8, code.size - 15 + $0) }
        for (i, c) in secondCells.enumerated() where code[c.0, c.1] { second |= 1 << i }
        XCTAssertEqual(first, bits)
        XCTAssertEqual(second, bits)
    }

    func testSmallestVersionIsChosen() throws {
        XCTAssertEqual(try QRCode.encode([UInt8](repeating: 65, count: 14), correction: .medium).version, 1)
        XCTAssertEqual(try QRCode.encode([UInt8](repeating: 65, count: 15), correction: .medium).version, 2)
        XCTAssertEqual(try QRCode.encode([UInt8](repeating: 65, count: 84), correction: .medium).version, 5)
        XCTAssertEqual(try QRCode.encode([UInt8](repeating: 65, count: 85), correction: .medium).version, 6)
        XCTAssertEqual(try QRCode.encode([UInt8](repeating: 65, count: 2953), correction: .low).version, 40)
    }

    func testErrors() {
        XCTAssertThrowsError(try QRCode.encode([UInt8](repeating: 0, count: 2954), correction: .low)) {
            XCTAssertEqual($0 as? QRCode.EncodeError, .dataTooLong(bytes: 2954, maxVersion: 40))
        }
        XCTAssertThrowsError(try QRCode.encode([UInt8](repeating: 0, count: 100), maxVersion: 3))
        XCTAssertThrowsError(try QRCode.encodeAlphanumeric("lower case"))
        XCTAssertThrowsError(try QRCode.encode([1], mask: 8))
        XCTAssertThrowsError(try QRCode.encode([1], minVersion: 0))
    }

    // MARK: - Decoding with zbar, where installed

    /// Renders `code` as a PNG with a 4-module quiet zone.
    static func png(_ code: QRCode, scale: Int = 4) throws -> Data {
        let n = (code.size + 8) * scale
        var rgba = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n where code[x / scale - 4, y / scale - 4] {
                let i = (y * n + x) * 4
                rgba[i] = 0; rgba[i + 1] = 0; rgba[i + 2] = 0
            }
        }
        return try PNGEncoder.encode(width: n, height: n, rgba: rgba)
    }

    /// `zbarimg --raw` on a PNG; nil when zbarimg is not installed.
    static func zbar(_ png: Data) throws -> Data? {
        guard let tool = ExternalTool.find("zbarimg") else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("qr-\(UUID().uuidString).png")
        try png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // -Sbinary: the payload bytes exactly, no trailing newline added.
        return try ExternalTool.run(tool, ["--raw", "-q", "-Sbinary", file.path]).out
    }

    func testZbarDecodesEveryLevelAndManyVersions() throws {
        guard try Self.zbar(Self.png(try QRCode.encode(text: "probe"))) != nil else {
            if RequiredTools.isRequired("zbar") { XCTFail("zbarimg not installed and SEMPERE_REQUIRE_TOOLS names zbar") }
            throw XCTSkip("zbarimg not installed (apt install zbar-tools)")
        }
        let key = "AGE-SECRET-KEY-1JQ4L7CGCHC2TE7JUJ7YG4Y4DREUWFD7Y6U5XKFZ3EYTNY62Z5PES6MWJVN"
        var payloads = [key, "x", String(repeating: "0123456789", count: 30)]
        payloads.append((0..<600).map { String(UnicodeScalar(UInt8(33 + ($0 * 13) % 94))) }.joined())
        payloads.append(String(repeating: "-----BEGIN AGE ENCRYPTED FILE-----\n", count: 30))
        var versions = Set<Int>()
        for p in payloads {
            for level in QRCode.ErrorCorrection.allCases {
                let code = try QRCode.encode(text: p, correction: level)
                versions.insert(code.version)
                let decoded = try XCTUnwrap(try Self.zbar(Self.png(code)))
                XCTAssertEqual(String(decoding: decoded, as: UTF8.self), p,
                               "version \(code.version) level \(level)")
            }
        }
        XCTAssertGreaterThanOrEqual(versions.count, 12)
        for mask in 0..<8 {
            let code = try QRCode.encode(text: key, correction: .quartile, mask: mask)
            XCTAssertEqual(String(decoding: try XCTUnwrap(try Self.zbar(Self.png(code))), as: UTF8.self), key)
        }
    }
}
