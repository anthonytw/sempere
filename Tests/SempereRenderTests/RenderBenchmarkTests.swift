import Foundation
import XCTest
import Sempere
import SempereFonts
@testable import SempereRender
#if canImport(Glibc)
import Glibc
#endif

/// The process's peak resident size in MB (run one benchmark per process to
/// attribute it).
func peakRSSMegabytes() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    #if os(Linux)
    return Double(usage.ru_maxrss) / 1024   // kilobytes
    #else
    return Double(usage.ru_maxrss) / 1_048_576   // bytes
    #endif
}

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

    /// A long text box: `SEMPERE_BENCH_LINES` paragraphs of 40 characters,
    /// with and without stored breaks (two per paragraph).
    func testTextShapeTimings() throws {
        let lines = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_LINES"] ?? "") ?? 500
        let shaper = DefaultTextShaper(library: FontLibrary(bundled: SempereFonts.directory, packs: []))
        let paragraph = "The quick brown fox jumps over the dog."
        let text = Array(repeating: paragraph, count: lines).joined(separator: "\n")
        var breaks: [Int] = []
        for k in 0..<lines { breaks += [k * 40 + 10, k * 40 + 20] }
        let black = Color(r: 0, g: 0, b: 0, a: 255)
        for stored in [nil, breaks] {
            let content = TextContent(size: 10, color: black, runs: [TextRun(text)], breaks: stored)
            let t = Date()
            let shaped = try shaper.shape(content, frame: Rect(x: 0, y: 0, w: 150, h: 10))
            var digest = ""
            for l in shaped.lines {
                digest += "\(l.text)|\(l.baseline)|\(l.x)|\(l.width)|"
                for r in l.runs { for g in r.glyphs { digest += "\(g.glyph),\(g.x)," } }
            }
            print("bench: shape \(lines) lines, stored breaks \(stored != nil): \(secs(t)), \(shaped.lines.count) lines, "
                  + "crc \(Zlib.crc32(0, Data(digest.utf8))), peak \(Int(peakRSSMegabytes())) MB")
        }
    }

    /// A Japanese text box of `SEMPERE_BENCH_CJK` characters with the
    /// system's font packs (scanned before timing).
    func testCJKShapeTimings() throws {
        let count = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_CJK"] ?? "") ?? 1_000
        let library = FontLibrary(bundled: SempereFonts.directory, packs: FontLibrary.defaultPackDirectories())
        let shaper = DefaultTextShaper(library: library)
        let black = Color(r: 0, g: 0, b: 0, a: 255)
        _ = try shaper.shape(TextContent(size: 10, color: black, lang: "ja", runs: [TextRun("日")]),
                             frame: Rect(x: 0, y: 0, w: 300, h: 10))
        var scalars = String.UnicodeScalarView()
        for i in 0..<count {
            // Kanji (3,000 distinct), kana and punctuation.
            let v: UInt32 = i % 5 == 4 ? 0x3042 + UInt32(i % 80) : 0x4E00 + UInt32((i * 7) % 3_000)
            scalars.append(Unicode.Scalar(v)!)
            if i % 40 == 39 { scalars.append("\n") }
        }
        let content = TextContent(size: 10, color: black, lang: "ja", runs: [TextRun(String(scalars))])
        let t = Date()
        let shaped = try shaper.shape(content, frame: Rect(x: 0, y: 0, w: 300, h: 10))
        var digest = ""
        for l in shaped.lines {
            for r in l.runs { digest += r.face.key + "|"; for g in r.glyphs { digest += "\(g.glyph),\(g.x)," } }
        }
        print("bench: shape \(count) CJK characters: \(secs(t)), \(shaped.lines.count) lines, "
              + "crc \(Zlib.crc32(0, Data(digest.utf8))), peak \(Int(peakRSSMegabytes())) MB")
    }
}
