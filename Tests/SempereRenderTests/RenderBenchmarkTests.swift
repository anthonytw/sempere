import Foundation
import XCTest
import Sempere
@testable import SempereRender

/// Prints how long exporting a dense ink page takes. Quick mode draws a small
/// page; `SEMPERE_BENCH_STROKES` and `SEMPERE_BENCH_POINTS` scale it up
/// (e.g. 20000 and 100 for a dense handwritten page).
final class RenderBenchmarkTests: XCTestCase {
    static func denseNote(strokes: Int, points: Int) -> NoteState {
        var state: UInt64 = 42
        func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        let size = PageSize(width: 612, height: 792)
        var list: [Stroke] = []
        for _ in 0..<strokes {
            var x = 20 + unit() * 560, y = 20 + unit() * 740
            var heading = unit() * 2 * .pi
            var pts: [StrokePoint] = []
            for _ in 0..<points {
                heading += (unit() - 0.5) * 0.9
                x += cos(heading) * 0.8; y += sin(heading) * 0.8
                pts.append(T.pt(x, y, w: 1.5 + unit(), o: 1))
            }
            list.append(T.stroke(pts))
        }
        return T.note(pages: [list], meta: T.meta(size: size))
    }

    private var size: (strokes: Int, points: Int) {
        let env = ProcessInfo.processInfo.environment
        return (Int(env["SEMPERE_BENCH_STROKES"] ?? "") ?? 300, Int(env["SEMPERE_BENCH_POINTS"] ?? "") ?? 60)
    }

    private func secs(_ t: Date) -> String { String(format: "%.3f s", Date().timeIntervalSince(t)) }

    func testExportTimings() throws {
        let (strokes, points) = size
        let note = Self.denseNote(strokes: strokes, points: points)
        var t = Date()
        let pdf = try PDFWriter.render(note: note)
        print("bench: PDF, \(strokes) strokes x \(points) points: \(secs(t)), \(pdf.count) bytes, crc \(Zlib.crc32(0, pdf))")
        var raw = RenderOptions()
        raw.compress = false
        t = Date()
        let plain = try PDFWriter.render(note: note, options: raw)
        print("bench: PDF uncompressed: \(secs(t)), \(plain.count) bytes, crc \(Zlib.crc32(0, plain))")
        t = Date()
        let svg = try SVGWriter.render(note: note)
        print("bench: SVG, \(strokes) strokes x \(points) points: \(secs(t)), \(svg.reduce(0) { $0 + $1.utf8.count }) bytes, crc \(Zlib.crc32(0, Data(svg.joined().utf8)))")
        t = Date()
        let png = try PNGWriter.render(note: note)
        print("bench: PNG, \(strokes) strokes x \(points) points: \(secs(t)), \(png.reduce(0) { $0 + $1.count }) bytes")
    }

    /// Many small fills on a letter page at 300 dpi (one per stroke, as PNG
    /// export and recognition images do).
    func testRasterFillTimings() {
        let fills = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_FILLS"] ?? "") ?? 5_000
        var raster = Raster(width: 2_550, height: 3_300)
        let t = Date()
        for i in 0..<fills {
            let x = Double(i % 97) * 26 + 3, y = Double(i % 113) * 29 + 3
            raster.fill([[Point(x: x, y: y), Point(x: x + 9, y: y + 2), Point(x: x + 4, y: y + 8)]],
                        paint: Paint(r: 0, g: 0, b: 0, alpha: 0.5))
        }
        print("bench: \(fills) small fills at 2550 px: \(secs(t)), crc \(Zlib.crc32(0, raster.pixels))")
    }
}
