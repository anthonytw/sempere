import Foundation
@testable import Sempere
import XCTest

@testable import SempereRender

/// `ItemRaster`: one item drawn alone (the app's item layer) matches the
/// placement oracle of format.md §8.5.1 that the exports are checked against,
/// for every orientation, crop and rotation; placeholders, background fill,
/// the pixel cap and invalid geometry.
final class ItemRasterTests: XCTestCase {
    typealias IE = ImageExportTests

    static let text = TextContent(size: 12, color: .black, runs: [TextRun("x")])

    /// Pixel at page point `p` of a rendered item.
    private func pixel(_ r: ItemRaster.Rendered, _ p: Point) -> (Int, Int, Int, Int)? {
        let x = Int((p.x - r.bounds.x) * r.scale), y = Int((p.y - r.bounds.y) * r.scale)
        guard x >= 0, y >= 0, x < r.image.width, y < r.image.height else { return nil }
        let i = (y * r.image.width + x) * 4
        let px = r.image.pixels
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
    }

    func testEveryPlacementMatchesTheOracle() throws {
        let png = try IE.pngData(IE.quadrants())
        let ref = BlobRef(content: png, type: "image/png")
        let options = RenderOptions(blobs: MemoryBlobSource([png]))
        var checked = 0
        for c in IE.cases() {
            let item = Item(kind: .image, frame: c.frame, rotation: c.rotation, z: "a", blob: ref,
                            pixelSize: Size(w: 40, h: 30), orientation: c.orientation, crop: c.crop)
            let r = try ItemRaster.render(item, scale: 2, options: options)
            XCTAssertNil(r.placeholder)
            let label = "o\(c.orientation) r\(c.rotation) crop \(c.crop != nil)"
            for gy in stride(from: r.bounds.y + 1, to: r.bounds.y + r.bounds.h - 1, by: 5) {
                for gx in stride(from: r.bounds.x + 1, to: r.bounds.x + r.bounds.w - 1, by: 5) {
                    let probes = [(0.0, 0.0), (2, 0), (-2, 0), (0, 2), (0, -2)].map {
                        IE.oracle(c, Point(x: gx + $0.0, y: gy + $0.1), w: 40, h: 30)
                    }
                    guard let got = pixel(r, Point(x: gx, y: gy)) else { continue }
                    if probes.allSatisfy({ $0 == nil }) {
                        XCTAssertEqual(got.3, 0, "\(label): transparent outside the frame at (\(gx), \(gy))")
                        checked += 1
                    } else if let s = probes[0], probes.allSatisfy({ $0 != nil }) {
                        guard abs(s.a - 20) >= 1.5, abs(s.b - 15) >= 1.5, s.a >= 1.5, s.a <= 38.5, s.b >= 1.5,
                              s.b <= 28.5 else { continue }
                        let e = IE.quadrant(a: s.a, b: s.b, w: 40, h: 30)
                        XCTAssert(abs(got.0 - e.0) <= 2 && abs(got.1 - e.1) <= 2 && abs(got.2 - e.2) <= 2 && got.3 == 255,
                                  "\(label) at (\(gx), \(gy)): got \(got), expected \(e)")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 2000)
    }

    func testBoundsCoverTheRotatedFrame() throws {
        let item = Item.text(Self.text, frame: Rect(x: 10, y: 20, w: 100, h: 50), z: "a")
        var rotated = item
        rotated.rotation = 90
        let r = try ItemRaster.render(rotated, scale: 1)
        XCTAssertEqual(r.bounds.x, 35, accuracy: 1e-9)
        XCTAssertEqual(r.bounds.y, -5, accuracy: 1e-9)
        XCTAssertEqual(r.bounds.w, 50, accuracy: 1e-9)
        XCTAssertEqual(r.bounds.h, 100, accuracy: 1e-9)
        XCTAssertEqual(r.image.width, 50)
        XCTAssertEqual(r.image.height, 100)
    }

    func testMissingBlobIsAPlaceholderWithDiagonals() throws {
        let ref = BlobRef(content: Data("not here".utf8), type: "image/png")
        let item = Item.image(blob: ref, pixelSize: Size(w: 40, h: 30), frame: Rect(x: 0, y: 0, w: 80, h: 60), z: "a")
        let r = try ItemRaster.render(item, scale: 1, options: RenderOptions(blobs: MemoryBlobSource()))
        guard case .blobUnavailable? = r.placeholder else { return XCTFail("\(String(describing: r.placeholder))") }
        // The diagonal through the centre is drawn, the area beside it is not.
        XCTAssertGreaterThan(pixel(r, Point(x: 40, y: 30))?.3 ?? 0, 0)
        XCTAssertEqual(pixel(r, Point(x: 40, y: 10))?.3, 0)
        let none = try ItemRaster.render(item, scale: 1)
        XCTAssertEqual(none.placeholder, .noBlobSource)
    }

    func testBackgroundItemIsFilledWithPaperOnlyWhenAsked() throws {
        let ref = BlobRef(content: Data("pdf".utf8), type: "application/pdf")
        let item = Item.pdfPage(blob: ref, pageIndex: 0, pageSize: Size(w: 100, h: 100),
                                frame: Rect(x: 0, y: 0, w: 100, h: 100), z: "a")
        let filled = try ItemRaster.render(item, scale: 1, paper: Paper.blank)
        let p = try XCTUnwrap(pixel(filled, Point(x: 30, y: 10)))
        XCTAssertEqual(p.3, 255)
        let plain = try ItemRaster.render(item, scale: 1)
        XCTAssertEqual(pixel(plain, Point(x: 30, y: 10))?.3, 0)
    }

    func testPixelCapLowersTheScale() throws {
        let item = Item.text(Self.text, frame: Rect(x: 0, y: 0, w: 600, h: 800), z: "a")
        let r = try ItemRaster.render(item, scale: 8, maxPixels: 120_000)
        XCTAssertLessThan(r.scale, 8)
        XCTAssertLessThanOrEqual(r.image.width * r.image.height, 120_000 + r.image.width + r.image.height + 1)
    }

    func testInvalidGeometryThrows() {
        var item = Item.text(Self.text, frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "a")
        item.rotation = .nan
        XCTAssertThrowsError(try ItemRaster.render(item, scale: 1))
        item.rotation = nil
        XCTAssertThrowsError(try ItemRaster.render(item, scale: 0))
        XCTAssertThrowsError(try ItemRaster.render(item, scale: .infinity))
        item.frame = Rect(x: 1e9, y: 0, w: 10, h: 10)
        XCTAssertThrowsError(try ItemRaster.render(item, scale: 1))
    }
}
