import Foundation
import ImportTestSupport
import Sempere
import SempereRender
import XCTest

@testable import SempereImport
@testable import SempereNotability

/// Regression tests for hostile Notability attachments (typed text, text
/// boxes, images, recordings; docs/import-notability.md "Attachments"): each
/// imports within the format's limits or is reported, never traps or runs
/// without bound (format.md §9).
final class UntrustedAttachmentImportTests: XCTestCase {
    func resolve(_ package: Data, maxHeldBytes: Int = NotabilityAttachments.maxHeldBytes)
        throws -> (NotabilityNote, NotabilityAttachments) {
        let pkg = try NotePackage(data: package)
        let note = try NotabilityNote.parse(package: pkg)
        return (note, NotabilityAttachments.resolve(note, package: pkg, keepImageMetadata: false, maxHeldBytes: maxHeldBytes))
    }

    /// Every item of every page lies within the renderer's extent (format.md §8.4).
    func assertWithinExtent(_ state: NoteState, file: StaticString = #filePath, line: UInt = #line) {
        let e = RenderLimits.maxExtent
        for page in state.pages {
            for item in page.items {
                let f = item.frame
                XCTAssertTrue(abs(f.x) <= e && abs(f.x + f.w) <= e && abs(f.y) <= e && abs(f.y + f.h) <= e,
                              "\(f)", file: file, line: line)
                XCTAssertNil(item.validationError, file: file, line: line)
            }
        }
    }

    // MARK: - Audio containers

    /// An `mvhd` box with no body as the file's last bytes: the importer's own
    /// MPEG-4 walker read the version byte past the end (a trap). MPEG-4 files
    /// now go through `AudioProbe`.
    func testMP4WithAnEmptyMovieHeaderAtTheEndDoesNotTrap() {
        let ftyp = AttachmentFixtures.box("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0])
        let file = Data(ftyp + AttachmentFixtures.box("moov", AttachmentFixtures.box("mvhd", [])))
        let c = AudioContainer.read(file)
        XCTAssertEqual(c?.type, "audio/mp4")
        XCTAssertNil(c?.duration)
    }

    /// A CAF rate of 1e-300 Hz made any frame count an infinite duration,
    /// which JSON cannot hold.
    func testCAFWithAnAbsurdRateHasNoDuration() throws {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            Array(type.utf8) + AttachmentFixtures.be(UInt64(body.count), 8) + body
        }
        for rate in [1e-300, 0.5, Double.nan, 1e300] {
            let desc = AttachmentFixtures.be(rate.bitPattern, 8) + Array("aac ".utf8) + [UInt8](repeating: 0, count: 20)
            let pakt = AttachmentFixtures.be(10, 8) + AttachmentFixtures.be(1 << 40, 8) + [UInt8](repeating: 0, count: 8)
            let caf = Data(Array("caff".utf8) + [0, 1, 0, 0] + chunk("desc", desc) + chunk("pakt", pakt))
            let c = try XCTUnwrap(AudioContainer.read(caf))
            XCTAssertNil(c.duration, "\(rate)")
            XCTAssertNil(c.sampleRate, "\(rate)")
        }
    }

    /// Recordings are held in memory until the note is written: they count
    /// against the same per-note budget as PDFs and images.
    func testRecordingsCountAgainstTheHeldBytes() throws {
        let m4a = AttachmentFixtures.m4a(seconds: 2)
        let library = AttachmentFixtures.library([("a", "<key>fileName</key><string>a.m4a</string>"),
                                                  ("b", "<key>fileName</key><string>b.m4a</string>")])
        var second = m4a
        second.append(0)   // other bytes: not deduplicated
        let pkg = AttachmentFixtures.package(session: SyntheticNote.session(),
                                             extra: [("Recordings/library.plist", library), ("Recordings/a.m4a", m4a),
                                                     ("Recordings/b.m4a", second)])
        let (_, a) = try resolve(pkg, maxHeldBytes: m4a.count + 1)
        XCTAssertEqual(a.recordings.count, 1)
        XCTAssertEqual(a.dropped.recordings, 1)
        XCTAssertLessThanOrEqual(a.blobs.values.reduce(0) { $0 + $1.data.count }, m4a.count + 1)
        XCTAssertTrue(a.warnings.contains { $0.contains("MiB of attachments read for one note") }, "\(a.warnings)")
        // The same file twice is held once.
        let twice = AttachmentFixtures.package(session: SyntheticNote.session(),
                                               extra: [("Recordings/library.plist", library), ("Recordings/a.m4a", m4a),
                                                       ("Recordings/b.m4a", m4a)])
        let (_, b) = try resolve(twice, maxHeldBytes: m4a.count + 1)
        XCTAssertEqual(b.recordings.count, 2)
    }

    // MARK: - Shared archive objects

