import Foundation
import Sempere
import SempereFonts
import XCTest

@testable import SempereRender

/// Text layout (format.md §8.5.3) and shaping with the CLI's shaper.
final class TextLayoutTests: XCTestCase {
    /// Bundled Noto plus the test fixtures as the only font pack.
    static let library: FontLibrary = {
        let fixtures = try? T.fixtureURL("fonts")
        return FontLibrary(bundled: SempereFonts.directory, packs: fixtures.map { [$0] } ?? [])
    }()
    static let shaper = DefaultTextShaper(library: library)
    static let black = Color(r: 0, g: 0, b: 0, a: 255)

    static func text(_ runs: [TextRun], size: Double = 10, align: TextContent.Alignment? = nil,
                     dir: TextContent.Direction? = nil, breaks: [Int]? = nil, lang: String? = nil) -> TextContent {
        TextContent(size: size, color: black, align: align, dir: dir, lang: lang, runs: runs, breaks: breaks)
    }

    static func lines(_ t: TextContent, width: Double = 200) throws -> ShapedText {
        try shaper.shape(t, frame: Rect(x: 10, y: 20, w: width, h: 100))
    }

    func testBundledFontsPresent() throws {
        XCTAssertNotNil(SempereFonts.directory, "the SempereFonts resource bundle")
        for family in [TextContent.Font.sans, .serif, .mono] {
            for (b, i) in [(false, false), (true, false), (false, true), (true, true)] {
                XCTAssertNotNil(Self.library.bundledFace(family, bold: b, italic: i), "\(family) \(b) \(i)")
            }
        }
    }

    // MARK: Lines and breaks

    func testStoredBreaksAreHonoured() throws {
        // "aaa bbb ccc": the writer broke after "aaa " and after "bbb " even though all fits.
        let t = Self.text([TextRun("aaa bbb ccc")], breaks: [4, 8])
        let s = try Self.lines(t, width: 1000)
        XCTAssertEqual(s.lines.map(\.text), ["aaa", "bbb", "ccc"])
        // Vertical metrics: lines 1.2 S apart, baseline 0.95 S below each top.
        let expected: [Double] = [29.5, 41.5, 53.5]
        XCTAssertEqual(s.lines.map(\.baseline), expected)
        XCTAssertEqual(s.bottom, 20 + 36, accuracy: 1e-9)
    }

    /// Stored breaks in several paragraphs: each paragraph takes its own
    /// (the breaks are sorted once for the whole text).
    func testStoredBreaksAcrossParagraphs() throws {
        // "aaa bbb\nccc ddd eee\nfff": breaks after "aaa ", "ccc " and "ddd ".
        let s = try Self.lines(Self.text([TextRun("aaa bbb\nccc ddd eee\nfff")], breaks: [4, 12, 16]), width: 1000)
        XCTAssertEqual(s.lines.map(\.text), ["aaa", "bbb", "ccc", "ddd", "eee", "fff"])
        XCTAssertEqual(s.lines.map(\.range), [0..<4, 4..<7, 8..<12, 12..<16, 16..<19, 20..<23])
    }

    /// `fallback` caches its choice: repeated and interleaved calls give the
    /// face a fresh library chooses, misses included.
    func testFallbackCacheMatchesFreshChoice() {
        let packs = (try? T.fixtureURL("fonts")).map { [$0] } ?? []
        let cached = FontLibrary(bundled: SempereFonts.directory, packs: packs)
        let queries: [(UInt32, String?, TextContent.Font, Bool, Bool)] = [
            (0x65E5, "ja", .sans, false, false), (0x65E5, "zh-Hant", .serif, true, false), (0x3042, nil, .mono, false, true),
            (0x0928, nil, .sans, false, false), (0x41, nil, .sans, false, false), (0x65E5, "ko", TextContent.Font(rawValue: "x"), false, false),
        ]
        for round in 0..<3 {
            for (c, lang, generic, bold, italic) in queries {
                let fresh = FontLibrary(bundled: SempereFonts.directory, packs: packs)
                    .fallback(for: c, lang: lang, generic: generic, bold: bold, italic: italic)
                let got = cached.fallback(for: c, lang: lang, generic: generic, bold: bold, italic: italic)
                XCTAssertEqual(got?.key, fresh?.key, "round \(round), U+\(String(c, radix: 16)) \(lang ?? "-")")
            }
        }
        XCTAssertNotNil(cached.fallback(for: 0x65E5, lang: "ja", generic: .sans, bold: false, italic: false))
    }

