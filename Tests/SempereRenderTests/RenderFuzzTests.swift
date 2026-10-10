import Foundation
import FuzzSupport
import Sempere
import XCTest

@testable import SempereRender

/// Seeded mutation fuzzing of the renderers with note state decoded from
/// untrusted JSON: PNG (with a pixel cap), SVG and PDF must either render or
/// throw `RenderError`, within bounded time and memory, never trap.
final class RenderFuzzTests: XCTestCase {
    static let png = PNGOptions(scale: 0.5, maxPixels: 1_000_000)

    static func typed(_ body: () throws -> Void) -> String? {
        do { try body() } catch is DecodingError {
        } catch is RenderError {
        } catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    static func render(_ note: NoteState) throws {
        _ = try PNGWriter.render(note: note, png: png)
        _ = try SVGWriter.render(note: note)
        _ = try PDFWriter.render(note: note)
    }

    static func seeds() throws -> [Data] {
        var states = [try T.loadSampleNote()]
        let tools = InkTool.allCases
        var strokes: [Stroke] = []
        for (i, tool) in tools.enumerated() {
            var pts: [StrokePoint] = []
            for j in 0..<6 {
                let x = Double(10 + 20 * i + 3 * j), y = Double(10 + 7 * j)
                pts.append(T.pt(x, y, w: 1 + Double(j % 3), o: 0.8))
            }
            let xf: Transform? = i % 3 == 0 ? Transform(a: 1.5, b: 0.2, c: 0, d: 1, tx: 4, ty: 9) : nil
            strokes.append(T.stroke(pts, tool: tool, width: 3, transform: xf))
        }
        for paper in [Paper(kind: .ruled), Paper(kind: .grid, spacing: 10), Paper(kind: .dot, spacing: 5), .blank] {
            states.append(T.note(pages: [strokes, [strokes[0]]], meta: T.meta(paper: paper)))
        }
        states.append(T.note(pages: [strokes], meta: T.meta(size: PageSize(width: 300, height: 400, infinite: true,
                                                                             breakHeight: 150))))
        // A finite page a fraction of a point tall, ink far below it (pages below a page, §5.4.3).
        states.append(T.note(pages: [strokes + [T.stroke([T.pt(20, 150_000, w: 2), T.pt(180, 150_010, w: 2)], width: 2)]],
                             meta: T.meta(size: PageSize(width: 300, height: 0.001))))
        return try states.map { try InkJSON.encoder().encode($0) }
    }

    /// Hostile but well-formed geometry: long segments, many points, extreme
    /// transforms and widths, dense paper on tall infinite pages.
    static func generate(_ rng: inout FuzzRNG) -> Data {
        let big = [0.0, 1, 72, 1000, 199_999, 200_001, 1e9, 1e300, -1e300, 5e-324]
        var strokes: [Stroke] = []
        for _ in 0..<(1 + rng.below(6)) {
            let n = rng.pick([1, 2, 3, 50, 2000])
            let pts = (0..<n).map { _ in
                StrokePoint(x: rng.pick(big) * (rng.oneIn(2) ? 1 : -1), y: rng.pick(big), t: 0, w: rng.pick(big),
                            h: rng.pick(big), o: rng.pick([0, 0.5, 1, 1e300, -1e300]), f: 0)
            }
            let s = rng.pick(big)
            let xf = rng.oneIn(3) ? Transform(a: s, b: rng.pick(big), c: rng.pick(big), d: s, tx: rng.pick(big), ty: rng.pick(big))
                : nil
            strokes.append(T.stroke(pts, tool: rng.pick(InkTool.allCases), width: rng.pick(big), transform: xf))
        }
        let size = PageSize(width: rng.pick([1, 300, 199_999, 1e9]), height: rng.pick([0, 400, 199_999, 1e9, 1, 0.001, 1e-300]),
                            infinite: rng.oneIn(2), breakHeight: rng.oneIn(2) ? rng.pick([0, 72, 1, 1e300]) : nil)
        let paper = Paper(kind: rng.pick(PaperKind.allCases), spacing: rng.pick([0, 4, 4.0001, 1e-300, 24, 1e300]))
        let note = T.note(pages: [strokes], meta: T.meta(paper: paper, size: size))
        return (try? InkJSON.encoder().encode(note)) ?? Data()
    }

    func testFuzzRenderers() throws {
        let report = Fuzz.run("render", seeds: try Self.seeds(), quick: 400, text: true, maxSize: 512 << 10,
                              generate: Self.generate) { input in
            Self.typed {
                let note = try InkJSON.decoder().decode(NoteState.self, from: input)
                try Self.render(note)
            }
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}

/// Seeded mutation fuzzing of the image decoders and of image items in the
/// three writers (docs/attachments.md §14, C1): every input decodes, strips
/// or exports, or fails with `ImageError`; stripping metadata never changes
/// the decoded pixels; nothing traps, hangs or allocates past the budget.
final class ImageFuzzTests: XCTestCase {
    /// A small pixel cap keeps each case's memory far under the harness budget.
    static let maxPixels = 4_000_000

    static func typed(_ body: () throws -> String?) -> String? {
        do { return try body() } catch is ImageError {
        } catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    static func fixtures(_ ext: String) throws -> [Data] {
        let dir = try T.fixtureURL("images")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(ext) }.sorted()
            .map { try Data(contentsOf: dir.appendingPathComponent($0)) }
    }

    /// Headers that claim more than their bytes hold, and short hostile streams.
    static func generateJPEG(_ rng: inout FuzzRNG) -> Data {
        let w = rng.pick([1, 8, 9, 65535, 30000]), h = rng.pick([1, 8, 16, 65535, 30000])
        let n = rng.pick([1, 3, 4])
        var d: [UInt8] = [0xFF, 0xD8]
        if rng.oneIn(2) { d += [0xFF, 0xDD, 0, 4, 0, UInt8(rng.below(4))] }
        d += [0xFF, rng.pick([0xC0, 0xC1, 0xC2]), 0, UInt8(8 + 3 * n), 8, UInt8(h >> 8), UInt8(h & 255),
              UInt8(w >> 8), UInt8(w & 255), UInt8(n)]
        for i in 0..<n { d += [UInt8(i + 1), UInt8(rng.pick([0x11, 0x22, 0x41, 0x14, 0x44])), 0] }
        d += [0xFF, 0xDB, 0, 67, 0] + [UInt8](repeating: UInt8(1 + rng.below(255)), count: 64)
        d += [0xFF, 0xC4, 0, 20, UInt8(rng.pick([0x00, 0x10]))] + [1] + [UInt8](repeating: 0, count: 15) + [0]
        d += [0xFF, 0xDA, 0, UInt8(6 + 2 * n), UInt8(n)]
        for i in 0..<n { d += [UInt8(i + 1), 0] }
        d += [UInt8(rng.below(64)), UInt8(rng.below(64)), UInt8(rng.below(256))]
        d += (0..<rng.below(64)).map { _ in UInt8(rng.below(256)) }
        if rng.oneIn(2) { d += [0xFF, 0xD9] }
        return Data(d)
    }

    func testFuzzJPEG() throws {
        let report = Fuzz.run("jpeg", seeds: try Self.fixtures(".jpg"), quick: 300, maxSize: 64 << 10,
                              generate: Self.generateJPEG) { input in
            Self.typed {
                _ = try? JPEG.info(input)
                let full = try? JPEG.decode(input, maxPixels: Self.maxPixels)
                for s in [2, 8] { _ = try? JPEG.decode(input, scale: s, maxPixels: Self.maxPixels) }
                let stripped = try JPEG.stripMetadata(input)
                if let full {
                    let again = try JPEG.decode(stripped, maxPixels: Self.maxPixels)
                    if again != full { return "stripping metadata changed the decoded image" }
                }
                return nil
            }
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    func testFuzzPNG() throws {
        let report = Fuzz.run("png", seeds: try Self.fixtures(".png"), quick: 400, maxSize: 64 << 10) { input in
            Self.typed {
                let full = try? PNG.decode(input, maxPixels: Self.maxPixels)
                let stripped = try PNG.stripMetadata(input)
                if let full, try PNG.decode(stripped, maxPixels: Self.maxPixels) != full {
                    return "stripping metadata changed the decoded image"
                }
                return nil
            }
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    /// What a writer learns about a file before storing it: JPEG/PNG size, the EXIF
    /// orientation parser, metadata removal, and PDF page sizes.
    func testFuzzIngest() throws {
        let pdfs = try ["classic.pdf", "rotated.pdf", "broken-xref.pdf"].map {
            try Data(contentsOf: AttachmentIngestTests.pdfFixtures.appendingPathComponent($0))
        }
        let exif = try Self.fixtures(".jpg").prefix(2).map { AttachmentIngestTests.insertExif(into: $0, orientation: 6, bigEndian: false) }
        let seeds = try Array(Self.fixtures(".jpg").prefix(4)) + Array(Self.fixtures(".png").prefix(4)) + exif + pdfs
        let report = Fuzz.run("ingest", seeds: seeds, quick: 300, maxSize: 64 << 10) { input in
            do {
                let image = try ImageIngest.prepare(input, maxPixels: Self.maxPixels)
                // Whatever is stored is itself attachable and keeps its type and (upright) size: the
                // orientation moved into the field, so the stripped bytes carry none.
                let again = try ImageIngest.prepare(image.data, maxPixels: Self.maxPixels)
                if again.mediaType != image.mediaType || again.orientation != nil { return "stripping changed the image" }
                if image.orientation == nil, again.pixelSize != image.pixelSize { return "stripping changed the size" }
                if image.pixelSize.w < 1 || image.pixelSize.h < 1 { return "empty size" }
            } catch is ImageIngestError {
            } catch { return "untyped error \(type(of: error)): \(error)" }
            do {
                let pdf = try PDFIngest.inspect(input)
                if pdf.pages.isEmpty || pdf.pages.contains(where: { !$0.size.isPositive }) { return "unusable page accepted" }
            } catch is PDFIngestError {
            } catch { return "untyped error \(type(of: error)): \(error)" }
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    /// One mutated image blob placed by mutated items in all three writers.
    func testFuzzImageExport() throws {
        let seeds = try Array(Self.fixtures(".jpg").prefix(4)) + Array(Self.fixtures(".png").prefix(6))
        let report = Fuzz.run("image-export", seeds: seeds, quick: 120, maxSize: 64 << 10) { input in
            var rng = FuzzRNG(seed: UInt64(input.count) &* 0x9E37_79B9)
            let ref = BlobRef(content: input, type: rng.pick(["image/jpeg", "image/png", "image/heic", "image/gif"]))
            // Extreme magnification, slivers and turns. (Frames as tall as the
            // 200 000 pt extent limit are legal but make hundreds of output
            // images; UntrustedRenderTests covers that extent with strokes.)
            let frames = [Rect(x: 10, y: 10, w: 100, h: 80), Rect(x: -50, y: 290, w: 1e-3, h: 400),
                          Rect(x: 0, y: 0, w: 2_000, h: 3)]
            let items = (0..<3).map { _ in
                Item(kind: .image, layer: ItemLayer(rawValue: rng.pick([0, 100, 7])), frame: rng.pick(frames),
                     rotation: rng.pick([nil, 0, 45, 1e9, -0.001]), z: "a", blob: ref,
                     pixelSize: Size(w: 1, h: 1), orientation: rng.pick([nil, 1, 5, 8, 9]),
                     crop: rng.pick([nil, Rect(x: 1, y: 1, w: 2, h: 2), Rect(x: -1e9, y: 0, w: 1e-3, h: 1e12)]))
            }
            let note = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0),
                                                pageSize: PageSize(width: 300, height: 300, infinite: rng.oneIn(2))),
                                 pages: [Page(order: "a", items: items)])
            let options = RenderOptions(blobs: MemoryBlobSource([input]), maxImagePixels: Self.maxPixels)
            do {
                var r = RenderReport()
                _ = try PNGWriter.render(note: note, options: options, png: PNGOptions(scale: 0.5, maxPixels: 1_000_000), report: &r)
                _ = try SVGWriter.export(note: note, options: options, report: &r)
                _ = try PDFWriter.render(note: note, options: options, report: &r)
            } catch is RenderError {
            } catch { return "untyped error \(type(of: error)): \(error)" }
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
    /// Image preparation for storing (`ImageImport`): sniffing, EXIF
    /// orientation, HEIF sizes and stripping. Only `Failure` may be thrown.
    func testFuzzImageImport() throws {
        let seeds = try Array(Self.fixtures(".jpg").prefix(6)) + Array(Self.fixtures(".png").prefix(4))
            + Array(Self.fixtures(".gif")) + Array(Self.fixtures(".tif"))
        let report = Fuzz.run("image-import", seeds: seeds, quick: 300, maxSize: 64 << 10,
                              generate: Self.generateJPEG) { input in
            _ = JPEG.exifOrientation(input)
            _ = HEIF.imageSize(input)
            do {
                let p = try ImageImport.prepare(input)
                if p.width <= 0 || p.height <= 0 { return "non-positive size \(p.width) × \(p.height)" }
                if let o = p.orientation, !(2...8).contains(o) { return "orientation \(o)" }
            } catch is ImageImport.Failure {
            } catch { return "untyped error \(type(of: error)): \(error)" }
            var heif = Data([0, 0, 0, 16]) + Data("ftypheic".utf8) + Data(count: 4)
            heif += input
            _ = HEIF.imageSize(heif)
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}

/// Seeded mutation fuzzing of the font reader (fonts come from user font
/// directories) and of text layout (text from revisions): parse, outlines,
/// layout lookups and subsetting either work or throw `FontError`; layout
/// never traps on any text, direction or stored breaks.
final class TextFuzzTests: XCTestCase {
    static func fontSeeds() throws -> [Data] {
        let dir = try T.fixtureURL("fonts")
        var seeds = try ["arabic.ttf", "hebrew.ttf", "cjk.otf"].map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        // A small TrueType subset of a bundled font (whole fonts are too large to mutate quickly).
        if let face = TextLayoutTests.library.bundledFace(.sans, bold: false, italic: false) {
            var s = FontSubset(face.font)
            for c in "Aé fi,Ω".unicodeScalars { _ = s.id(face.font.glyph(for: c.value)) }
            if let file = try? s.trueTypeFile(cmap: [0x41: 1]) { seeds.append(Data(file)) }
        }
        return seeds
    }

    func testFuzzOpenType() throws {
        let report = Fuzz.run("opentype", seeds: try Self.fontSeeds(), quick: 300, maxSize: 64 << 10) { input in
            do {
                let font = try OpenTypeFont(data: [UInt8](input))
                for g in 0..<min(font.numGlyphs, 24) { _ = try? font.outline(g) }
                for c: UInt32 in [0x41, 0x627, 0x5D0, 0x65E5, 0x10FFFF] { _ = font.glyph(for: c, variation: 0xFE00) }
                let layout = OpenTypeLayout(font)
                var applier = GSUBApplier(layout: layout, buffer: (0..<min(font.numGlyphs, 12)).map { .init(glyph: $0, cluster: $0) })
                for (l, _) in layout.lookups(layout.gsub, script: "arab", features: ["ccmp", "init", "medi", "fina", "isol", "rlig"]) {
                    applier.apply(l)
                }
                for (l, _) in layout.lookups(layout.gpos, script: "hebr", features: ["mark", "mkmk"]) {
                    _ = layout.attach(l, mark: 3, base: 1)
                }
                var s = FontSubset(font)
                for g in 0..<min(font.numGlyphs, 8) { _ = s.id(g) }
                _ = font.isCFF ? try? s.cffTable() : try? s.trueTypeFile(cmap: [0x41: 1])
            } catch is FontError {
            } catch { return "untyped error \(type(of: error)): \(error)" }
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    /// Random text from a pool of scripts, controls and marks, any direction
    /// and alignment, random stored breaks, in tiny and huge frames.
    /// Markdown boxes laid out and expanded (format.md §8.5.4) with any
    /// source, frame, stored layout and typeset formulas: no trap, finite
    /// geometry, and a stored layout of the same text always used.
    func testFuzzMarkdownLayout() throws {
        let seeds = ["# H\n\n- [x] **a** `d` $x$\n> q\n```\nc\n```\n$$y$$", "a b c d e f g h i j k l m n o p",
                     "مرحبا $x$ بكم", "$x$$x$$y$$"].map { Data($0.utf8) }
        let render = BlobRef(sha256: String(repeating: "a", count: 64), size: 10, type: "application/pdf")
        let report = Fuzz.run("markdown-layout", seeds: seeds, quick: 300, maxSize: 600) { input in
            let b = [UInt8](input)
            let source = String(decoding: input, as: UTF8.self)
            var content = TextContent(size: [1, 12, 300][Int(b.first ?? 0) % 3], color: .black, runs: [TextRun(source)],
                                      markup: .markdown)
            content.math = ["x", "y", "\\frac{a}{b}"].map { latex in
                TypesetFormula(math: MathContent(latex: latex, display: b.count % 2 == 0, size: content.size, color: .black,
                                                 render: render, renderSize: Size(w: 5 + Double(b.count % 40), h: 9), engine: "f"),
                               depth: 2)
            }
            let offsets = b.prefix(6).map { Int($0) % max(source.unicodeScalars.count, 1) }.sorted()
            var unique: [Int] = []
            for o in offsets where unique.last != o { unique.append(o) }
            content.layout = RenderedLayout(of: MarkdownText.hash(source), breaks: unique)
            let frame = [Rect(x: 0, y: 0, w: 0.001, h: 1), Rect(x: 10, y: 10, w: 200, h: 40), Rect(x: 0, y: 0, w: 1e5, h: 1)][Int(b.last ?? 0) % 3]
            let laid = MarkdownLayout(content, frame: frame, measure: MarkdownLayoutTests.measure)
            guard laid.height.isFinite, laid.texts.allSatisfy({ [$0.frame.x, $0.frame.y, $0.frame.w].allSatisfy(\.isFinite) }) else {
                return "non-finite geometry"
            }
            // A writer's layout is used as it was written.
            let relaid = MarkdownLayout.relayout(content, frame: Rect(x: 0, y: 0, w: 150, h: 1), measure: MarkdownLayoutTests.measure)
            if !MarkdownLayout(relaid.content, frame: relaid.frame, measure: MarkdownLayoutTests.measure).usedStoredBreaks {
                return "a writer's own layout was not usable"
            }
            if let it = try? PreparedItem(Item.text(content, frame: Rect(x: 1, y: 1, w: 100, h: 20), z: "a"), pageNumber: 1) {
                _ = MarkdownItems.expand(it, shaper: TextLayoutTests.shaper)
            }
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    func testFuzzTextLayout() throws {
        let pool: [UInt32] = [0x41, 0x61, 0x20, 0x09, 0x2D, 0x0A, 0x301, 0x5D0, 0x5B8, 0x627, 0x644, 0x64E, 0x651, 0x660,
                              0x4E00, 0x3042, 0xAC00, 0x928, 0x94D, 0x200D, 0x200C, 0x202B, 0x202C, 0x2067, 0x2069, 0x2066,
                              0xFE0F, 0x1F600, 0x1F1E6, 0x28, 0x29, 0x5B, 0x31, 0x2E, 0xA0, 0x2028, 0xFFFD, 0x10FFFF]
        let seeds = (0..<8).map { k in Data((0..<(8 * (k + 1))).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ k) }) }
        let report = Fuzz.run("text-layout", seeds: seeds, quick: 300, maxSize: 512) { input in
            let b = [UInt8](input)
            guard b.count >= 2 else { return nil }
            var scalars = String.UnicodeScalarView()
            for byte in b.dropFirst(4) { if let s = Unicode.Scalar(pool[Int(byte) % pool.count]) { scalars.append(s) } }
            let text = String(scalars)
            let dirs: [TextContent.Direction?] = [nil, .ltr, .rtl, .auto]
            let aligns: [TextContent.Alignment?] = [nil, .start, .end, .center, .left, .right]
            let breaks = b.prefix(4).map { Int($0) % max(text.unicodeScalars.count, 1) }
            let content = TextContent(size: [1, 12, 1000][Int(b[0]) % 3], color: Color(r: 0, g: 0, b: 0, a: 255),
                                      align: aligns[Int(b[0]) % aligns.count], dir: dirs[Int(b.last!) % dirs.count],
                                      lang: b.count % 2 == 0 ? "zh-Hant" : nil,
                                      runs: [TextRun(text, b: b[0] & 1 != 0, i: b[0] & 2 != 0, u: true)],
                                      breaks: b[0] & 4 != 0 ? breaks : nil)
            let frame = [Rect(x: 0, y: 0, w: 0.001, h: 1), Rect(x: 10, y: 10, w: 300, h: 40), Rect(x: 0, y: 0, w: 1e5, h: 1)][Int(b[1]) % 3]
            do { _ = try TextLayoutTests.shaper.shape(content, frame: frame) } catch {
                return "layout threw \(error)"
            }
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

}

/// Seeded mutation fuzzing of what a math model folder holds (docs/research/
/// handwriting-to-latex.md): `manifest.json` and the tokenizer may come from
/// any folder given to `sempere recognize-math --model`. Each parses or fails
/// with its typed error; a parsed manifest's checks hold; decoding any ids of
/// a parsed vocabulary never traps; the clean-up keeps sources the format accepts.
final class MathModelFuzzTests: XCTestCase {
    static func seeds() throws -> [Data] {
        let folder = try T.fixtureURL("math-tiny")
        let manifest = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        let small = Data(#"{"model": {"vocab": {"<s>": 0, "</s>": 1, "\\frac": 2, "Ġx": 3}}, "added_tokens": [{"id": 0, "content": "<s>", "special": true}]}"#.utf8)
        return [manifest, small, Data(#"["<sos>", "x", "^", "{", "2", "}"]"#.utf8)]
    }

    func testFuzzManifestAndVocabulary() throws {
        let report = Fuzz.run("math-model", seeds: try Self.seeds(), quick: 400, text: true, maxSize: 64 << 10) { input in
            do {
                let m = try MathModelManifest.parse(input)
                if let why = m.problem { return "parsed a manifest that fails its own check: \(why)" }
                for f in m.files where !MathModelManifest.isSafePath(f.path) { return "unsafe path \(f.path)" }
                _ = m.decoder.length(for: m.decoder.maxLength)
            } catch is MathModelManifest.Failure {
            } catch { return "untyped manifest error \(type(of: error))" }
            for joining in [MathVocabulary.Joining.byteLevel, .words] {
                do {
                    let v = try MathVocabulary.parse(input, joining: joining)
                    let ids = [-1, 0, 1, 2, v.tokens.count - 1, v.tokens.count, Int.max, Int.min]
                    let text = v.text(ids)
                    _ = LaTeXCleanup.clean(text)
                } catch is MathVocabulary.Failure {
                } catch { return "untyped vocabulary error \(type(of: error))" }
            }
            if let s = String(data: input, encoding: .utf8) {
                let cleaned = LaTeXCleanup.clean(s)
                if MathSource.formatViolation(s) == nil, MathSource.formatViolation(cleaned) != nil {
                    return "clean-up made a valid source invalid"
                }
            }
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}
