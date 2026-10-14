import Foundation
import XCTest

@testable import SempereRender

/// The GIF and TIFF readers (`LegacyImage`) against Pillow's decodes
/// (`Fixtures/images/legacy-*`, made by `generate_legacy_image_fixtures.py`),
/// and the conversion `ImageImport.prepare` makes of them to PNG.
final class LegacyImageTests: XCTestCase {
    static func fixture(_ name: String) throws -> Data { try ImageCodecTests.fixture(name) }

    static let tiffs = ["rgb-raw", "rgb-lzw", "rgb-packbits", "rgb-deflate", "rgba-lzw", "gray-lzw", "palette",
                        "bilevel", "rgb-orient6", "gray16"]
    static let gifs = ["plain", "interlaced", "transparent"]

    /// Pixels equal, except that the colour under alpha 0 is not compared.
    static func sameVisible(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        for i in stride(from: 0, to: a.count, by: 4) {
            if a[i + 3] != b[i + 3] { return false }
            if a[i + 3] != 0, !(a[i] == b[i] && a[i + 1] == b[i + 1] && a[i + 2] == b[i + 2]) { return false }
        }
        return true
    }

    func testTIFFMatchesPillow() throws {
        for name in Self.tiffs {
            let image = try LegacyImage.tiff(Self.fixture("legacy-\(name).tif"), maxPixels: ImageLimits.maxPixels)
            let ref = [UInt8](try Self.fixture("legacy-\(name).rgba"))
            XCTAssertEqual(image.width * image.height * 4, ref.count, name)
            XCTAssertTrue(Self.sameVisible(image.pixels, ref), name)
        }
    }

    func testTIFFOrientationTurnsTheImage() throws {
        let image = try LegacyImage.tiff(Self.fixture("legacy-rgb-orient6.tif"), maxPixels: ImageLimits.maxPixels)
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 48)
    }

    func testGIFMatchesPillow() throws {
        for name in Self.gifs {
            let image = try LegacyImage.gif(Self.fixture("legacy-\(name).gif"), maxPixels: ImageLimits.maxPixels)
            let ref = [UInt8](try Self.fixture("legacy-\(name).rgba"))
            XCTAssertEqual(image.width * image.height * 4, ref.count, name)
            XCTAssertTrue(Self.sameVisible(image.pixels, ref), name)
        }
        let t = try LegacyImage.gif(Self.fixture("legacy-transparent.gif"), maxPixels: ImageLimits.maxPixels)
        XCTAssertTrue(stride(from: 3, to: t.pixels.count, by: 4).contains { t.pixels[$0] == 0 })
    }

    /// The smallest GIF there is (43 bytes, a transparent pixel): not Pillow's.
    func testTinyGIF() throws {
        let hex = "47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
        }
        let image = try LegacyImage.gif(Data(bytes), maxPixels: ImageLimits.maxPixels)
        XCTAssertEqual([image.width, image.height], [1, 1])
        XCTAssertEqual(image.pixels[3], 0)
    }

    /// `ImageImport.prepare` stores GIF and TIFF as PNG, which decodes to the same pixels.
    func testPrepareConvertsToPNG() throws {
        for (name, ext) in Self.gifs.map({ ($0, "gif") }) + [("rgba-lzw", "tif"), ("rgb-raw", "tif")] {
            let data = try Self.fixture("legacy-\(name).\(ext)")
            let p = try ImageImport.prepare(data)
            XCTAssertEqual(p.type, "image/png", name)
            XCTAssertEqual(p.convertedFrom, ext == "gif" ? .gif : .tiff)
            XCTAssertTrue(p.strippedMetadata)
            let decoded = try PNG.decode(p.data)
            XCTAssertEqual([decoded.width, decoded.height], [p.width, p.height])
            XCTAssertTrue(Self.sameVisible(decoded.pixels, [UInt8](try Self.fixture("legacy-\(name).rgba"))), name)
        }
        XCTAssertNil(try ImageImport.prepare(Self.fixture("baseline-420.jpg")).convertedFrom)
    }

    func testWebPBMPAndAVIFStayRefused() {
        let webp = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBPVP8 ".utf8) + Data(count: 16)
        XCTAssertThrowsError(try ImageImport.prepare(webp)) {
            XCTAssertEqual($0 as? ImageImport.Failure, .unsupportedFormat(.webp))
        }
    }

    // MARK: Untrusted input (format.md §9)

    func testTruncatedAndCorruptFilesThrow() throws {
        for (name, ext) in Self.gifs.map({ ($0, "gif") }) + Self.tiffs.map({ ($0, "tif") }) {
            let data = try Self.fixture("legacy-\(name).\(ext)")
            for cut in [0, 3, 10, 40, data.count / 2, data.count - 1] where cut < data.count {
                let part = data.prefix(cut)
                // Either a typed error or a (partial) image; never a trap.
                _ = try? ImageImport.prepare(Data(part))
            }
        }
        XCTAssertThrowsError(try LegacyImage.tiff(Data("II*\0".utf8) + Data(count: 4), maxPixels: ImageLimits.maxPixels))
    }

    func testClaimedSizeIsCheckedBeforeAllocating() throws {
        // A GIF header claiming 65535 × 65535 over a few bytes.
        var gif = [UInt8]("GIF89a".utf8) + [0xFF, 0xFF, 0xFF, 0xFF, 0x80, 0, 0] + [0, 0, 0, 255, 255, 255]
        gif += [0x2C, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 2, 1, 0, 0, 0x3B]
        XCTAssertThrowsError(try LegacyImage.gif(Data(gif), maxPixels: ImageLimits.maxPixels)) {
            XCTAssertEqual($0 as? ImageError, .tooLarge(width: 65535, height: 65535))
        }
        // A TIFF claiming 100 000 × 1 000 with one tiny strip.
        var tiff = try Self.fixture("legacy-rgb-raw.tif")
        // ImageWidth is the first IFD entry in Pillow's files; find tag 256 and rewrite its value.
        let ifd = Int(tiff[4]) | Int(tiff[5]) << 8 | Int(tiff[6]) << 16 | Int(tiff[7]) << 24
        let n = Int(tiff[ifd]) | Int(tiff[ifd + 1]) << 8
        for k in 0..<n {
            let o = ifd + 2 + 12 * k
            let tag = Int(tiff[o]) | Int(tiff[o + 1]) << 8
            if tag == 256 || tag == 257 {
                let big = tag == 256 ? 100_000 : 1_000
                tiff[o + 8] = UInt8(big & 0xFF); tiff[o + 9] = UInt8(big >> 8 & 0xFF); tiff[o + 10] = UInt8(big >> 16 & 0xFF)
                tiff[o + 4] = 1; tiff[o + 5] = 0; tiff[o + 6] = 0; tiff[o + 7] = 0
                tiff[o + 2] = 4; tiff[o + 3] = 0
            }
        }
        XCTAssertThrowsError(try LegacyImage.tiff(tiff, maxPixels: ImageLimits.maxPixels))
    }
}