    func testInvalidBreaksAreIgnored() throws {
        for breaks in [[0], [4, 4], [8, 4], [11], [3, 99]] {   // at 0, not increasing, at the end, beyond
            let s = try Self.lines(Self.text([TextRun("aaa bbb ccc")], breaks: breaks), width: 1000)
            XCTAssertEqual(s.lines.map(\.text), ["aaa bbb ccc"], "\(breaks)")
        }
        // Inside a grapheme cluster (e + combining acute): ignored too.
        let s = try Self.lines(Self.text([TextRun("ae\u{301}b")], breaks: [2]), width: 1000)
        XCTAssertEqual(s.lines.count, 1)
        // After a line feed's first character only: a break right after "\n" is invalid.
        XCTAssertEqual(try Self.lines(Self.text([TextRun("ab\ncd")], breaks: [3]), width: 1000).lines.count, 2)
    }

    func testGreedyBreakingAndLongWords() throws {
        // Without breaks: UAX #14 opportunities, greedy, trailing spaces not counted.
        let words = "alpha beta gamma delta epsilon"
        let narrow = try Self.lines(Self.text([TextRun(words)]), width: 60)
        XCTAssertGreaterThan(narrow.lines.count, 2)
        XCTAssertEqual(narrow.lines.map(\.text).joined(separator: " "), words)
        for l in narrow.lines { XCTAssertLessThanOrEqual(l.width, 60 + 1e-9, l.text) }
        // A word wider than the frame breaks between grapheme clusters.
        let long = try Self.lines(Self.text([TextRun("Donaudampfschiffahrtsgesellschaft")]), width: 50)
        XCTAssertGreaterThan(long.lines.count, 2)
        XCTAssertEqual(long.lines.map(\.text).joined(), "Donaudampfschiffahrtsgesellschaft")
        // Hyphen and CJK opportunities.
        let hy = try Self.lines(Self.text([TextRun("well-known")]), width: 30)
        XCTAssertEqual(hy.lines.first?.text, "well-")
    }

    func testEmptyLinesTabsAndMixedSizes() throws {
        let s = try Self.lines(Self.text([TextRun("Title", size: 20), TextRun("\n\nbody\ta")]), width: 500)
        XCTAssertEqual(s.lines.map(\.text), ["Title", "body\ta"])
        // 20 pt line, then an empty line of the run holding its line feed (10), then body.
        XCTAssertEqual(s.lines[0].baseline, 20 + 19, accuracy: 1e-9)
        XCTAssertEqual(s.lines[1].baseline, 20 + 24 + 12 + 9.5, accuracy: 1e-9)
        // A tab advances like four spaces.
        let font = try XCTUnwrap(Self.library.bundledFace(.sans, bold: false, italic: false)).font
        let space = Double(font.advance(font.glyph(for: 0x20))) * 10 / Double(font.unitsPerEm)
        let glyphs = s.lines[1].runs.flatMap(\.glyphs)
        let tab = try XCTUnwrap(glyphs.first { $0.text == "\t" })
        XCTAssertEqual(tab.advance, 4 * space, accuracy: 1e-9)
    }