    /// 10 000 style entries sharing one subtree of 4 096 values made a 49 KB
    /// package walk 41 million values (five minutes in a debug build): the
    /// walks of one note now share one budget.
    func testSharedStyleEntriesAreWalkedOnOneBudget() throws {
        let session = SyntheticNote.session(attributed: { a in
            let z = a.string("z")
            let y = a.array(Array(repeating: z, count: 64))
            let x = a.array(Array(repeating: y, count: 64))
            let entry = a.dict([("rangeKey", a.string("{0, 1}")), ("fontSize", .real(12)), ("x", x)])
            return a.dict([("stringKey", a.string("hello")), ("subRangesKey", a.array(Array(repeating: entry, count: 10_000)))])
        })
        let note = try NotabilityNote.parse(package: NotePackage(data: AttachmentFixtures.package(session: session)))
        let perEntry = NotabilityNote.MediaObject.maxValues
        XCTAssertLessThanOrEqual(note.typed.runs.count, NotabilityNote.MediaObject.maxValuesPerNote / perEntry + 1)
        XCTAssertFalse(note.typed.runs.isEmpty)
    }

    /// One object with 20 000 fields listed 50 000 times as a media object:
    /// each reference decoded (copied) all its fields again. Objects are now
    /// decoded once per archive, and media objects read up to the limit.
    func testSharedObjectIsDecodedOnce() throws {
        let session = SyntheticNote.session(typed: "", media: { a in
            let v = a.string("v")
            let big = a.object("ImageMediaObject", (0..<20_000).map { ("field\($0)", v) })
            return Array(repeating: big, count: 50_000)
        })
        let t0 = Date()
        let (note, a) = try resolve(AttachmentFixtures.package(session: session))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 30)
        XCTAssertEqual(note.mediaCount, 50_000)
        XCTAssertEqual(note.mediaObjects.count, NotabilityAttachments.maxMediaObjects)
        XCTAssertEqual(a.dropped.media, 50_000)
        XCTAssertTrue(a.warnings.contains { $0.contains("from number 1001 on not read") }, "\(a.warnings.suffix(2))")
    }

    /// Decoding once keeps what a dictionary held, and its failures.
    func testCachedDecodingMatchesTheArchive() throws {
        var b = KeyedArchiveBuilder()
        let d = b.dict([("a", .int(1)), ("b", b.string("two"))])
        let bad = b.object("NSDictionary", [("NS.keys", .array([.int(1)])), ("NS.objects", .array([]))])
        let root = b.array([d, d, bad])
        let data = b.archive(top: [("root", root)])
        let archive = try KeyedArchive(data: data)
        let top = try archive.root("root")
        guard case .array(let refs) = top else { return XCTFail("\(top)") }
        for r in refs.prefix(2) {
            let n = try archive.node(r)
            XCTAssertEqual(n.raw("a"), .int(1))
            XCTAssertEqual(try archive.field(n, "b").string, "two")
        }
        XCTAssertThrowsError(try archive.node(refs[2])) { XCTAssertTrue($0 is ImportError) }
    }

    // MARK: - Frames within the extent

    /// Frames up to ±1e6 units passed, and a renderer refuses anything beyond
    /// 200 000 (format.md §8.4): such an image or text box is reported.
    func testFramesBeyondTheExtentAreReported() throws {
        let jpeg = AttachmentFixtures.jpeg(width: 40, height: 30, orientation: nil)
        let path = "Images/5B0A-photo.jpg"
        let session = SyntheticNote.session(typed: "", media: { a in
            [AttachmentFixtures.imageObject(&a, file: path, origin: (900_000, 10), size: (300, 400)),
             AttachmentFixtures.imageObject(&a, file: path, origin: (10, 10), size: (300, 900_000)),
             a.object("TextBoxMediaObject", [("frame", a.string("{{-900000, 60}, {200, 50}}")), ("string", a.string("far"))]),
             AttachmentFixtures.imageObject(&a, file: path, origin: (10, 10), size: (300, 400))]
        })
        let (note, a) = try resolve(AttachmentFixtures.package(session: session, extra: [(path, jpeg)]))
        XCTAssertEqual(a.imported.images, 1)
        XCTAssertEqual(a.imported.textItems, 0)
        XCTAssertEqual(a.dropped.media, 3)
        XCTAssertEqual(a.warnings.filter { $0.contains("beyond the page extent") }.count, 3, "\(a.warnings)")
        for scale in [true, false] {
            assertWithinExtent(NotabilityImporter.convert(note, scaleToLetterWidth: scale, attachments: a))
        }
    }

    /// Typed text at 1 000 points: estimated boxes were millions of units tall,
    /// and a note of them would be cut into millions of sheets.
    func testHugeTypedTextStaysWithinTheExtent() throws {
        let line = String(repeating: "w", count: 2_000)
        let text = Array(repeating: line, count: 40).joined(separator: "\n\n")
        let session = SyntheticNote.session(attributed: { a in
            a.dict([("stringKey", a.string(text)),
                    ("subRangesKey", a.array([a.dict([("rangeKey", a.string("{0, \(text.utf16.count)}")),
                                                      ("fontSize", .real(1_000))])]))])
        })
        let (note, a) = try resolve(AttachmentFixtures.package(session: session))
        XCTAssertGreaterThan(a.imported.textItems, 0)
        XCTAssertGreaterThan(a.dropped.typedTextCharacters, 0)
        XCTAssertTrue(a.warnings.contains { $0.contains("stacked below") }, "\(a.warnings)")
        let state = NotabilityImporter.convert(note, attachments: a)
        assertWithinExtent(state)
        XCTAssertLessThan(state.pages.count, 2_000)
    }
}
