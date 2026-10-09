import Foundation
import FuzzSupport
import Sempere
import SempereFonts
import XCTest

@testable import SempereRender

/// Text items in PDF, SVG and PNG exports (docs/attachments.md §10): font
/// subsets only, searchable text, the CJK font pack, the missing-script report.
final class TextItemExportTests: XCTestCase {
    static let options = RenderOptions(shaper: TextLayoutTests.shaper)
    static let black = Color(r: 0, g: 0, b: 0, a: 255)

    static func note(_ items: [Item], paper: Paper = .blank) -> NoteState {
        NoteState(meta: NoteMeta(title: "Text", created: Date(timeIntervalSince1970: 0), paper: paper,
                                 pageSize: PageSize(width: 400, height: 300)),
                  pages: [Page(order: "a", items: items)])
    }

    static func box(_ s: String, _ y: Double, lang: String? = nil, font: TextContent.Font = .sans, size: Double = 14,
                    rotation: Double? = nil) -> Item {
        Item(kind: .text, frame: Rect(x: 20, y: y, w: 360, h: 30), rotation: rotation, z: "a",
             text: TextContent(font: font, size: size, color: black, lang: lang, runs: [TextRun(s)]))
    }

    static let multilingual = note([
        box("Linear maps and kernels", 20),
        box("Ωμέγα Жизнь", 50),
        box("مرحبا بالعالم", 80),
        box("שָׁלוֹם עולם", 110),
        box("日本語のテキスト中文汉字", 140, lang: "ja"),
    ])

    static func tool(_ name: String) -> String? { ExternalTool.find(name)?.path }

