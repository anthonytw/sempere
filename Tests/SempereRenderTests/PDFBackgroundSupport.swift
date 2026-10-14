import Foundation
import FuzzSupport
import Sempere
import SemperePDF
import XCTest
@testable import SempereRender

/// Blobs held in memory, as a `BlobSource`.
struct MemoryBlobs: BlobSource {
    var contents: [String: Data] = [:]

    mutating func add(_ data: Data, type: String = "application/pdf") -> BlobRef {
        let ref = BlobRef(content: data, type: type)
        contents[ref.sha256] = data
        return ref
    }

    func data(for ref: BlobRef, maxBytes: Int) throws -> Data {
        guard let d = contents[ref.sha256] else { throw BlobError.missing(ref.sha256) }
        guard d.count <= maxBytes else { throw BlobError.contentTooLarge(limit: Int64(maxBytes)) }
        return d
    }

    func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
        guard let d = contents[ref.sha256] else { throw BlobError.missing(ref.sha256) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(UUID().uuidString).pdf")
        try d.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }
}

/// Paints the requested size: left half red, right half blue, top-left
/// quadrant green, so orientation errors show.
struct QuadrantRasterizer: PDFPageRasterizer {
    func rasterize(pdf: URL, pageIndex: Int, pixelWidth w: Int, pixelHeight h: Int) throws -> RGBAImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let c: (UInt8, UInt8, UInt8) = x < w / 2 ? (y < h / 2 ? (0, 255, 0) : (255, 0, 0)) : (0, 0, 255)
                px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2
            }
        }
        return try RGBAImage(width: w, height: h, pixels: px)
    }
}

struct FailingRasterizer: PDFPageRasterizer {
    struct Boom: Error {}
    func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int) throws -> RGBAImage { throw Boom() }
}

/// Poppler for tests: `pdftoppm` as a subprocess (the CLI has the hardened one).
enum Poppler {
    static var pdftoppm: String? {
        if let p = ProcessInfo.processInfo.environment["SEMPERE_PDFTOPPM"] { return p }
        return ExternalTool.find("pdftoppm")?.path
    }

    /// Skips the test without Poppler, unless `SEMPERE_REQUIRE_POPPLER` is set (CI).
    static func require() throws -> String {
        if let p = pdftoppm { return p }
        if ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_POPPLER"] != nil {
            XCTFail("pdftoppm not found and SEMPERE_REQUIRE_POPPLER is set")
        }
        throw XCTSkip("pdftoppm (poppler-utils) not installed")
    }

    struct Image {
        var width: Int
        var height: Int
        var rgb: [UInt8]
        subscript(x: Int, y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 3
            return (Int(rgb[i]), Int(rgb[i + 1]), Int(rgb[i + 2]))
        }
    }

    /// Page `page` (1-based) at `dpi`, or scaled to exactly `size`; the crop box when `cropBox`.
    static func render(_ pdf: URL, page: Int = 1, dpi: Double = 72, size: (Int, Int)? = nil,
                       cropBox: Bool = true) throws -> Image {
        let tool = try require()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ppm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var args = ["-f", "\(page)", "-l", "\(page)", "-singlefile", "-aa", "yes", "-aaVector", "yes"]
        if cropBox { args.append("-cropbox") }
        if let (w, h) = size { args += ["-scale-to-x", "\(w)", "-scale-to-y", "\(h)"] } else { args += ["-r", "\(dpi)"] }
        args += [pdf.path, dir.appendingPathComponent("out").path]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "pdftoppm", code: Int(p.terminationStatus)) }
        return try parsePPM(Data(contentsOf: dir.appendingPathComponent("out.ppm")))
    }

    static func parsePPM(_ d: Data) throws -> Image {
        let b = [UInt8](d)
        var i = 0
        func token() -> String {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
            var s = ""
            while i < b.count, !(b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09) {
                s.append(Character(Unicode.Scalar(b[i]))); i += 1
            }
            return s
        }
        guard token() == "P6", let w = Int(token()), let h = Int(token()), token() == "255" else {
            throw NSError(domain: "ppm", code: 1)
        }
        i += 1
        guard b.count - i >= w * h * 3 else { throw NSError(domain: "ppm", code: 2) }
        return Image(width: w, height: h, rgb: Array(b[i..<(i + w * h * 3)]))
    }

    static func image(fromPNGRaster r: RGBAImage) -> Image {
        var rgb: [UInt8] = []
        rgb.reserveCapacity(r.width * r.height * 3)
        for i in 0..<(r.width * r.height) {
            // Over white, as Poppler renders.
            let a = Double(r.pixels[4 * i + 3]) / 255
            for c in 0..<3 { rgb.append(UInt8((Double(r.pixels[4 * i + c]) * a + 255 * (1 - a)).rounded())) }
        }
        return Image(width: r.width, height: r.height, rgb: rgb)
    }

    /// Fraction of pixels whose largest channel difference exceeds `threshold`, and the mean difference.
    static func compare(_ a: Image, _ b: Image, threshold: Int = 48) -> (bad: Double, mean: Double) {
        guard a.width == b.width, a.height == b.height else { return (1, 255) }
        var bad = 0
        var sum = 0
        for i in 0..<(a.width * a.height) {
            var m = 0
            for c in 0..<3 { m = max(m, abs(Int(a.rgb[3 * i + c]) - Int(b.rgb[3 * i + c]))) }
            sum += m
            if m > threshold { bad += 1 }
        }
        let n = Double(a.width * a.height)
        return (Double(bad) / n, Double(sum) / n)
    }
}

/// Poppler as a `PDFPageRasterizer` (tests only).
struct PopplerTestRasterizer: PDFPageRasterizer {
    func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int) throws -> RGBAImage {
        // Poppler scales before applying /Rotate.
        let rotation = (try? PDFFile(data: Data(contentsOf: pdf)).page(pageIndex).rotation) ?? 0
        let size = rotation % 180 == 0 ? (pixelWidth, pixelHeight) : (pixelHeight, pixelWidth)
        let img = try Poppler.render(pdf, page: pageIndex + 1, size: size)
        var px: [UInt8] = []
        px.reserveCapacity(img.width * img.height * 4)
        for i in 0..<(img.width * img.height) { px += [img.rgb[3 * i], img.rgb[3 * i + 1], img.rgb[3 * i + 2], 255] }
        return try RGBAImage(width: img.width, height: img.height, pixels: px)
    }
}

enum PDFFixture {
    /// SemperePDF's fixtures, from the source tree.
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SemperePDFTests/Fixtures").appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    /// A note with one finite blank page of `size` holding `items`.
    static func note(size: (Double, Double), items: [Item], strokes: [Stroke] = [], paper: Paper = .blank) -> NoteState {
        NoteState(meta: T.meta(paper: paper, size: PageSize(width: size.0, height: size.1)),
                  pages: [Page(order: "a0", strokes: strokes, items: items)])
    }

    static func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }
}

enum PNGTestDecoder {
    static func decode(_ d: Data) throws -> DecodedPNG { try DecodedPNG(d) }
}

extension DecodedPNG {
    /// RGB of a pixel.
    func rgb(_ x: Int, _ y: Int) -> [UInt8] { Array(px(x, y).prefix(3)) }
}
