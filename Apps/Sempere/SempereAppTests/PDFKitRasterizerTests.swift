import Foundation
import SempereRender
import Testing
@testable import SempereApp

/// The app's PDF rasterizer draws the effective page (CropBox ∩ MediaBox,
/// turned by /Rotate) at exactly the requested size, the way SemperePDF and
/// the CLI's Poppler rasterizer read it (format.md §8.5.1).
struct PDFKitRasterizerTests {
    /// A one-page 200 × 100 PDF: a red square at the top-left corner, a blue
    /// one at the bottom-right.
    static func pdf(rotate: Int = 0, crop: String = "[0 0 200 100]") throws -> URL {
        let content = "1 0 0 rg 0 80 20 20 re f 0 0 1 rg 180 0 20 20 re f"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /CropBox \(crop) /Rotate \(rotate) /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(repeating: "0", count: 10 - String(o).count) + "\(o) 00000 n \n" }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("raster-\(UUID().uuidString).pdf")
        try Data(out.utf8).write(to: url)
        return url
    }

    func colour(_ img: RGBAImage, _ x: Int, _ y: Int) -> String {
        let i = (y * img.width + x) * 4
        let (r, g, b) = (img.pixels[i], img.pixels[i + 1], img.pixels[i + 2])
        if r > 200 && g < 60 && b < 60 { return "red" }
        if b > 200 && r < 60 && g < 60 { return "blue" }
        if r > 200 && g > 200 && b > 200 { return "white" }
        return "\(r),\(g),\(b)"
    }

    @Test func unrotatedPage() throws {
        let url = try Self.pdf()
        defer { try? FileManager.default.removeItem(at: url) }
        let img = try PDFKitRasterizer().rasterize(pdf: url, pageIndex: 0, pixelWidth: 400, pixelHeight: 200)
        #expect(img.width == 400 && img.height == 200)
        #expect(colour(img, 10, 10) == "red")
        #expect(colour(img, 390, 190) == "blue")
        #expect(colour(img, 200, 100) == "white")
    }

    @Test func rotatedPagesTurnClockwise() throws {
        // /Rotate 90: the effective page is 100 × 200, the top-left corner goes to the top-right.
        let url90 = try Self.pdf(rotate: 90)
        defer { try? FileManager.default.removeItem(at: url90) }
        let a = try PDFKitRasterizer().rasterize(pdf: url90, pageIndex: 0, pixelWidth: 100, pixelHeight: 200)
        #expect(colour(a, 95, 5) == "red")
        #expect(colour(a, 5, 195) == "blue")
        let url270 = try Self.pdf(rotate: -90)
        defer { try? FileManager.default.removeItem(at: url270) }
        let b = try PDFKitRasterizer().rasterize(pdf: url270, pageIndex: 0, pixelWidth: 100, pixelHeight: 200)
        #expect(colour(b, 5, 195) == "red")
        #expect(colour(b, 95, 5) == "blue")
    }

    @Test func cropBoxIsTheVisiblePage() throws {
        // Quartz returns this CropBox as stored; the rasterizer clips it to the MediaBox: x 100…200.
        let url = try Self.pdf(crop: "[100 0 300 100]")
        defer { try? FileManager.default.removeItem(at: url) }
        let img = try PDFKitRasterizer().rasterize(pdf: url, pageIndex: 0, pixelWidth: 100, pixelHeight: 100)
        #expect(colour(img, 95, 95) == "blue")
        #expect(colour(img, 5, 5) == "white")
    }

    @Test func badRequestsThrow() throws {
        let url = try Self.pdf()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: PDFKitRasterizer.Failure.noPage(1)) {
            try PDFKitRasterizer().rasterize(pdf: url, pageIndex: 1, pixelWidth: 10, pixelHeight: 10)
        }
        #expect(throws: PDFKitRasterizer.Failure.tooLarge) {
            try PDFKitRasterizer().rasterize(pdf: url, pageIndex: 0, pixelWidth: 100_000, pixelHeight: 100_000)
        }
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(throws: PDFKitRasterizer.Failure.unreadable) {
            try PDFKitRasterizer().rasterize(pdf: junk, pageIndex: 0, pixelWidth: 10, pixelHeight: 10)
        }
    }
}