    func testAlignment() throws {
        let frame = Rect(x: 10, y: 20, w: 200, h: 50)
        func line(_ align: TextContent.Alignment?, _ dir: TextContent.Direction?, _ text: String) throws -> ShapedLine {
            try Self.shaper.shape(Self.text([TextRun(text)], align: align, dir: dir), frame: frame).lines[0]
        }
        let l = try line(nil, nil, "abc")
        XCTAssertEqual(l.x, 10)
        XCTAssertEqual(try line(.end, nil, "abc").x + l.width, 210, accuracy: 1e-9)
        XCTAssertEqual(try line(.center, nil, "abc").x, 10 + (200 - l.width) / 2, accuracy: 1e-9)
        XCTAssertEqual(try line(.right, nil, "abc").x + l.width, 210, accuracy: 1e-9)
        // start/end follow the paragraph direction; left/right do not.
        let h = try line(nil, nil, "שלום")
        XCTAssertTrue(h.rtl)
        XCTAssertEqual(h.x + h.width, 210, accuracy: 1e-9)
        XCTAssertEqual(try line(.end, nil, "שלום").x, 10)
        XCTAssertEqual(try line(.left, nil, "שלום").x, 10)
        XCTAssertEqual(try line(nil, .rtl, "abc").x + l.width, 210, accuracy: 1e-9)
        // A line wider than the frame overflows on its end side, never re-broken.
        let wide = try Self.shaper.shape(Self.text([TextRun("abcdefghij")], breaks: nil), frame: Rect(x: 10, y: 0, w: 1, h: 1))
        XCTAssertGreaterThan(wide.lines.count, 1)   // no stored breaks: broken by clusters
        let kept = try Self.shaper.shape(Self.text([TextRun("abc def")], breaks: [4]), frame: Rect(x: 10, y: 0, w: 1, h: 1))
        XCTAssertEqual(kept.lines.map(\.text), ["abc", "def"])
        XCTAssertEqual(kept.lines[0].x, 10)
    }

    func testDecorationsAndSyntheticFaces() throws {
        let s = try Self.lines(Self.text([TextRun("under", u: true), TextRun(" strike", s: true)]), width: 500)
        XCTAssertFalse(s.decorations.isEmpty)
        let base = s.lines[0].baseline
        let under = try XCTUnwrap(s.decorations.first)
        XCTAssertEqual(under.height, 10.0 / 18, accuracy: 1e-9)
        XCTAssertEqual(under.y + under.height / 2, base + 1.2, accuracy: 1e-9)
        let strike = try XCTUnwrap(s.decorations.last)
        XCTAssertEqual(strike.y + strike.height / 2, base - 3, accuracy: 1e-9)
        // Mono has no italic face: slanted synthetically.
        let mono = try Self.shaper.shape(TextContent(font: .mono, size: 10, color: Self.black, runs: [TextRun("x", i: true)]),
                                         frame: Rect(x: 0, y: 0, w: 100, h: 10))
        XCTAssertTrue(mono.lines[0].runs[0].syntheticItalic)
        XCTAssertFalse(mono.lines[0].runs[0].syntheticBold)
    }

    // MARK: Right to left, against HarfBuzz

    struct Reference: Decodable {
        struct Glyph: Decodable { var glyph: Int; var cluster: Int; var advance: Int; var dx: Int; var dy: Int }
        var font: String
        var text: String
        var glyphs: [Glyph]
    }

