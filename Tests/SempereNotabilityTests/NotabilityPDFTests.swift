import Age
import Foundation
import ImportTestSupport
import Sempere
import XCTest
@testable import SempereImport
@testable import SempereNotability

/// Notes laid out on imported PDF pages (synthetic, no personal data).
final class NotabilityPDFTests: XCTestCase {
    /// Landscape slides, as Notability stores them: 4:3 thumbnails.
    static let slideThumbs = [("thumb.png", 48, 36), ("thumb2x.png", 96, 72), ("thumb12x.png", 576, 432)]

    func testPDFPagesStackAtRoundedUpHeight() throws {
        let note = try NotabilityNote.parse(data: SyntheticNote.package(pdfPages: 3, thumbnails: Self.slideThumbs))
        XCTAssertEqual(note.pdfCount, 1)
        XCTAssertEqual(note.pdfPageCount, 3)
        // 716.8 × 0.75 = 537.6; PDF pages repeat every 538 units.
        XCTAssertEqual(note.paper.pageHeight, 538, accuracy: 1e-9)

        let raw = NotabilityImporter.convert(note, scaleToLetterWidth: false)
        XCTAssertEqual(raw.meta.pageSize.breakHeight ?? 0, 538, accuracy: 1e-9)
        let scaled = NotabilityImporter.convert(note)
        XCTAssertEqual(scaled.meta.pageSize.breakHeight ?? 0, 538 * 612 / 716.8, accuracy: 1e-9)

        // Recognition on page 2 is offset by one stride.
        let words = try XCTUnwrap(raw.pages[0].recognition?.words)
        XCTAssertEqual(words.last?.box.y ?? 0, 49 + 538, accuracy: 1e-9)

        // Ink is placed exactly as on paper: the layout only moves breaks and recognition.
        let paper = NotabilityImporter.convert(try NotabilityNote.parse(data: SyntheticNote.package()),
                                               scaleToLetterWidth: false)
        XCTAssertEqual(raw.pages[0].strokes, paper.pages[0].strokes)
        XCTAssertEqual(NotabilityImporter.dropped(note).pdfPages, 3)
        XCTAssertEqual(NotabilityImporter.dropped(note).pdfs, 1)
    }

    func testWholeUnitPDFPageIsNotRoundedFurther() throws {
        // A 572-wide note on 4:3 slides: 572 × 0.75 = 429 exactly.
        let files = SyntheticNote.files(pdfPages: 2, thumbnails: Self.slideThumbs).map { path, data in
            TestZip.File(path: path, data: path.hasSuffix("Session.plist") ? Self.relocked(data, to: "572.0:Mac") : data)
        }
        let note = try NotabilityNote.parse(data: TestZip.write(files))
        XCTAssertEqual(note.paper.width, 572, accuracy: 1e-9)
        XCTAssertEqual(note.paper.pageHeight, 429, accuracy: 1e-9)
    }

    /// Rewrites the `lockedWidth:716.8:iPad` sizing string of a session
    /// archive in place (same byte length, padded with spaces).
    static func relocked(_ session: Data, to value: String) -> Data {
        let old = Data("lockedWidth:716.8:iPad".utf8), new = Data("lockedWidth:\(value)".utf8)
        precondition(new.count <= old.count)
        guard let r = session.range(of: old) else { return session }
        var out = session
        out.replaceSubrange(r, with: new + Data(repeating: 0x20, count: old.count - new.count))
        return out
    }

