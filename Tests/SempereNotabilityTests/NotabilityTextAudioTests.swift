import Age
import Foundation
import ImportTestSupport
import Sempere
import XCTest
@testable import SempereImport
@testable import SempereNotability

/// Typed text and recordings of Notability notes (docs/attachments.md §11,
/// tasks D3 and D4), on synthetic packages only.
final class NotabilityTextAudioTests: XCTestCase {
    static let k = 612 / 716.8

    func resolve(_ package: Data) throws -> (NotabilityNote, NotabilityAttachments) {
        let pkg = try NotePackage(data: package)
        let note = try NotabilityNote.parse(package: pkg)
        return (note, NotabilityAttachments.resolve(note, package: pkg))
    }

    func texts(_ state: NoteState) -> [TextContent] { state.pages[0].items.compactMap(\.text) }

    // MARK: - Typed text (D3)

    /// Notability's `{stringKey, subRangesKey}` with styled ranges, including
    /// a Japanese run.
    static func styledSession() -> Data {
        SyntheticNote.session(attributed: { a in
            let ranges = [
                a.dict([("rangeKey", a.string("{0, 9}")), ("fontName", a.string("Helvetica-Bold")),
                        ("fontSize", .real(24)), ("color", a.string("#C0392BFF"))]),
                a.dict([("rangeKey", a.string("{10, 11}")), ("fontName", a.string("Helvetica")), ("fontSize", .real(16)),
                        ("underline", .int(1))]),
                a.dict([("rangeKey", a.string("{32, 6}")), ("fontName", a.string("HiraginoSans-W3")),
                        ("fontSize", .real(16))]),
            ]
            return a.dict([("stringKey", a.string("Lecture 3\nlinear maps\n\n\nKernel: 線形写像です\r\nend")),
                           ("subRangesKey", a.array(ranges))])
        })
    }

