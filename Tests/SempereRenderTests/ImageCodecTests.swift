import Foundation
import XCTest

@testable import SempereRender

/// The JPEG and PNG decoders against reference decodes (`Fixtures/images`,
/// made by `generate_image_fixtures.py`: libjpeg-turbo through Pillow for
/// JPEG; samples computed in Python, cross-checked with Pillow, for PNG).
final class ImageCodecTests: XCTestCase {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: T.fixtureURL("images/" + name))
    }

    static let jpegs = ["baseline-444", "baseline-422", "baseline-420", "progressive-420", "progressive-444",
                        "restart-420", "grey", "grey-progressive", "tiny-420", "wide-420", "magick-440",
                        "magick-411", "magick-progressive-restart", "metadata"]

    /// Largest per-channel difference between two RGBA buffers.
    static func maxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    /// Bit-exact: the decoder follows libjpeg-turbo's integer IDCT,
    /// upsampling and colour tables (the task's bar was ±2 per channel).
    func testJPEGMatchesLibjpegTurbo() throws {
        for name in Self.jpegs + ["quadrants"] {
            let data = try Self.fixture(name + ".jpg")
            let ref = [UInt8](try Self.fixture(name + ".rgba"))
            let image = try JPEG.decode(data)
            XCTAssertEqual(image.width * image.height * 4, ref.count, name)
            XCTAssertEqual(Self.maxDiff(image.pixels, ref), 0, name)
        }
    }

    /// Security review 2026-10 stage 4, S15: list previews decode stored images only as items are drawn —
    /// JPEG and PNG here, nothing else without the app's decoder — within the pixel limit, reduced.
    func testImagePreviewDecodesOnlyWhatItemsDecode() throws {
        let jpeg = try Self.fixture("baseline-420.jpg")
        let full = try JPEG.decode(jpeg)
        let small = try XCTUnwrap(ImagePreview.image(jpeg, type: "image/jpeg", side: 16, decoder: nil))
        XCTAssertLessThan(max(small.width, small.height), max(full.width, full.height))
        XCTAssertGreaterThanOrEqual(max(small.width, small.height), 8)
        let png = try PNGEncoder.encode(width: 4, height: 3, rgba: [UInt8](repeating: 200, count: 48))
        let p = try XCTUnwrap(ImagePreview.image(png, type: "image/png", side: 64, decoder: nil))
        XCTAssertEqual([p.width, p.height], [4, 3])
        // GIF (and anything not JPEG or PNG) is never decoded without a decoder for it.
        let gif = Data("GIF89a".utf8) + Data([1, 0, 1, 0, 0, 0, 0, 0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3B])
        XCTAssertNil(ImagePreview.image(gif, type: "image/gif", side: 16, decoder: nil))
        XCTAssertNil(ImagePreview.image(Data("not an image".utf8), type: "image/jpeg", side: 16, decoder: nil))
        // Beyond the pixel limit: refused from the header.
        XCTAssertNil(ImagePreview.image(jpeg, type: "image/jpeg", side: 16, decoder: nil, maxPixels: 16))
    }

    func testJPEGInfo() throws {
        let i = try JPEG.info(Self.fixture("baseline-420.jpg"))
        XCTAssertEqual(i, JPEG.Info(width: 61, height: 45, components: 3, progressive: false, isRGB: false))
        XCTAssertTrue(try JPEG.info(Self.fixture("progressive-420.jpg")).progressive)
        XCTAssertEqual(try JPEG.info(Self.fixture("grey.jpg")).components, 1)
        XCTAssertThrowsError(try JPEG.info(Self.fixture("cmyk.jpg"))) {
            XCTAssertEqual($0 as? ImageError, .unsupported("CMYK JPEG"))
        }
        XCTAssertThrowsError(try JPEG.decode(Self.fixture("cmyk.jpg")))
    }

    /// DCT scaling: 1/2, 1/4 and 1/8 decode to the rounded-up size and stay
    /// close to an area average of the full decode.
    func testJPEGScaledDecode() throws {
        let data = try Self.fixture("baseline-444.jpg")
        let full = try JPEG.decode(data)
        for s in [2, 4, 8] {
            let img = try JPEG.decode(data, scale: s)
            XCTAssertEqual(img.width, (61 + s - 1) / s)
            XCTAssertEqual(img.height, (45 + s - 1) / s)
            // Compare an interior pixel with the average of its full-size block.
            let x = 1, y = 1
            for c in 0..<3 {
                var sum = 0
                for dy in 0..<s { for dx in 0..<s { sum += Int(full.pixels[((y * s + dy) * 61 + x * s + dx) * 4 + c]) } }
                let avg = sum / (s * s)
                XCTAssertLessThanOrEqual(abs(Int(img.pixels[(y * img.width + x) * 4 + c]) - avg), 12, "scale \(s)")
            }
        }
        XCTAssertEqual(JPEG.scale(width: 4000, height: 3000, minWidth: 400, minHeight: 300), 8)
        XCTAssertEqual(JPEG.scale(width: 4000, height: 3000, minWidth: 1100, minHeight: 300), 2)
        XCTAssertEqual(JPEG.scale(width: 4000, height: 3000, minWidth: 4000, minHeight: 1), 1)
    }

    /// Stripping removes APP1 (EXIF with GPS, XMP) and COM but leaves the
    /// image data and what PDF needs (JFIF, ICC, Adobe) alone.
    func testJPEGStripMetadata() throws {
        let data = try Self.fixture("metadata.jpg")
        XCTAssertTrue(Self.segments(data).contains(0xE1))
        XCTAssertTrue(Self.segments(data).contains(0xFE))
        var withTail = data
        withTail.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xE1, 0, 4, 1, 2])   // a trailing "preview"
        let stripped = try JPEG.stripMetadata(withTail)
        let markers = Self.segments(stripped)
        XCTAssertFalse(markers.contains(0xE1))
        XCTAssertFalse(markers.contains(0xFE))
        XCTAssertTrue(markers.contains(0xE0))
        XCTAssertEqual(Array(stripped.suffix(2)), [0xFF, 0xD9])
        XCTAssertNil(T.find([UInt8](stripped), "SyntheticCam"))
        XCTAssertNil(T.find([UInt8](stripped), "Exif"))
        XCTAssertEqual(try JPEG.decode(stripped).pixels, try JPEG.decode(data).pixels)
        // Every fixture strips to a file that decodes the same.
        for name in Self.jpegs {
            let d = try Self.fixture(name + ".jpg")
            XCTAssertEqual(try JPEG.decode(JPEG.stripMetadata(d)).pixels, try JPEG.decode(d).pixels, name)
        }
    }

    /// Marker codes of the segments before the first scan.
    static func segments(_ data: Data) -> [UInt8] {
        let d = [UInt8](data)
        var out: [UInt8] = []
        var p = 2
        while p + 4 <= d.count, d[p] == 0xFF {
            let m = d[p + 1]
            out.append(m)
            if m == 0xDA { break }
            p += 2 + (Int(d[p + 2]) << 8 | Int(d[p + 3]))
        }
        return out
    }

    func testJPEGTruncatedDecodesWhatItHas() throws {
        let data = try Self.fixture("baseline-420.jpg")
        let full = try JPEG.decode(data)
        let cut = try JPEG.decode(data.prefix(data.count * 3 / 4))
        XCTAssertEqual(cut.width, full.width)
        // The top rows are intact.
        XCTAssertEqual(Array(cut.pixels.prefix(61 * 4 * 8)), Array(full.pixels.prefix(61 * 4 * 8)))
        // A header alone is refused, never decoded to a blank image.
        let header = data.prefix(upTo: UntrustedRenderTests.marker([UInt8](data), 0xDA) ?? 0)
        XCTAssertThrowsError(try JPEG.decode(header))
    }

    func testJPEGRefusesUnsupportedAndHostile() throws {
        // Arithmetic coding (SOF9), 12-bit precision, a lying size.
        func frame(_ sof: UInt8, precision: UInt8 = 8, w: Int = 8, h: Int = 8, n: UInt8 = 1) -> Data {
            var d: [UInt8] = [0xFF, 0xD8, 0xFF, sof, 0, 8 + 3 * n, precision, UInt8(h >> 8), UInt8(h & 255),
                              UInt8(w >> 8), UInt8(w & 255), n]
            for i in 0..<n { d += [i + 1, 0x11, 0] }
            return Data(d + [0xFF, 0xD9])
        }
        XCTAssertThrowsError(try JPEG.info(frame(0xC9))) { XCTAssertEqual($0 as? ImageError, .unsupported("lossless, hierarchical or arithmetic-coded JPEG")) }
        XCTAssertThrowsError(try JPEG.info(frame(0xC0, precision: 12))) { XCTAssertEqual($0 as? ImageError, .unsupported("12-bit JPEG")) }
        XCTAssertThrowsError(try JPEG.decode(frame(0xC0, w: 30000, h: 30000))) {
            XCTAssertEqual($0 as? ImageError, .tooLarge(width: 30000, height: 30000))
        }
        XCTAssertThrowsError(try JPEG.decode(Data([0x89, 0x50]))) { XCTAssertEqual($0 as? ImageError, .notAnImage) }
        // Component ids R, G, B without JFIF or Adobe markers: stored as RGB.
        var rgb: [UInt8] = [0xFF, 0xD8, 0xFF, 0xC0, 0, 17, 8, 0, 8, 0, 8, 3]
        for id: UInt8 in [0x52, 0x47, 0x42] { rgb += [id, 0x11, 0] }
        XCTAssertTrue(try JPEG.info(Data(rgb + [0xFF, 0xD9])).isRGB)
    }

    static let pngs = ["grey1", "grey2", "grey4", "grey8", "grey16", "grey1-interlaced", "grey2-interlaced",
                       "grey4-interlaced", "grey8-interlaced", "grey16-interlaced", "grey4-trns",
                       "rgb8", "rgb16", "rgb8-interlaced", "rgb16-interlaced", "rgb16-trns",
                       "greyalpha8", "greyalpha16", "greyalpha8-interlaced", "greyalpha16-interlaced",
                       "rgba8", "rgba16", "rgba8-interlaced", "rgba16-interlaced",
                       "palette1", "palette2", "palette4", "palette8", "palette1-interlaced", "palette2-interlaced",
                       "palette4-interlaced", "palette8-interlaced", "pillow-rgb8-text", "pillow-rgba8", "tiny"]

    func testPNGMatchesReference() throws {
        for name in Self.pngs {
            let image = try PNG.decode(Self.fixture(name + ".png"))
            XCTAssertEqual(image.pixels, [UInt8](try Self.fixture(name + ".rgba")), name)
        }
    }

    func testPNGStripMetadata() throws {
        let data = try Self.fixture("pillow-rgb8-text.png")
        XCTAssertNotNil(T.find([UInt8](data), "tEXt"))
        XCTAssertNotNil(T.find([UInt8](data), "eXIf"))
        var tail = data
        tail.append(contentsOf: Array("trailing GPS".utf8))
        let stripped = try PNG.stripMetadata(tail)
        for name in ["tEXt", "eXIf", "synthetic", "GPS"] { XCTAssertNil(T.find([UInt8](stripped), name), name) }
        XCTAssertEqual(try PNG.decode(stripped), try PNG.decode(data))
        // tRNS is kept: the transparency is part of the image.
        let trns = try Self.fixture("palette4.png")
        XCTAssertNotNil(T.find([UInt8](try PNG.stripMetadata(trns)), "tRNS"))
    }

    func testPNGRefusesHostile() throws {
        let data = try Self.fixture("rgb8.png")
        var badCRC = [UInt8](data)
        badCRC[30] ^= 0xFF   // inside IHDR's CRC
        XCTAssertThrowsError(try PNG.decode(Data(badCRC)))
        XCTAssertThrowsError(try PNG.decode(data.prefix(data.count - 20))) { XCTAssertEqual($0 as? ImageError, .truncated) }
        // A header claiming 30000 × 30000 over a few bytes of data.
        var huge = [UInt8](data)
        huge.replaceSubrange(16..<24, with: [0, 0, 0x75, 0x30, 0, 0, 0x75, 0x30])
        let crc = huge.withUnsafeBufferPointer { b in crc32Fixture(b, 12, 17) }
        huge.replaceSubrange(29..<33, with: [UInt8(crc >> 24), UInt8(crc >> 16 & 255), UInt8(crc >> 8 & 255), UInt8(crc & 255)])
        XCTAssertThrowsError(try PNG.decode(Data(huge))) { XCTAssertEqual($0 as? ImageError, .tooLarge(width: 30000, height: 30000)) }
        XCTAssertThrowsError(try PNG.decode(Data(Array("not a png".utf8)))) { XCTAssertEqual($0 as? ImageError, .notAnImage) }
    }
}

/// CRC-32 (PNG's, ISO 3309) of `count` bytes of `b` from `start`.
func crc32Fixture(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ count: Int) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for i in start..<(start + count) {
        c ^= UInt32(b[i])
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }
    return ~c
}
