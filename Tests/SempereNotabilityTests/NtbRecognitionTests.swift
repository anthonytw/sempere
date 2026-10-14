import Foundation
import ImportTestSupport
import XCTest
import Sempere
@testable import SempereImport
@testable import SempereNotability

/// Notability's recognition in `.ntb` bundles (`ios/HandwritingIndex.fb`).
final class NtbRecognitionTests: XCTestCase {
    static func note(index: Data?) throws -> NotabilityNote {
        let bundle = SyntheticBundle.noteBundle(strokes: SyntheticBundle.strokesMatchingSyntheticNote())
        let pkg = NotePackage(zip: try ZipArchive(data: SyntheticBundle.package(bundle, handwritingIndex: index)))
        return try NotabilityBundle.parse(package: pkg)
    }

    /// Two pages, listed out of order, map to one recognition: texts in page
    /// order, words in page coordinates, the second page one page height lower.
    func testTwoPagesMapLikeTheInk() throws {
        let index = SyntheticBundle.handwritingIndex([
            .init(index: 1, text: "two", boxes: [(40, 30, 10, 12), (50, 30, 10, 12), (60, 30, 10, 12)]),
            .init(index: 0, text: "hi you", boxes: [(36, 20, 8, 10), (44, 20, 4, 10), nil, (60, 22, 9, 10), (69, 22, 9, 10), (78, 22, 9, 10)]),
        ])
        let note = try Self.note(index: index)
        XCTAssertEqual(note.recognition.keys.sorted(), [1, 2])
        let rec = try XCTUnwrap(NotabilityImporter.recognition(note))
        XCTAssertEqual(rec.text, "hi you\ntwo")
        XCTAssertEqual(rec.words.map(\.text), ["hi", "you", "two"])
        let h = note.paper.pageHeight
        XCTAssertEqual(rec.words[0].box, Recognition.Box(x: 36, y: 20, w: 12, h: 10))
        XCTAssertEqual(rec.words[1].box, Recognition.Box(x: 60, y: 22, w: 27, h: 10))
        XCTAssertEqual(rec.words[2].box.x, 40)
        XCTAssertEqual(rec.words[2].box.y, 30 + h, accuracy: 1e-9)
        XCTAssertEqual(rec.words[2].box.w, 30)
    }

    /// The boxes land where the bundle's strokes are placed (both use page
    /// coordinates; the importer shifts both by the same inset).
    func testBoxesShareTheInkCoordinates() throws {
        let strokes = SyntheticBundle.strokesMatchingSyntheticNote()
        let firstStroke = try XCTUnwrap(try Self.note(index: nil).curves.first)
        let (x0, y0) = (Double(strokes[0].origin.0), Double(strokes[0].origin.1))
        let note = try Self.note(index: SyntheticBundle.handwritingIndex([.init(index: 0, text: "a", boxes: [(x0, y0, 5, 5)])]))
        let state = NotabilityImporter.convert(note, key: "t")
        let word = try XCTUnwrap(state.pages.first?.recognition?.words.first)
        let ink = try XCTUnwrap(state.pages.first?.strokes.first?.points.first)
        XCTAssertEqual(word.box.x, ink.x, accuracy: 0.5, "box x \(word.box.x) vs ink x \(ink.x), \(firstStroke.points.first!)")
        XCTAssertEqual(word.box.y, ink.y, accuracy: 0.5)
    }

    /// A bundle without an index, or with a broken one, still imports its ink.
    func testMissingOrBrokenIndexKeepsTheInk() throws {
        let plain = try Self.note(index: nil)
        XCTAssertTrue(plain.recognition.isEmpty)
        var broken = SyntheticBundle.handwritingIndex([.init(index: 0, text: "x", boxes: [(1, 1, 1, 1)])])
        broken.replaceSubrange(0..<4, with: [0xFF, 0xFF, 0xFF, 0x7F])
        let note = try Self.note(index: broken)
        XCTAssertTrue(note.recognition.isEmpty)
        XCTAssertEqual(note.curves.count, plain.curves.count)
    }

    /// Hostile shapes are refused rather than trusted.
    func testHostileIndexes() throws {
        // More boxes than characters.
        XCTAssertThrowsError(try NotabilityBundle.parseHandwritingIndex(
            SyntheticBundle.handwritingIndex([.init(index: 0, text: "a", boxes: [(1, 1, 1, 1), (2, 2, 2, 2)])]), inset: 0))
        // A page index beyond the limit and a duplicate page are skipped.
        let pages = try NotabilityBundle.parseHandwritingIndex(SyntheticBundle.handwritingIndex([
            .init(index: UInt32(NotabilityNote.maxRecognizedPage), text: "far", boxes: []),
            .init(index: 0, text: "first", boxes: []),
            .init(index: 0, text: "again", boxes: []),
        ]), inset: 0)
        XCTAssertEqual(pages.keys.sorted(), [1])
        XCTAssertEqual(pages[1]?.text, "first")
        // Coordinates beyond the format's range become "no box".
        let far = try NotabilityBundle.parseHandwritingIndex(
            SyntheticBundle.handwritingIndex([.init(index: 0, text: "a", boxes: [(60000, 1, 1, 1)])]), inset: 0)
        XCTAssertEqual(far[1]?.characterBoxes.count, 1)
    }
}