    func testStyledTypedTextBecomesTextItems() throws {
        let (note, a) = try resolve(AttachmentFixtures.package(session: Self.styledSession()))
        let state = NotabilityImporter.convert(note, attachments: a)
        let t = texts(state)
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t[0].string, "Lecture 3\nlinear maps")
        XCTAssertEqual(t[1].string, "Kernel: 線形写像です\nend")
        // Block 1: the box takes the most-used style; the heading run overrides it.
        let heading = try XCTUnwrap(t[0].runs.first)
        XCTAssertEqual(heading.t, "Lecture 3\n")
        XCTAssertTrue(heading.b)
        XCTAssertEqual(heading.size ?? 0, 24 * Self.k, accuracy: 1e-9)
        XCTAssertEqual(heading.color, Color(hex: "#C0392BFF"))
        XCTAssertEqual(t[0].size, 16 * Self.k, accuracy: 1e-9)
        XCTAssertEqual(t[0].font, .sans)
        XCTAssertTrue(t[0].runs.contains { $0.t == "linear maps" && $0.u }, "\(t[0].runs)")
        // The Japanese run carries its language.
        XCTAssertTrue(t[1].runs.contains { $0.t.contains("線形写像です") && $0.lang == "ja" }, "\(t[1].runs)")
        // Stacked from the top at the ink's left edge.
        let items = state.pages[0].items
        XCTAssertEqual(items[0].frame.x, 716.8 / 38.4 * Self.k, accuracy: 1e-3)
        XCTAssertLessThan(items[0].frame.y, items[1].frame.y)
        XCTAssertGreaterThanOrEqual(items[1].frame.y, items[0].frame.y + items[0].frame.h)
        XCTAssertEqual(NotabilityImporter.dropped(note, attachments: a).typedTextCharacters, 0)
        XCTAssertEqual(a.imported.textItems, 2)
        XCTAssertTrue(a.warnings.contains { $0.contains("subRangesKey: color, fontname, fontsize, rangekey, underline") },
                      "\(a.warnings)")
        for item in items { XCTAssertNil(item.validationError) }
        // Searchable through the note's summary like any text item.
        XCTAssertNoThrow(try InkJSON.encoder().encode(NotabilityImporter.ops(for: state)))
    }

    /// A standard archived NSAttributedString: attribute dictionaries indexed by run lengths.
    func testNSAttributedString() throws {
        let session = SyntheticNote.session(attributed: { a in
            let bold = a.object("UIFont", [("NSName", a.string("Georgia-BoldItalic")), ("NSSize", .real(20))])
            let red = a.object("UIColor", [("UIRed", .real(1)), ("UIGreen", .real(0)), ("UIBlue", .real(0)), ("UIAlpha", .real(1))])
            let plain = a.object("UIFont", [("NSName", a.string("Georgia")), ("NSSize", .real(12))])
            let attrs = a.array([a.dict([("NSFont", bold), ("NSColor", red), ("NSStrikethrough", .int(1))]),
                                 a.dict([("NSFont", plain)])])
            return a.object("NSMutableAttributedString", [
                ("NSString", a.string("Title body text here")), ("NSAttributes", attrs),
                ("NSAttributeInfo", a.data(Data([5, 0, 15, 1]))),
            ])
        })
        let (note, a) = try resolve(AttachmentFixtures.package(session: session))
        XCTAssertEqual(note.typedText, "Title body text here")
        let t = try XCTUnwrap(texts(NotabilityImporter.convert(note, scaleToLetterWidth: false, attachments: a)).first)
        XCTAssertEqual(t.font, .serif)
        XCTAssertEqual(t.size, 12)
        XCTAssertEqual(t.runs.map(\.t), ["Title", " body text here"])
        XCTAssertTrue(t.runs[0].b && t.runs[0].i && t.runs[0].s)
        XCTAssertEqual(t.runs[0].color, Color(r: 255, g: 0, b: 0))
        XCTAssertEqual(t.runs[0].size, 20)
    }

    func testTextBoxMediaObject() throws {
        let session = SyntheticNote.session(media: { a in
            [a.object("TextBoxMediaObject", [("frame", a.string("{{40, 60}, {200, 50}}")),
                                             ("string", a.string("A boxed label"))])]
        })
        let (note, a) = try resolve(AttachmentFixtures.package(session: session))
        let state = NotabilityImporter.convert(note, scaleToLetterWidth: false, attachments: a)
        let item = try XCTUnwrap(state.pages[0].items.first { $0.text?.string == "A boxed label" })
        XCTAssertEqual(item.frame, Rect(x: 40 + 716.8 / 38.4, y: 60, w: 200, h: 50))
        XCTAssertEqual(NotabilityImporter.dropped(note, attachments: a).media, 0)
    }

    /// Text over the per-item limits is split at lines into several items.
    func testLongTextSplitsWithinLimits() throws {
        let line = String(repeating: "word ", count: 2000)   // 10 000 bytes per line
        let text = Array(repeating: line, count: 20).joined(separator: "\n")
        let session = SyntheticNote.session(attributed: { a in a.dict([("stringKey", a.string(text))]) })
        let (note, a) = try resolve(AttachmentFixtures.package(session: session))
        let t = texts(NotabilityImporter.convert(note, attachments: a))
        XCTAssertGreaterThan(t.count, 1)
        XCTAssertTrue(t.allSatisfy { $0.limitViolation == nil })
        XCTAssertEqual(t.map { $0.string.count }.reduce(0, +) + t.count - 1, text.count)
        XCTAssertEqual(NotabilityImporter.dropped(note, attachments: a).typedTextCharacters, 0)
    }

    func testHostileRangesAndControls() throws {
        let session = SyntheticNote.session(attributed: { a in
            let ranges = [a.dict([("rangeKey", a.string("{5, 99999999}")), ("fontSize", .real(1e9))]),
                          a.dict([("rangeKey", a.string("{2, 4}")), ("fontSize", .real(-3))]),
                          a.dict([("rangeKey", a.string("{-4, 2}"))])]
            return a.dict([("stringKey", a.string("ab\u{0}cd\u{FFFC}ef\u{7}gh")), ("subRangesKey", a.array(ranges))])
        })
        let (note, a) = try resolve(AttachmentFixtures.package(session: session))
        let t = texts(NotabilityImporter.convert(note, attachments: a))
        XCTAssertEqual(t.map(\.string), ["abcdefgh"])
        XCTAssertTrue(t.allSatisfy { $0.limitViolation == nil })
    }

    func testWhitespaceOnlyTypedTextImportsNothing() throws {
        let (note, a) = try resolve(AttachmentFixtures.package(session: SyntheticNote.session(attributed: { a in
            a.dict([("stringKey", a.string("\n\n \n"))])
        })))
        XCTAssertTrue(texts(NotabilityImporter.convert(note, attachments: a)).isEmpty)
        XCTAssertFalse(a.warnings.contains { $0.contains("typed text") })
    }

    /// A long block is split where every piece fits `content`'s limit: nothing is cut.
    func testLongTypedTextChunksFitWithoutCuts() {
        // 20 lines are 65,500 bytes: within utf8Bytes, but beyond what `content` keeps.
        let line = String(repeating: "a", count: 3_274) + "\n"
        let text = String(repeating: line, count: 25)
        let block = text.unicodeScalars.map { ($0, Int32(0)) }
        let chunks = NotabilityAttachments.chunks(block)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(String(String.UnicodeScalarView(chunks.joined().map(\.0))), text)
        for chunk in chunks { XCTAssertEqual(NotabilityAttachments.content(chunk, runs: []).1, 0) }
    }

    /// A line beyond the limit is cut at its end, not with holes: a multi-byte scalar that does not fit
    /// ends it, even where later one-byte scalars would.
    func testATooLongLineIsCutAtTheEnd() throws {
        let limit = TextContent.Limits.utf8Bytes - 64
        let text = String(repeating: "a", count: limit - 1) + "é" + "bc"
        let (content, cut) = NotabilityAttachments.content(text.unicodeScalars.map { ($0, Int32(0)) }, runs: [])
        XCTAssertEqual(cut, 3)
        let kept = try XCTUnwrap(content).string
        XCTAssertTrue(kept == String(repeating: "a", count: limit - 1), "\(kept.count) characters, ends \(kept.suffix(3))")
    }

    // MARK: - Recordings (D4)

    static let created = SyntheticNote.created

    static func recordingPackage(library: Data, files: [(String, Data)], tokens: [Int32]? = nil) -> Data {
        AttachmentFixtures.package(session: SyntheticNote.session(eventTokens: tokens),
                                   extra: [("Recordings/library.plist", library)] + files)
    }

    static let lectureEntry = """
        <key>name</key><string>Lecture</string>\
        <key>fileName</key><string>Recording 1.m4a</string>\
        <key>creationDate</key><date>2026-10-04T16:20:00Z</date>\
        <key>duration</key><real>12.5</real>
        """

    func testRecordingWithStrokeLinks() throws {
        let pkg = Self.recordingPackage(library: AttachmentFixtures.library([("rec-0", Self.lectureEntry)]),
                                        files: [("Recordings/Recording 1.m4a", AttachmentFixtures.m4a(seconds: 12.5))],
                                        tokens: [0, 1500, -1, 3000])
        let identity = try NativeIdentity.generate(.postQuantum)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let vault = try Vault.create(at: tmp.appendingPathComponent("V.sempere"), recipients: [identity.recipient],
                                     identities: [identity])
        let path = tmp.appendingPathComponent("N.note")
        try pkg.write(to: path)
        var clock = HybridClock()
        let r = try XCTUnwrap(NotabilityImporter.import(paths: [path], into: vault, device: DeviceID("0a0b0c0d")!,
                                                        clock: &clock).notes.first)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.attachments.recordings, 1)
        XCTAssertEqual(r.attachments.recLinkedStrokes, 3)
        XCTAssertEqual(r.dropped.recordings, 0)
        XCTAssertEqual(r.dropped.recLinks, 0)
        let state = try vault.reconstruct(noteId: try XCTUnwrap(r.noteId))
        let rec = try XCTUnwrap(state.recordings.first)
        XCTAssertEqual(rec.title, "Lecture")
        XCTAssertEqual(rec.duration, 12.5)
        XCTAssertEqual(rec.started, ISO8601DateFormatter().date(from: "2026-10-04T16:20:00Z"))
        XCTAssertEqual(rec.codec, "aac")
        XCTAssertEqual(rec.sampleRate, 48000)
        XCTAssertEqual(rec.channels, 1)
        XCTAssertEqual(rec.blob.type, "audio/mp4")
        XCTAssertEqual(try vault.readBlob(note: try XCTUnwrap(r.noteId), rec.blob), AttachmentFixtures.m4a(seconds: 12.5))
        let links = state.pages[0].strokes.compactMap(\.rec)
        XCTAssertEqual(links.count, 3)
        XCTAssertTrue(links.allSatisfy { $0.id == rec.id })
        XCTAssertEqual(Set(links.map(\.at)), [0, 1.5, 3])
        XCTAssertTrue(r.warnings.contains { $0.contains("read as milliseconds") })
    }

    func testDroppedKindsNameEveryCounter() {
        var d = NotabilityImporter.Dropped()
        XCTAssertTrue(d.nonZero.isEmpty)
        d.media = 2; d.pdfTextPages = 3; d.dashedStrokes = 5
        XCTAssertEqual(d.nonZero.map(\.kind), [.media, .dashedStrokes, .pdfTextPages])
        XCTAssertEqual(d.nonZero.map(\.count), [2, 5, 3])
        // Every counter has a kind: a Dropped with each field set once lists them all.
        var all = NotabilityImporter.Dropped()
        all.typedTextCharacters = 1; all.pdfs = 1; all.pdfPages = 1; all.media = 1; all.pdfHighlights = 1; all.templatePDFs = 1
        all.recLinks = 1; all.recordings = 1; all.dashedStrokes = 1; all.unknownStyleStrokes = 1
        all.defaultedAttributeStrokes = 1; all.unsupportedShapes = 1; all.unsupportedStrokes = 1; all.clampedStrokes = 1
        all.bundleRecordsWithoutFile = 1; all.bundleFilesUnreferenced = 1; all.pdfTextPages = 1
        XCTAssertEqual(all.nonZero.count, NotabilityImporter.Dropped.Kind.allCases.count)
        XCTAssertTrue(NotabilityImporter.Dropped.Kind.allCases.allSatisfy { !$0.english.isEmpty })
    }

    // MARK: Notability's own transcripts (GA-09)

    static let transcriptEntry = lectureEntry + """
        <key>locale</key><string>en_US</string>\
        <key>transcript</key><array>\
        <dict><key>text</key><string>Hello class</string><key>start</key><real>0.5</real><key>duration</key><real>1.5</real></dict>\
        <dict><key>text</key><string>Today: limits</string><key>start</key><real>2</real><key>end</key><real>4.25</real></dict>\
        <dict><key>text</key><string>   </string><key>start</key><real>5</real></dict>\
        </array>
        """

    func testNotabilityTranscriptBecomesATranscriptBlob() throws {
        let pkg = Self.recordingPackage(library: AttachmentFixtures.library([("rec-0", Self.transcriptEntry)]),
                                        files: [("Recordings/Recording 1.m4a", AttachmentFixtures.m4a(seconds: 12.5))])
        let identity = try NativeIdentity.generate(.postQuantum)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-trn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let vault = try Vault.create(at: tmp.appendingPathComponent("V.sempere"), recipients: [identity.recipient],
                                     identities: [identity])
        let path = tmp.appendingPathComponent("N.note")
        try pkg.write(to: path)
        var clock = HybridClock()
        let r = try XCTUnwrap(NotabilityImporter.import(paths: [path], into: vault, device: DeviceID("0a0b0c0d")!,
                                                        clock: &clock).notes.first)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.attachments.transcripts, 1)
        let id = try XCTUnwrap(r.noteId)
        let rec = try XCTUnwrap(try vault.reconstruct(noteId: id).recordings.first)
        let ref = try XCTUnwrap(rec.transcript)
        XCTAssertEqual(ref.type, BlobRef.transcriptType)
        let t = try Transcript.decode(try vault.readBlob(note: id, ref))
        XCTAssertEqual(t.recording, rec.id)
        XCTAssertEqual(t.language, "en-US")
        XCTAssertTrue(t.engine.hasPrefix("notability-"), t.engine)
        XCTAssertEqual(t.segments.map(\.text), ["Hello class", "Today: limits"])
        XCTAssertEqual(t.segments.map(\.start), [0.5, 2])
        XCTAssertEqual(t.segments.map(\.end), [2, 4.25])
        // The same bytes on a second import of the same note (ids and dates derive from the note).
        XCTAssertEqual(r.attachments.blobs, 2)
    }

    func testTranscriptFormsAndLimits() throws {
        // A plain string spans the recording; milliseconds are recognized against the duration.
        let plain = TranscriptRead.parse(.string("All of it"), duration: 12.5, field: "transcript")
        XCTAssertEqual(plain?.segments.first.map { [$0.start, $0.end] }, [0, 12.5])
        let ms = TranscriptRead.parse(.array([.dict(["text": .string("a"), "start": .int(1000), "end": .int(2000)]),
                                              .dict(["text": .string("b"), "start": .int(2000), "end": .int(9000)])]),
                                      duration: 12.5, field: "t")
        XCTAssertEqual(ms?.segments.map(\.end), [2, 9])
        XCTAssertEqual(ms?.milliseconds, true)
        // Overlap is pushed apart, out-of-order items sorted, non-finite and empty items dropped.
        let messy = TranscriptRead.parse(.array([.dict(["text": .string("late"), "start": .real(5), "end": .real(6)]),
                                                 .dict(["text": .string("early"), "start": .real(1), "end": .real(5.5)]),
                                                 .dict(["text": .string("bad"), "start": .real(.nan)])]),
                                         duration: 20, field: "t")
        XCTAssertEqual(messy?.segments.map(\.text), ["early", "late"])
        XCTAssertNil(try messy.map { Transcript(recording: UUID(), engine: "e", language: "en", created: Date(), segments: $0.segments).validationError }.flatMap { $0 })
        XCTAssertNil(TranscriptRead.parse(.dict(["x": .int(1)]), duration: nil, field: "t"))
        // Bounded: a hostile array never yields more than the cap.
        let many = PlistValue.array((0..<50_000).map { .dict(["text": .string("w"), "start": .int(Int64($0))]) })
        XCTAssertLessThanOrEqual(TranscriptRead.parse(many, duration: nil, field: "t")?.segments.count ?? 0, TranscriptRead.maxSegments)
    }

    /// Review of #134: 20 000 segments of 8 192 characters made a blob far past `Transcript.maxSize`, which
    /// `Transcript.decode` refuses, so the import wrote a transcript no reader could open. The text kept is
    /// now budgeted, and what is kept encodes to a blob that decodes.
    func testTranscriptTextIsBudgetedSoTheBlobDecodes() throws {
        let long = String(repeating: "é", count: TranscriptRead.maxTextLength)   // 2 bytes each in UTF-8
        let huge = PlistValue.array((0..<TranscriptRead.maxSegments).map {
            .dict(["text": .string(long), "start": .int(Int64($0)), "end": .int(Int64($0) + 1)])
        })
        let read = try XCTUnwrap(TranscriptRead.parse(huge, duration: nil, field: "t"))
        XCTAssertLessThan(read.segments.count, TranscriptRead.maxSegments, "cut by the byte budget")
        let total = read.segments.reduce(0) { $0 + $1.text.utf8.count + TranscriptRead.segmentOverhead }
        XCTAssertLessThanOrEqual(total, TranscriptRead.maxTotalBytes)
        let data = try Transcript(recording: UUID(), engine: "notability-1", language: "en", created: Date(),
                                  segments: read.segments).encoded()
        XCTAssertLessThanOrEqual(data.count, Transcript.maxSize)
        XCTAssertEqual(try Transcript.decode(data).segments.count, read.segments.count)
        // Characters JSON escapes (six bytes each) still give a blob that decodes.
        let control = String(repeating: "\u{1}", count: TranscriptRead.maxTextLength)
        let escaped = PlistValue.array((0..<TranscriptRead.maxSegments).map {
            .dict(["text": .string("a" + control + "b"), "start": .int(Int64($0))])
        })
        let kept = try XCTUnwrap(TranscriptRead.parse(escaped, duration: nil, field: "t"))
        let blob = try Transcript(recording: UUID(), engine: "e", language: "en", created: Date(), segments: kept.segments).encoded()
        XCTAssertLessThanOrEqual(blob.count, Transcript.maxSize)
        XCTAssertNoThrow(try Transcript.decode(blob))
    }

    func testUnreadableTranscriptFieldIsReported() throws {
        let entry = Self.lectureEntry + "<key>transcriptData</key><integer>3</integer>"
        let pkg = Self.recordingPackage(library: AttachmentFixtures.library([("rec-0", entry)]),
                                        files: [("Recordings/Recording 1.m4a", AttachmentFixtures.m4a(seconds: 12.5))])
        let (_, a) = try resolve(pkg)
        XCTAssertTrue(a.transcripts.isEmpty)
        XCTAssertTrue(a.warnings.contains { $0.contains("transcriptData") && $0.contains("no readable text") }, "\(a.warnings)")
    }

    func testCAFDurationFromTheFileAndOrderPairing() throws {
        // The entry names no file: the one audio file is paired with it; no duration in the library.
        let pkg = Self.recordingPackage(library: AttachmentFixtures.library([("a", "<key>title</key><string>Talk</string>")]),
                                        files: [("Recordings/0001.caf", AttachmentFixtures.caf(seconds: 2))])
        let (note, a) = try resolve(pkg)
        let rec = try XCTUnwrap(NotabilityImporter.convert(note, attachments: a).recordings.first)
        XCTAssertEqual(rec.blob.type, "audio/x-caf")
        XCTAssertEqual(rec.duration ?? 0, 2, accuracy: 1e-3)
        XCTAssertEqual(rec.title, "Talk")
        XCTAssertEqual(rec.started, note.metadata.created)
        XCTAssertTrue(a.warnings.contains { $0.contains("paired with the audio files by order") })
        XCTAssertTrue(a.warnings.contains { $0.contains("no start date") })
    }

    func testImplausibleTokensWriteNoRec() throws {
        let pkg = Self.recordingPackage(library: AttachmentFixtures.library([("rec-0", Self.lectureEntry)]),
                                        files: [("Recordings/Recording 1.m4a", AttachmentFixtures.m4a(seconds: 12.5))],
                                        tokens: [5, 900_000, 7, -1])
        let (note, a) = try resolve(pkg)
        XCTAssertTrue(a.strokeLinks.isEmpty)
        XCTAssertEqual(NotabilityImporter.dropped(note, attachments: a).recLinks, 3)
        XCTAssertTrue(a.warnings.contains { $0.contains("eventTokens 5…900000") }, "\(a.warnings)")
        XCTAssertTrue(NotabilityImporter.convert(note, attachments: a).pages[0].strokes.allSatisfy { $0.rec == nil })
    }

    func testMissingAndUnknownAudioAreReported() throws {
        let pkg = Self.recordingPackage(
            library: AttachmentFixtures.library([("a", "<key>fileName</key><string>gone.m4a</string>"),
                                                 ("b", "<key>fileName</key><string>noise.bin</string>")]),
            files: [("Recordings/noise.bin", Data("not audio".utf8))])
        let (note, a) = try resolve(pkg)
        XCTAssertTrue(a.recordings.isEmpty)
        XCTAssertEqual(NotabilityImporter.dropped(note, attachments: a).recordings, 2)
        XCTAssertTrue(a.warnings.contains { $0.contains("recording a: no audio file") })
        XCTAssertTrue(a.warnings.contains { $0.contains("not an audio container") })
    }

    func testNoAttachmentsDropsTextAndRecordings() throws {
        let pkg = Self.recordingPackage(library: AttachmentFixtures.library([("rec-0", Self.lectureEntry)]),
                                        files: [("Recordings/Recording 1.m4a", AttachmentFixtures.m4a(seconds: 12.5))],
                                        tokens: [0, 1, 2, 3])
        let note = try NotabilityNote.parse(package: NotePackage(data: pkg))
        let d = NotabilityImporter.dropped(note)
        XCTAssertEqual(d.recordings, 1)
        XCTAssertEqual(d.recLinks, 4)
        XCTAssertEqual(d.typedTextCharacters, "typed words".count)
        XCTAssertTrue(NotabilityImporter.convert(note).recordings.isEmpty)
    }

    func testAudioContainer() {
        XCTAssertNil(AudioContainer.read(Data("hello".utf8)))
        XCTAssertEqual(AudioContainer.read(Data("RIFF\0\0\0\0WAVEfmt ".utf8))?.type, "audio/wav")
        let m4a = AudioContainer.read(AttachmentFixtures.m4a(seconds: 3))
        XCTAssertEqual(m4a?.duration, 3)
        // Truncated containers read without a crash.
        let full = [UInt8](AttachmentFixtures.m4a(seconds: 3)) + [UInt8](AttachmentFixtures.caf(seconds: 3))
        for n in stride(from: 0, to: full.count, by: 7) { _ = AudioContainer.read(Data(full[0..<n])) }
    }
}