    /// Arabic joins (initial/medial/final forms, lam-alef) and Hebrew and
    /// Arabic marks attach like HarfBuzz's shaping of the same fonts: the
    /// same glyphs at the same positions (font units, ±1).
    func testRightToLeftMatchesHarfBuzz() throws {
        let refs = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: T.fixtureURL("fonts/harfbuzz.json")))
        for ref in refs {
            let face = try XCTUnwrap(Self.library.load(try T.fixtureURL("fonts/" + ref.font), face: 0))
            let upem = Double(face.font.unitsPerEm)
            let s = try Self.shaper.shape(Self.text([TextRun(ref.text)], size: upem), frame: Rect(x: 0, y: 0, w: 1e5, h: 1e4))
            XCTAssertEqual(s.lines.count, 1)
            let line = s.lines[0]
            XCTAssertTrue(line.rtl, ref.text)
            var ours: [[Int]] = []
            for run in line.runs where run.face.url.lastPathComponent == ref.font {
                for g in run.glyphs where g.glyph != face.font.glyph(for: 0x20) {
                    ours.append([g.glyph, Int((g.x - line.x).rounded()), Int((line.baseline - g.y).rounded())])
                }
            }
            var theirs: [[Int]] = []
            var pen = 0
            for g in ref.glyphs {
                if g.glyph != face.font.glyph(for: 0x20) { theirs.append([g.glyph, pen + g.dx, g.dy]) }
                pen += g.advance
            }
            XCTAssertEqual(ours.sorted { $0.lexicographicallyPrecedes($1) }.count, theirs.count, ref.text)
            for (a, b) in zip(ours.sorted { $0.lexicographicallyPrecedes($1) }, theirs.sorted { $0.lexicographicallyPrecedes($1) }) {
                XCTAssertEqual(a[0], b[0], ref.text)
                XCTAssertEqual(Double(a[1]), Double(b[1]), accuracy: 1, "\(ref.text) glyph \(a[0])")
                XCTAssertEqual(Double(a[2]), Double(b[2]), accuracy: 1, "\(ref.text) glyph \(a[0])")
            }
            XCTAssertEqual(Double(line.width), Double(pen), accuracy: 1, ref.text)
        }
    }

    func testMixedDirectionsReorder() throws {
        // "abc" then Hebrew in an LTR paragraph: the Hebrew word reads right to left, after "abc ".
        let s = try Self.lines(Self.text([TextRun("abc שלום def")]), width: 1000)
        let text = s.lines[0].runs.flatMap(\.glyphs).map(\.text).joined()
        XCTAssertEqual(text, "abc םולש def")
        XCTAssertFalse(s.lines[0].rtl)
    }

    // MARK: Font packs and missing scripts

    func testCJKComesFromAFontPack() throws {
        let s = try Self.lines(Self.text([TextRun("中文汉字と日本語")], lang: "ja"), width: 1000)
        XCTAssertTrue(s.missingScripts.isEmpty, "\(s.missingScripts)")
        let faces = Set(s.lines.flatMap(\.runs).map(\.face.url.lastPathComponent))
        XCTAssertEqual(faces, ["cjk.otf"])
        // Ideographs break between each other (UAX #14 ID).
        let narrow = try Self.lines(Self.text([TextRun("日本語のテキスト")], lang: "ja"), width: 25)
        XCTAssertGreaterThan(narrow.lines.count, 2)
    }

    func testMissingScriptIsReported() throws {
        // Devanagari: neither bundled nor in the fixture pack.
        let s = try Self.lines(Self.text([TextRun("नमस्ते and ok")]), width: 1000)
        XCTAssertEqual(Set(s.missingScripts.keys), ["Devanagari"])
        XCTAssertTrue(s.approximateScripts.contains("Devanagari"))
        // The missing characters are drawn as .notdef (glyph 0), the rest normally.
        let glyphs = s.lines[0].runs.flatMap(\.glyphs)
        XCTAssertTrue(glyphs.contains { $0.glyph == 0 })
        XCTAssertTrue(glyphs.contains { $0.text == "o" && $0.glyph != 0 })
    }

    // MARK: Bounded work (format.md §9)

    /// Text at the format's limit (65 536 UTF-8 bytes) in the shapes that
    /// would be quadratic: one unbreakable word in a narrow frame (thousands
    /// of lines), many words in a very wide frame (one long line), only
    /// spaces, Arabic with a mark on every letter. Each lays out in time
    /// proportional to its length.
    func testMaximumTextLaysOutInBoundedTime() throws {
        let cases: [(String, Double)] = [
            (String(repeating: "a", count: 65_000), 30),
            (String(repeating: "ab ", count: 21_000), 1e5),
            (String(repeating: " ", count: 65_000), 100),
            (String(repeating: "\u{628}\u{64E}", count: 16_000), 200),
        ]
        for (text, width) in cases {
            let t0 = Date()
            let s = try Self.shaper.shape(Self.text([TextRun(text)]), frame: Rect(x: 0, y: 0, w: width, h: 10))
            let elapsed = Date().timeIntervalSince(t0)
            XCTAssertLessThan(elapsed, 60, "\(text.prefix(3)) × \(text.unicodeScalars.count), width \(width): \(elapsed) s")
            XCTAssertTrue(text.hasPrefix(" ") || !s.lines.isEmpty)
        }
    }
}