    static func run(_ tool: String, _ args: [String], input pdf: Data) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("in.pdf")
        try pdf.write(to: file)
        let r = try ExternalTool.run(URL(fileURLWithPath: tool), args + [file.path] + (tool.hasSuffix("pdftotext") ? ["-"] : []))
        return String(decoding: r.out, as: UTF8.self)
    }

    func testPDFTextIsSearchableAndFontsAreSubsets() throws {
        var report = RenderReport()
        let pdf = try PDFWriter.render(note: Self.multilingual, options: Self.options, report: &report)
        XCTAssertEqual(report, RenderReport())
        XCTAssertTrue(T.contains(pdf, "/Type0"))
        XCTAssertTrue(T.contains(pdf, "/CIDFontType0C"), "the CJK pack is CFF")
        XCTAssertTrue(T.contains(pdf, "/FontFile2"))
        XCTAssertEqual(T.count(pdf, "/ToUnicode"), T.count(pdf, "/Subtype /Type0"))
        guard let pdftotext = Self.tool("pdftotext"), let pdffonts = Self.tool("pdffonts") else {
            throw XCTSkip("poppler-utils not installed")
        }
        let text = try Self.run(pdftotext, [], input: pdf)
        for word in ["Linear", "kernels", "Ωμέγα", "Жизнь", "مرحبا", "بالعالم", "עולם", "日本語のテキスト中文汉字"] {
            XCTAssertTrue(text.contains(word), "\(word) in \(text)")
        }
        // pdffonts: every font embedded, a subset, with a ToUnicode map.
        let fonts = try Self.run(pdffonts, [], input: pdf).split(separator: "\n").dropFirst(2)
        XCTAssertEqual(fonts.count, 4)   // Noto Sans (Latin, Greek, Cyrillic), Naskh Arabic, Sans Hebrew, CJK pack
        for f in fonts {
            let cols = f.split(separator: " ")
            XCTAssertTrue(cols[0].range(of: "^[A-Z]{6}\\+", options: .regularExpression) != nil, String(f))
            XCTAssertEqual(Array(cols.suffix(5).prefix(3)), ["yes", "yes", "yes"], String(f))   // emb sub uni
        }
    }

    /// Each embedded font program holds only the drawn glyphs (plus .notdef).
    func testEmbeddedFontsAreSubsetOnly() throws {
        var fonts = PDFFontSet()
        var cs = ContentStream(height: 300)
        let prepared = try PreparedPage(page: Self.multilingual.pages[0], meta: Self.multilingual.meta, options: Self.options)
        var drawn: [String: Set<Int>] = [:]
        var report = RenderReport()
        for item in prepared.items {
            guard case .success(let (shaped, rotation)) = TextItems.shape(item, shaper: Self.options.shaper, report: &report)
            else { continue }
            cs.text(shaped, transform: rotation, fonts: &fonts)
            for run in shaped.lines.flatMap(\.runs) { drawn[run.face.key, default: [0]].formUnion(run.glyphs.map(\.glyph)) }
        }
        XCTAssertEqual(fonts.entries.count, 4)
        for var e in fonts.entries {
            let file = e.subset.font.isCFF ? try e.subset.openTypeCFFFile(cmap: [:]) : try e.subset.trueTypeFile()
            let parsed = try OpenTypeFont(data: file)
            let original = e.subset.font
            XCTAssertLessThanOrEqual(parsed.numGlyphs, (drawn.values.map(\.count).max() ?? 0) + 8)
            XCTAssertLessThan(file.count, 64 << 10, original.postScriptName)
            // Every subset glyph draws like the original.
            for (i, g) in e.subset.glyphs.enumerated() {
                XCTAssertEqual(try parsed.outline(i), try original.outline(g))
            }
        }
    }

    func testSVGEmbedsSubsetsAndSelectableText() throws {
        var report = RenderReport()
        let svg = try SVGWriter.export(note: Self.multilingual, options: Self.options, report: &report).pages[0]
        XCTAssertEqual(svg.components(separatedBy: "@font-face").count - 1, 4)
        // The invisible overlay carries the real characters.
        for line in ["Linear maps and kernels", "مرحبا بالعالم", "日本語のテキスト中文汉字"] {
            XCTAssertTrue(svg.contains(">\(line)</text>"), line)
        }
        XCTAssertTrue(svg.contains("direction=\"rtl\""))
        XCTAssertTrue(svg.contains("&#xE001;"), "glyphs through private-use code points")
        // The embedded fonts parse and map those code points.
        let uri = try XCTUnwrap(svg.range(of: "base64,"))
        let b64 = svg[uri.upperBound...].prefix { $0 != ")" }
        let font = try OpenTypeFont(data: [UInt8](try XCTUnwrap(Data(base64Encoded: String(b64)))))
        XCTAssertNotEqual(font.glyph(for: 0xE001), 0)
    }

    func testPNGDrawsGlyphs() throws {
        let note = Self.note([Self.box("Hello", 20, size: 40), Self.box("שלום", 120, size: 40)])
        let img = try PNG.decode(try PNGWriter.render(note: note, options: Self.options, png: PNGOptions(scale: 1))[0])
        func dark(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Int {
            var n = 0
            for y in y0..<y1 { for x in x0..<x1 where img.pixels[(y * img.width + x) * 4] < 100 { n += 1 } }
            return n
        }
        XCTAssertGreaterThan(dark(20, 140, 20, 70), 300, "Hello at the left")
        XCTAssertEqual(dark(250, 380, 20, 70), 0)
        XCTAssertGreaterThan(dark(280, 380, 120, 170), 300, "Hebrew starts at the right")
        XCTAssertEqual(dark(20, 150, 120, 170), 0)
    }

    func testReportNamesMissingScriptsAndApproximateShaping() throws {
        var report = RenderReport()
        _ = try PDFWriter.render(note: Self.note([Self.box("नमस्ते", 20), Self.box("ok", 60)]), options: Self.options,
                                 report: &report)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.warnings[0].contains("Devanagari"), report.warnings[0])
        XCTAssertTrue(report.warnings[0].contains("fonts-noto-core"))
        XCTAssertTrue(report.warnings[0].hasPrefix("page 1: item "), report.warnings[0])
        XCTAssertTrue(report.placeholders.isEmpty)
        // Without a shaper (the app's share export today), text is a reported
        // placeholder (format.md §8.5.2), never silently left out.
        report = RenderReport()
        let unshaped = try PDFWriter.render(note: Self.note([Self.box("ok", 20)]), options: RenderOptions(compress: false),
                                            report: &report)
        XCTAssertEqual(report.placeholders.map(\.reason), [.unsupportedKind("text")])
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertTrue(T.contains(unshaped, "0.604 0.627 0.651 RG"), "the placeholder is drawn")
        report = RenderReport()
        _ = try SVGWriter.render(note: Self.note([Self.box("ok", 20)]), report: &report)
        _ = try PNGWriter.render(note: Self.note([Self.box("ok", 20)]), png: PNGOptions(scale: 0.5), report: &report)
        XCTAssertEqual(report.placeholders.map(\.reason), [.unsupportedKind("text"), .unsupportedKind("text")])
        // Han without a pack: the suggestion is fonts-noto-cjk.
        let bare = DefaultTextShaper(library: FontLibrary(bundled: SempereFonts.directory, packs: []))
        report = RenderReport()
        _ = try PDFWriter.render(note: Self.note([Self.box("汉字", 20)]), options: RenderOptions(shaper: bare), report: &report)
        XCTAssertTrue(report.warnings.first?.contains("fonts-noto-cjk") ?? false, "\(report.warnings)")
    }

    /// A textual golden: a rotated box draws with one `cm`, glyphs shown by
    /// subset id with an upright text matrix.
    func testPDFContentStreamGolden() throws {
        let note = Self.note([Self.box("Hi", 20, size: 10, rotation: 90)])
        let pdf = try PDFWriter.render(note: note, options: RenderOptions(compress: false, shaper: TextLayoutTests.shaper))
        let text = String(decoding: pdf, as: UTF8.self)
        let expected = """
            q
            0 1 -1 0 235 -165 cm
            BT
            /T0 10 Tf
            0 0 0 rg
            1 0 0 -1 20 29.5 Tm <0001> Tj
            1 0 0 -1 27.41 29.5 Tm <0002> Tj
            ET
            Q
            """
        XCTAssertTrue(text.contains(expected), String(text[(text.range(of: "q\n0 1")?.lowerBound ?? text.startIndex)...].prefix(300)))
    }
}
