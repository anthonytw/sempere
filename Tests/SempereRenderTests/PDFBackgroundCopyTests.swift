import Foundation
import Sempere
import SemperePDF
import XCTest
@testable import SempereRender

/// Every page of a PDF is rasterized from one private copy, with the
/// rotation already parsed, unless the blob source's files are cached.
final class PDFBackgroundCopyTests: XCTestCase {
    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var withFile = 0
        var rasterized: [(url: URL, rotation: Int?, existed: Bool)] = []
    }

    struct CountingBlobs: BlobSource {
        var inner: MemoryBlobs
        let calls: Calls
        var cached = false
        func data(for ref: BlobRef, maxBytes: Int) throws -> Data { try inner.data(for: ref, maxBytes: maxBytes) }
        func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
            calls.lock.lock(); calls.withFile += 1; calls.lock.unlock()
            return try inner.withFile(for: ref, body)
        }
        var filesAreCached: Bool { cached }
    }

    struct RecordingRasterizer: PDFPageRasterizer {
        let calls: Calls
        func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int) throws -> RGBAImage {
            try rasterize(pdf: pdf, pageIndex: pageIndex, pixelWidth: pixelWidth, pixelHeight: pixelHeight, rotation: nil)
        }
        func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int, rotation: Int?) throws -> RGBAImage {
            calls.lock.lock()
            calls.rasterized.append((pdf, rotation, FileManager.default.fileExists(atPath: pdf.path)))
            calls.lock.unlock()
            return try QuadrantRasterizer().rasterize(pdf: pdf, pageIndex: pageIndex, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
    }

    private func item(_ ref: BlobRef) -> Item {
        Item.pdfPage(blob: ref, pageIndex: 0, pageSize: Size(w: 400, h: 300), crop: nil,
                     frame: Rect(x: 0, y: 0, w: 100, h: 100), z: "a0", layer: .background)
    }

    func testPagesShareOneCopyAndTheParsedRotation() throws {
        var memory = MemoryBlobs()
        let data = try PDFFixture.data("classic.pdf")
        let ref = memory.add(data)
        let calls = Calls()
        var backgrounds: PDFBackgrounds? = PDFBackgrounds(blobs: CountingBlobs(inner: memory, calls: calls),
                                                          rasterizer: RecordingRasterizer(calls: calls))
        for size in [40, 50, 60] {
            guard case .success = backgrounds!.raster(item(ref), pixelWidth: size, pixelHeight: size) else { return XCTFail() }
        }
        XCTAssertEqual(calls.withFile, 1, "the blob is read once, to parse it")
        XCTAssertEqual(Set(calls.rasterized.map(\.url)).count, 1)
        XCTAssertTrue(calls.rasterized.allSatisfy(\.existed))
        let rotation = try PDFFile(data: data).page(0).rotation
        XCTAssertEqual(calls.rasterized.map(\.rotation), [rotation, rotation, rotation])
        let copy = try XCTUnwrap(calls.rasterized.first?.url)
        XCTAssertEqual(try Data(contentsOf: copy), data)
        let attrs = try FileManager.default.attributesOfItem(atPath: copy.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        backgrounds = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path), "removed with the export")
    }

    func testCachedSourcesAreNotCopied() throws {
        var memory = MemoryBlobs()
        let ref = memory.add(try PDFFixture.data("classic.pdf"))
        let calls = Calls()
        let backgrounds = PDFBackgrounds(blobs: CountingBlobs(inner: memory, calls: calls, cached: true),
                                         rasterizer: RecordingRasterizer(calls: calls))
        for size in [40, 50] {
            guard case .success = backgrounds.raster(item(ref), pixelWidth: size, pixelHeight: size) else { return XCTFail() }
        }
        XCTAssertEqual(calls.withFile, 3, "one read to parse, then the cached file per page")
        XCTAssertEqual(calls.rasterized.count, 2)
        XCTAssertNotNil(calls.rasterized.first?.rotation)
    }
}
