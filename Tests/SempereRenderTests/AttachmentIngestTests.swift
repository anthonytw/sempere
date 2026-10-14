import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// `ImageIngest` and `PDFIngest`: what the CLI (and the app, for formats it
/// does not convert itself) learns about a file before storing it.
final class AttachmentIngestTests: XCTestCase {
    static let pdfFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SemperePDFTests/Fixtures")

    static func image(_ name: String) throws -> Data { try Data(contentsOf: T.fixtureURL("images/" + name)) }

    static func pdf(_ name: String) throws -> Data { try Data(contentsOf: pdfFixtures.appendingPathComponent(name)) }

    // MARK: images

    func testFormatSniffing() throws {
        XCTAssertEqual(ImageIngest.format(of: try Self.image("metadata.jpg")), .jpeg)
        XCTAssertEqual(ImageIngest.format(of: Data(PNG.signature + [0, 0, 0, 0])), .png)
        XCTAssertEqual(ImageIngest.format(of: Data([0, 0, 0, 24] + Array("ftypheic".utf8) + [0, 0])), .heic)
        XCTAssertEqual(ImageIngest.format(of: Data("RIFF....WEBP".utf8)), .other)
        XCTAssertEqual(ImageIngest.format(of: Data()), .other)
    }

    func testJPEGKeepsTheOrientationFieldAndLosesTheMetadata() throws {
        let original = try Self.image("metadata.jpg")   // 61 × 45, Exif orientation 6, XMP, a comment
        XCTAssertNotNil(original.range(of: Data("synthetic comment".utf8)))
        let prepared = try ImageIngest.prepare(original)
        XCTAssertEqual(prepared.mediaType, "image/jpeg")
        XCTAssertEqual(prepared.orientation, 6)
        XCTAssertEqual(prepared.pixelSize, Size(w: 45, h: 61), "pixel size is after orientation")
        XCTAssertNil(prepared.data.range(of: Data("synthetic comment".utf8)))
        XCTAssertNil(prepared.data.range(of: Data("Exif".utf8)))
        XCTAssertNil(prepared.data.range(of: Data("adobe.com/xap".utf8)))
        XCTAssertNotNil(prepared.data.range(of: Data("JFIF".utf8)), "JFIF stays")
        // The stripped file is the same image.
        XCTAssertEqual(try JPEG.decode(prepared.data).pixels, try JPEG.decode(original).pixels)
        // Keeping metadata stores the bytes as they are.
        let kept = try ImageIngest.prepare(original, keepMetadata: true)
        XCTAssertEqual(kept.data, original)
        XCTAssertEqual(kept.orientation, 6)
    }

    func testJPEGWithoutExifIsUpright() throws {
        let prepared = try ImageIngest.prepare(try Self.image("baseline-420.jpg"))
        XCTAssertNil(prepared.orientation)
        XCTAssertEqual(prepared.pixelSize, Size(w: 61, h: 45))
    }

    func testEveryOrientationValueIsReadInBothByteOrders() throws {
        let base = try Self.image("baseline-420.jpg")
        for big in [true, false] {
            for value in 1...8 {
                let withExif = Self.insertExif(into: base, orientation: UInt16(value), bigEndian: big)
                let p = try ImageIngest.prepare(withExif)
                XCTAssertEqual(p.orientation, value == 1 ? nil : value, "orientation \(value) big=\(big)")
                XCTAssertEqual(p.pixelSize, value >= 5 ? Size(w: 45, h: 61) : Size(w: 61, h: 45))
            }
        }
        // An out-of-range value, a wrong type and a damaged header all mean upright.
        for bad in [0, 9, 300] {
            XCTAssertNil(try ImageIngest.prepare(Self.insertExif(into: base, orientation: UInt16(bad), bigEndian: true)).orientation)
        }
        let short = Data(base.prefix(2)) + Data([0xFF, 0xE1, 0x00, 0x0C]) + Data("Exif\0\0".utf8) + Data([0x4D, 0x4D, 0, 42]) + base.dropFirst(2)
        XCTAssertNil(try ImageIngest.prepare(short).orientation)
    }