    /// Thumbnails round the page height down to whole pixels (letter at 576
    /// px: 745.4 → 744), which made the stride of letter PDF pages 739 instead
    /// of 741 on a 572-wide note (and 926 instead of 928 at 716.8), drifting
    /// two units per page against Notability's own PDF export. A standard
    /// aspect within two thumbnail pixels is used instead.
    func testThumbnailAspectSnapsToLetter() throws {
        let thumbs = [("thumb.png", 48, 62), ("thumb8x.png", 384, 496), ("thumb12x.png", 576, 744)]
        let files = SyntheticNote.files(pdfPages: 3, thumbnails: thumbs).map { path, data in
            TestZip.File(path: path, data: path.hasSuffix("Session.plist") ? Self.relocked(data, to: "572.0:Mac") : data)
        }
        XCTAssertEqual(try NotabilityNote.parse(data: TestZip.write(files)).paper.pageHeight, 741, accuracy: 1e-9)
        let ipad = try NotabilityNote.parse(data: SyntheticNote.package(pdfPages: 3, thumbnails: thumbs))
        XCTAssertEqual(ipad.paper.pageHeight, 928, accuracy: 1e-9)
        // An aspect no standard size is near stays as measured.
        XCTAssertEqual(NotabilityNote.snapAspect(1.2, thumbnailWidth: 384), 1.2)
        XCTAssertEqual(NotabilityNote.snapAspect(744.0 / 576, thumbnailWidth: 576), 11 / 8.5)
    }

    func testLargestThumbnailGivesTheAspect() throws {
        // thumb.png rounds 576 × 432 down to 48 × 37; the 12× thumbnail is exact.
        let note = try NotabilityNote.parse(data: SyntheticNote.package(
            thumbnails: [("thumb.png", 48, 37), ("thumb12x.png", 576, 432)]))
        XCTAssertEqual(note.pdfPageCount, 0)
        // Paper pages are not rounded.
        XCTAssertEqual(note.paper.pageHeight, 537.6, accuracy: 1e-9)
    }

    func testPaperNoteUnchanged() throws {
        let note = try NotabilityNote.parse(data: SyntheticNote.package(
            thumbnails: [("thumb.png", 48, 63), ("thumb12x.png", 576, 756)]))
        XCTAssertEqual(note.pdfPageCount, 0)
        XCTAssertEqual(note.paper.pageHeight, 940.8, accuracy: 1e-9)
        XCTAssertEqual(NotabilityImporter.dropped(note).pdfPages, 0)
    }

    /// A PDF that was never written on: no curves, no handwriting index.
    func testInklessPDFNoteImportsEmptyAndReportsItsPages() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inkimport-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent("Deck.note")
        try SyntheticNote.package(curves: [], pdfPages: 94, thumbnails: Self.slideThumbs, handwriting: false).write(to: path)

        let note = try NotabilityNote.parse(data: try Data(contentsOf: path))
        XCTAssertEqual(note.curves.count, 0)
        XCTAssertTrue(note.recognition.isEmpty)
        XCTAssertEqual(note.pdfPageCount, 94)

        let identity = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: tmp.appendingPathComponent("V.sempere"), recipients: [identity.recipient],
                                     identities: [identity])
        var clock = HybridClock()
        let report = try NotabilityImporter.import(paths: [path], into: vault, device: DeviceID("0a0b0c0d")!, clock: &clock)
        let r = try XCTUnwrap(report.notes.first)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.strokes, 0)
        XCTAssertEqual(r.dropped.pdfs, 1)
        XCTAssertEqual(r.dropped.pdfPages, 94)
        let state = try vault.reconstruct(noteId: try XCTUnwrap(r.noteId))
        XCTAssertEqual(state.pages.count, 1)
        XCTAssertEqual(state.pages[0].strokes.count, 0)
        XCTAssertEqual(state.meta.pageSize.breakHeight ?? 0, 538 * 612 / 716.8, accuracy: 1e-9)
    }

    // MARK: - Untrusted geometry (review of #18)

    func testWidestThumbnailWinsWhateverItsName() throws {
        // Sorted by name the 2x thumbnail comes last; it is narrower, so the 12x one wins.
        let note = try NotabilityNote.parse(data: SyntheticNote.package(
            thumbnails: [("thumb.png", 48, 37), ("thumb12x.png", 576, 432), ("thumb2x.png", 96, 73)]))
        XCTAssertEqual(note.paper.pageHeight, 537.6, accuracy: 1e-9)
    }

    /// A degenerate thumbnail made the PDF page height round to 0 (and the
    /// note's `breakHeight` with it) or grow to 10¹² units.
    func testImplausibleThumbnailAspectIsIgnored() throws {
        for thumbs in [[("thumb.png", 0xFFFF_FFFF, 1)], [("thumb.png", 1, 0x7FFF_FFFF)], [("thumb.png", 0, 36)]] {
            let note = try NotabilityNote.parse(data: SyntheticNote.package(pdfPages: 2, thumbnails: thumbs))
            XCTAssertEqual(note.paper.pageHeight, 941, accuracy: 1e-9, "\(thumbs)")   // ⌈716.8 × 21/16⌉
        }
        // The widest thumbnail is skipped when implausible, not the note's aspect.
        let note = try NotabilityNote.parse(data: SyntheticNote.package(
            pdfPages: 2, thumbnails: [("thumb.png", 48, 36), ("thumb12x.png", 0xFFFF_FFFF, 1)]))
        XCTAssertEqual(note.paper.pageHeight, 538, accuracy: 1e-9)
        let size = NotabilityImporter.convert(note).meta.pageSize
        XCTAssertGreaterThan(size.breakHeight ?? 0, 0)
    }

    /// `custom:<w/h>` near 0 gave an infinite page height (the note failed to
    /// encode); a huge one a height of 0.
    func testImplausibleCustomPaperSizeFallsBackToTheThumbnail() throws {
        for size in ["custom:5e-324", "custom:1e308", "custom:0.001"] {
            let note = try NotabilityNote.parse(data: SyntheticNote.package(
                pdfPages: 2, thumbnails: Self.slideThumbs, paperSize: size))
            XCTAssertEqual(note.paper.pageHeight, 538, accuracy: 1e-9, size)
            XCTAssertNoThrow(try JSONEncoder().encode(NotabilityImporter.convert(note)), size)
        }
        let plausible = try NotabilityNote.parse(data: SyntheticNote.package(paperSize: "custom:0.5"))
        XCTAssertEqual(plausible.paper.pageHeight, 716.8 * 2, accuracy: 1e-9)
    }

    /// A locked width near 0 scaled the ink to infinity (NaN page size); a
    /// huge one squashed it to 0. Both fall back to the reflow width.
    func testImplausibleLockedWidthIsIgnored() throws {
        for value in ["5e-324:iP", "1e-9:iPad", "1e308:iPad"] {
            let files = SyntheticNote.files(pdfPages: 2, thumbnails: Self.slideThumbs).map { path, data in
                TestZip.File(path: path, data: path.hasSuffix("Session.plist") ? Self.relocked(data, to: value) : data)
            }
            let note = try NotabilityNote.parse(data: TestZip.write(files))
            XCTAssertEqual(note.paper.width, 716.8, accuracy: 1e-9, value)
            XCTAssertEqual(note.paper.pageHeight, 538, accuracy: 1e-9, value)
            let state = NotabilityImporter.convert(note)
            XCTAssertTrue(state.pages[0].strokes.allSatisfy { $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
            XCTAssertNoThrow(try JSONEncoder().encode(state), value)
        }
    }

    /// Reading every thumbnail (not just the first) must not make a corrupt
    /// one fail a note that imported before.
    func testUnreadableThumbnailIsSkipped() throws {
        var zip = SyntheticNote.package(pdfPages: 2, thumbnails: [("thumb.png", 48, 36), ("thumb12x.png", 576, 433)])
        let stored = SyntheticNote.png(width: 576, height: 433)
        let r = try XCTUnwrap(zip.range(of: stored))
        zip[r.upperBound - 1] ^= 0xFF   // CRC mismatch on read
        let note = try NotabilityNote.parse(data: zip)
        XCTAssertEqual(note.paper.pageHeight, 538, accuracy: 1e-9)   // from thumb.png's 4:3
    }
}