    /// `base` with an APP1 Exif segment holding one IFD entry, orientation, after SOI.
    static func insertExif(into base: Data, orientation: UInt16, bigEndian: Bool) -> Data {
        func u16(_ v: UInt16) -> [UInt8] { bigEndian ? [UInt8(v >> 8), UInt8(v & 255)] : [UInt8(v & 255), UInt8(v >> 8)] }
        func u32(_ v: UInt32) -> [UInt8] {
            bigEndian ? [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
                : [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24)]
        }
        var tiff: [UInt8] = bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        tiff += u16(42) + u32(8) + u16(1)                       // header, IFD0 at 8, one entry
        tiff += u16(0x0112) + u16(3) + u32(1) + u16(orientation) + [0, 0] + u32(0)
        let body = Array("Exif\0\0".utf8) + tiff
        let segment: [UInt8] = [0xFF, 0xE1, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 255)] + body
        return base.prefix(2) + Data(segment) + base.dropFirst(2)
    }

    func testPNGIsStrippedOfAncillaryChunks() throws {
        let png = try Self.image("rgb8.png")
        let prepared = try ImageIngest.prepare(png)
        XCTAssertEqual(prepared.mediaType, "image/png")
        XCTAssertNil(prepared.orientation)
        let decoded = try PNG.decode(png)
        XCTAssertEqual(prepared.pixelSize, Size(w: Double(decoded.width), h: Double(decoded.height)))
        XCTAssertEqual(try PNG.decode(prepared.data).pixels, decoded.pixels)
    }

    func testRefusals() throws {
        XCTAssertThrowsError(try ImageIngest.prepare(Data("GIF89a......".utf8))) { XCTAssertEqual($0 as? ImageIngestError, .unsupportedFormat) }
        XCTAssertThrowsError(try ImageIngest.prepare(Data())) { XCTAssertEqual($0 as? ImageIngestError, .unsupportedFormat) }
        let heic = Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 16)
        XCTAssertThrowsError(try ImageIngest.prepare(heic)) { XCTAssertEqual($0 as? ImageIngestError, .heic) }
        XCTAssertThrowsError(try ImageIngest.prepare(try Self.image("cmyk.jpg"))) {
            guard case .unreadable(.unsupported)? = $0 as? ImageIngestError else { return XCTFail("\($0)") }
        }
        // Truncated JPEG and PNG: not attachable.
        let jpeg = try Self.image("baseline-420.jpg")
        XCTAssertThrowsError(try ImageIngest.prepare(jpeg.prefix(30))) { XCTAssertTrue($0 is ImageIngestError) }
        let png = try Self.image("rgb8.png")
        XCTAssertThrowsError(try ImageIngest.prepare(png.prefix(png.count - 20))) { XCTAssertTrue($0 is ImageIngestError) }
        // Pixel limit.
        XCTAssertThrowsError(try ImageIngest.prepare(jpeg, maxPixels: 100)) {
            guard case .unreadable(.tooLarge)? = $0 as? ImageIngestError else { return XCTFail("\($0)") }
        }
    }

    // MARK: PDF

    func testPageSizesAreEffective() throws {
        let classic = try PDFIngest.inspect(try Self.pdf("classic.pdf"))
        XCTAssertEqual(classic.pages.first?.size, Size(w: 400, h: 300))
        XCTAssertEqual(classic.pages.map(\.index), Array(0..<classic.pages.count))
        // CropBox 500 × 360 turned by /Rotate 90: 360 × 500.
        let rotated = try PDFIngest.inspect(try Self.pdf("rotated.pdf"))
        // Page 2 has its own 300 × 200 MediaBox: the inherited CropBox is cut to it, then turned.
        XCTAssertEqual(rotated.pages.map(\.size), [Size(w: 360, h: 500), Size(w: 180, h: 250)])
        XCTAssertEqual(try rotated.pages(numbered: [2, 1]).map(\.index), [1, 0])
        XCTAssertThrowsError(try rotated.pages(numbered: [3])) { XCTAssertEqual($0 as? PDFIngestError, .noSuchPage(3, of: 2)) }
        XCTAssertThrowsError(try rotated.pages(numbered: [0]))
    }

    func testPDFRefusals() throws {
        XCTAssertThrowsError(try PDFIngest.inspect(try Self.pdf("encrypted.pdf"))) { XCTAssertEqual($0 as? PDFIngestError, .unreadable(.encrypted)) }
        XCTAssertThrowsError(try PDFIngest.inspect(Data("not a pdf".utf8))) { XCTAssertTrue($0 is PDFIngestError) }
        XCTAssertThrowsError(try PDFIngest.inspect(Data()))
        // A damaged cross-reference table is rebuilt and reported.
        XCTAssertTrue(try PDFIngest.inspect(try Self.pdf("broken-xref.pdf")).repaired)
        XCTAssertFalse(try PDFIngest.inspect(try Self.pdf("classic.pdf")).repaired)
    }
}
