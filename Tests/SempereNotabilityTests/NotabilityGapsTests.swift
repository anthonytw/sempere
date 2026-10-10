import Age
import Foundation
import ImportTestSupport
import Sempere
import SemperePDF
import SempereRender
import XCTest
@testable import SempereImport
@testable import SempereNotability

/// The import gaps closed after the reference-backup survey: `.ntb`
/// attachments, PDF page text, handwriting language, highlighter behind text
/// and paper colour (docs/import-notability.md). Synthetic packages only.
final class NotabilityGapsTests: NotabilityTestCase {
    static let letter = (612.0, 792.0)
    static let k = 612 / 716.8
    static func hashName(_ data: Data, _ ext: String) -> String { BlobRef(content: data, type: "x").sha256 + "." + ext }

    /// A PDF record whose payload names `name` (field 2, a string) on page 0.
    static func pdfRecord(_ seq: UInt32, name: FBValue) -> [Int: FBValue] {
        SyntheticBundle.record(seq, type: 2, payload: [0: .structBytes([0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]), 2: name])
    }

    /// A media record: page (field 0), the file (field 2), a rectangle (field 3).
    static func mediaRecord(_ seq: UInt32, name: String, page: UInt8, rect: (Float, Float, Float, Float)?,
                            origin: (Float, Float)? = nil, size: (Float, Float)? = nil) -> [Int: FBValue] {
        var p: [Int: FBValue] = [0: .structBytes([0, 0, 0, 0, 1, 0, 0, 0, page, 0, 0, 0]), 2: .table([0: .string(name)])]
        if let r = rect { p[3] = .structBytes([r.0, r.1, r.2, r.3].flatMap(SyntheticBundle.f32)) }
        if let o = origin { p[4] = .structBytes(SyntheticBundle.f32(o.0) + SyntheticBundle.f32(o.1)) }
        if let s = size { p[5] = .structBytes(SyntheticBundle.f32(s.0) + SyntheticBundle.f32(s.1)) }
        return SyntheticBundle.record(seq, type: 22, payload: p)
    }

    // MARK: - .ntb attachments

    func testBundlePDFBecomesBackgroundsAndMovesTheInkToItsPages() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter, Self.letter], texts: ["first page words", "second page"])
        let name = Self.hashName(pdf, "pdf")
        var strokes = SyntheticBundle.strokesMatchingSyntheticNote()
        strokes[1].page = 1
        let bundle = SyntheticBundle.noteBundle(strokes: strokes, extraRecords: [Self.pdfRecord(50, name: .string(name))])
        let vault = try makeVault()
        let (r, state) = try importFile(SyntheticBundle.package(bundle, extra: [(name, pdf)]), ext: "ntb", into: vault)
        XCTAssertEqual(r.attachments.pdfs, 1)
        XCTAssertEqual(r.attachments.pdfPages, 2)
        XCTAssertEqual(r.attachments.bundlePDFRecords, 1)
        XCTAssertEqual(r.attachments.bundleFiles, 1)
        XCTAssertEqual(r.attachments.bundleFilesImported, 1)
        XCTAssertEqual(r.dropped.pdfs, 0)
        XCTAssertEqual(r.dropped.pdfPages, 0)
        XCTAssertEqual(r.attachments.pdfTextPages, 2)
        XCTAssertEqual(r.attachments.pdfTextExtracted, 2)
        let page = try XCTUnwrap(state.pages.first)
        let items = page.items.filter { $0.kind == .pdfPage }.sorted { $0.frame.y < $1.frame.y }
        XCTAssertEqual(items.count, 2)
        // Letter pages on a 716.8-wide note stack every ⌈716.8 × 792 / 612⌉ = 928 units.
        XCTAssertEqual(items[1].frame.y, 928 * Self.k, accuracy: 1e-3)
        XCTAssertEqual(items[0].pageText?.text, "first page words")
        XCTAssertEqual(items[0].pageText?.engine, PDFText.engine)
        XCTAssertEqual(state.meta.pageSize.breakHeight ?? 0, 928 * Self.k, accuracy: 1e-3)
        // The stroke on bundle page 1 is at the PDF's page top (928), not the document's (940.8).
        let plain = try NotabilityBundle.parse(package: NotePackage(data: SyntheticBundle.package(bundle)))
        let y1 = try XCTUnwrap(plain.curves[1].points.first?.y)
        let ys = page.strokes.map { $0.points[0].y }.sorted()
        XCTAssertEqual(ys.last ?? 0, (y1 - 940.8 + 928) * Self.k, accuracy: 0.05)
        // The blob is the PDF, byte for byte.
        XCTAssertEqual(try vault.readBlob(note: try XCTUnwrap(r.noteId), try XCTUnwrap(items[0].blob)), pdf)
    }

    func testBundleRecordNamingTheHashAsRawBytesOrBareHex() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter])
        let name = Self.hashName(pdf, "pdf")
        var raw: [UInt8] = []
        var hex = Array(name.prefix(64).utf8)[...]
        while !hex.isEmpty { raw.append(UInt8(String(decoding: hex.prefix(2), as: UTF8.self), radix: 16)!); hex = hex.dropFirst(2) }
        for value in [FBValue.bytes(raw), .string(String(name.prefix(64)).uppercased())] {
            let bundle = SyntheticBundle.noteBundle(strokes: [], extraRecords: [Self.pdfRecord(50, name: value)])
            let pkg = try NotePackage(data: SyntheticBundle.package(bundle, extra: [(name, pdf)]))
            let note = try NotabilityBundle.parse(package: pkg)
            let a = NotabilityAttachments.resolve(note, package: pkg, pdfText: nil)
            XCTAssertEqual(a.imported.pdfPages, 1, "\(value)")
            XCTAssertEqual(a.dropped.bundleRecordsWithoutFile, 0)
        }
    }

    /// Notability 16: the record's field 0 starts with the 64 raw bytes of the
    /// file's SHA-512 (padded to 68), and the file is `assets/<128 hex>.pdf`.
    func testBundleRecordNamingA64ByteHashInlineUnderAssets() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter])
        let raw = (0..<64).map { UInt8(($0 * 37 + 11) & 0xFF) }
        let name = "assets/" + raw.map { String(format: "%02x", $0) }.joined() + ".pdf"
        let record = SyntheticBundle.record(50, type: 2, payload: [0: .structBytes(raw + [0, 0, 0, 0])])
        let bundle = SyntheticBundle.noteBundle(strokes: [], extraRecords: [record])
        let pkg = try NotePackage(data: SyntheticBundle.package(bundle, extra: [(name, pdf)]))
        let note = try NotabilityBundle.parse(package: pkg)
        XCTAssertEqual(note.bundleFiles, [name])
        let a = NotabilityAttachments.resolve(note, package: pkg, pdfText: nil)
        XCTAssertEqual(a.imported.pdfPages, 1, "\(a.warnings)")
        XCTAssertEqual(a.dropped.bundleRecordsWithoutFile, 0)
        XCTAssertFalse(a.warnings.contains { $0.contains("no record names") })
    }

    func testBundleImagePlacedByItsRectangleOnItsPage() throws {
        let png = AttachmentFixtures.png(width: 40, height: 20)
        let name = Self.hashName(png, "png")
        let bundle = SyntheticBundle.noteBundle(strokes: [], extraRecords: [
            Self.mediaRecord(60, name: name, page: 1, rect: (100, 50, 200, 100)),
            Self.mediaRecord(61, name: name, page: 0, rect: nil, origin: (10, 20), size: (80, 40)),
        ])
        let pkg = try NotePackage(data: SyntheticBundle.package(bundle, extra: [(name, png)]))
        let note = try NotabilityBundle.parse(package: pkg)
        XCTAssertEqual(note.bundleAttachments.count, 2)
        XCTAssertEqual(note.bundleAttachments[0].layout, "0:12,2:4,3:16")
        let a = NotabilityAttachments.resolve(note, package: pkg)
        XCTAssertEqual(a.imported.images, 2, "\(a.warnings)")
        let frames = a.placements.map(\.frame)
        XCTAssertEqual(frames[0].y, 50 + 940.8, accuracy: 1e-3)   // one bundle page (Float32 940.8) down
        XCTAssertEqual(frames[0].x, 100)
        XCTAssertEqual(frames[0].w, 200)
        XCTAssertEqual(frames[1], Rect(x: 10, y: 20, w: 80, h: 40))
        XCTAssertEqual(a.blobs.count, 1)
        XCTAssertEqual(a.imported.bundleMediaRecords, 2)
        XCTAssertEqual(a.imported.bundleFilesImported, 1)
    }

    func testUnnamedPDFIsUsedAndMissingFilesAreCounted() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter])
        let name = Self.hashName(pdf, "pdf")
        let jpeg = AttachmentFixtures.jpeg(width: 4, height: 4)
        let bundle = SyntheticBundle.noteBundle(strokes: [], extraRecords: [
            Self.mediaRecord(60, name: String(repeating: "a", count: 64) + ".jpeg", page: 0, rect: (0, 0, 10, 10)),
        ])
        let pkg = try NotePackage(data: SyntheticBundle.package(bundle, extra: [(name, pdf), (Self.hashName(jpeg, "jpeg"), jpeg)]))
        let note = try NotabilityBundle.parse(package: pkg)
        XCTAssertEqual(note.bundleFiles.count, 2)
        let a = NotabilityAttachments.resolve(note, package: pkg, pdfText: nil)
        XCTAssertEqual(a.imported.pdfPages, 1)
        XCTAssertEqual(a.dropped.bundleRecordsWithoutFile, 1)
        XCTAssertEqual(a.dropped.media, 1)
        XCTAssertEqual(a.dropped.bundleFilesUnreferenced, 1)
        XCTAssertTrue(a.warnings.contains { $0.contains("no record names") })
    }

    func testBundleWithoutAttachmentsIsUnchanged() throws {
        let bundle = SyntheticBundle.noteBundle(strokes: SyntheticBundle.strokesMatchingSyntheticNote())
        let pkg = try NotePackage(data: SyntheticBundle.package(bundle))
        let note = try NotabilityBundle.parse(package: pkg)
        let a = NotabilityAttachments.resolve(note, package: pkg)
        XCTAssertTrue(a.placements.isEmpty)
        XCTAssertEqual(NotabilityImporter.convert(note, key: "t", attachments: a), NotabilityImporter.convert(note, key: "t"))
    }

    // MARK: - PDF text

    func indexZip(_ entries: [(String, Data)]) -> Data {
        TestZip.write(entries.map { .init(path: $0.0, data: $0.1) })
    }

    func testNotabilityPDFIndexGivesPageTextBySplittingAtFormFeeds() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter, Self.letter], texts: ["extracted one", "extracted two"])
        let index = indexZip([("PDFTextIndex.txt", Data("index page one\u{0C}index page two\u{0C}".utf8)),
                              ("PDFMetadataIndex.plist", BPlist.encode(.dict([("version", .int(1))])))])
        let pkg = AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 2), pdf: pdf,
                                             extra: [("NBPDFIndex/PDFIndex.zip", index)])
        let vault = try makeVault()
        let (r, state) = try importFile(pkg, ext: "note", into: vault)
        XCTAssertEqual(r.attachments.pdfTextFromIndex, 2)
        XCTAssertEqual(r.attachments.pdfTextExtracted, 0)
        let texts = state.pages[0].items.compactMap(\.pageText)
        XCTAssertEqual(texts.map(\.text), ["index page one", "index page two"])
        XCTAssertEqual(texts[0].engine, "notability-14.2.6")
        XCTAssertTrue(r.warnings.contains { $0.contains("split at form feeds") })
        // Search sees PDF text, on the right page item.
        let summary = try vault.summary(of: try XCTUnwrap(r.noteId))
        let hits = NoteSearch.search("two", in: [summary])
        XCTAssertEqual(hits.first?.fields, [.text])
    }

    func testIndexWithOffsetsInTheMetadataPlist() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter, Self.letter])
        let text = "alphabeta"
        let index = indexZip([("PDFTextIndex.txt", Data(text.utf8)),
                              ("PDFMetadataIndex.plist", BPlist.encode(.dict([("pageOffsets", .array([.int(0), .int(5)]))])))])
        let pkg = AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 2), pdf: pdf,
                                             extra: [("NBPDFIndex/PDFIndex.zip", index)])
        let (_, a) = try resolve(pkg)
        XCTAssertEqual(a.placements.compactMap(\.pageText?.text), ["alpha", "beta"])
    }

    func testUnmappableIndexFallsBackToTheExtractor() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter, Self.letter], texts: ["from the pdf"])
        let index = indexZip([("PDFTextIndex.txt", Data("one blob of text".utf8))])
        let pkg = AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 2), pdf: pdf,
                                             extra: [("NBPDFIndex/PDFIndex.zip", index)])
        let (_, a) = try resolve(pkg)
        XCTAssertEqual(a.imported.pdfTextFromIndex, 0)
        XCTAssertEqual(a.imported.pdfTextExtracted, 1)
        XCTAssertEqual(a.dropped.pdfTextPages, 1)   // page 2 has no text at all
        XCTAssertEqual(a.placements.compactMap(\.pageText?.text), ["from the pdf"])
        XCTAssertTrue(a.warnings.contains { $0.contains("does not map") })
        // No extractor: no text, nothing fails.
        let pkgObj = try NotePackage(data: pkg)
        let none = NotabilityAttachments.resolve(try NotabilityNote.parse(package: pkgObj), package: pkgObj, pdfText: nil)
        XCTAssertEqual(none.imported.pdfTextPages, 0)
        XCTAssertEqual(none.dropped.pdfTextPages, 2)
    }

    func testBundlePDFIndex() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter, Self.letter])
        let name = Self.hashName(pdf, "pdf")
        let index = SyntheticBundle.handwritingIndex([.init(index: 1, text: "second", boxes: []),
                                                      .init(index: 0, text: "first", boxes: [])])
        let bundle = SyntheticBundle.noteBundle(strokes: [], extraRecords: [Self.pdfRecord(50, name: .string(name))])
        let pkg = try NotePackage(data: SyntheticBundle.package(bundle, extra: [(name, pdf), ("ios/PDFIndex.fb", index)]))
        let note = try NotabilityBundle.parse(package: pkg)
        let a = NotabilityAttachments.resolve(note, package: pkg)
        XCTAssertEqual(a.placements.compactMap(\.pageText?.text), ["first", "second"])
        XCTAssertEqual(a.imported.pdfTextFromIndex, 2)
    }

    func testHostileIndexesNeverFailTheNote() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter])
        for index in [Data("not a zip".utf8), indexZip([("PDFTextIndex.txt", Data(repeating: 0xFF, count: 100))]),
                      indexZip([("PDFMetadataIndex.plist", Data("bplist00garbage".utf8))])] {
            let pkg = AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 1), pdf: pdf,
                                                 extra: [("NBPDFIndex/PDFIndex.zip", index)])
            let (_, a) = try resolve(pkg)
            XCTAssertEqual(a.imported.pdfPages, 1)
        }
    }

    func resolve(_ package: Data) throws -> (NotabilityNote, NotabilityAttachments) {
        let pkg = try NotePackage(data: package)
        let note = try NotabilityNote.parse(package: pkg)
        return (note, NotabilityAttachments.resolve(note, package: pkg))
    }

    // MARK: - Language, highlighter, paper colour

    func testLanguageHighlighterAndPaperColour() throws {
        let session = SyntheticNote.session(rootExtra: { a in
            [("NBNoteTakingSessionHandwritingLanguageKey", a.string("es_ES")),
             ("NBNoteTakingSessionIsHighlighterBehindTextKey", .bool(true))]
        }, attrsExtra: { a in
            let color = a.object("UIColor", [("UIRed", .real(1)), ("UIGreen", .real(0.97)), ("UIBlue", .real(0.88)),
                                             ("UIAlpha", .real(1))])
            return [("paperStyle", a.object("Notability.NBPaperStyle", [("paperColor", color)]))]
        })
        let pkg = AttachmentFixtures.package(session: session)
        let note = try NotabilityNote.parse(package: NotePackage(data: pkg))
        XCTAssertEqual(note.handwritingLanguage, "es_ES")
        XCTAssertEqual(note.highlighterBehindText, true)
        XCTAssertEqual(note.paper.color, Color(r: 255, g: 247, b: 224, a: 255))
        let vault = try makeVault()
        let (r, state) = try importFile(pkg, ext: "note", into: vault)
        XCTAssertEqual(state.meta.lang, "es-ES")
        XCTAssertTrue(state.meta.markersBehindText)
        XCTAssertEqual(state.meta.paper.background, Color(r: 255, g: 247, b: 224, a: 255))
        XCTAssertEqual(r.lang, "es-ES")
        XCTAssertTrue(r.markersBehindText)
        XCTAssertEqual(r.paperColor, "#FFF7E0FF")
    }

    func testPaperColourAsAHexStringKey() throws {
        let session = SyntheticNote.session(attrsExtra: { a in [("Notability.NBPaperStyle.paperColor", a.string("#1C1C1E"))] })
        let note = try NotabilityNote.parse(package: NotePackage(data: AttachmentFixtures.package(session: session)))
        XCTAssertEqual(note.paper.color, Color(r: 0x1C, g: 0x1C, b: 0x1E, a: 255))
    }

    func testNotesWithoutTheKeysImportAsBefore() throws {
        let note = try NotabilityNote.parse(package: NotePackage(data: AttachmentFixtures.package(session: SyntheticNote.session())))
        XCTAssertNil(note.handwritingLanguage)
        XCTAssertNil(note.highlighterBehindText)
        XCTAssertNil(note.paper.color)
        let state = NotabilityImporter.convert(note, key: "t")
        XCTAssertNil(state.meta.lang)
        XCTAssertFalse(state.meta.markersBehindText)
        XCTAssertEqual(state.meta.paper.background, Paper.blank.background)
        let ops = NotabilityImporter.ops(for: state)
        XCTAssertFalse(ops.contains { if case .setMeta(.lang) = $0 { return true }; if case .setMeta(.markersBehindText) = $0 { return true }; return false })
    }

    func testInvalidLanguageIsNotStored() throws {
        let session = SyntheticNote.session(rootExtra: { a in [("NBNoteTakingSessionHandwritingLanguageKey", a.string("en US; drop"))] })
        let note = try NotabilityNote.parse(package: NotePackage(data: AttachmentFixtures.package(session: session)))
        XCTAssertNil(NotabilityImporter.convert(note, key: "t").meta.lang)
    }

    func testOverwriteClearsWhatTheOldImportSet() throws {
        let vault = try makeVault()
        let with = AttachmentFixtures.package(session: SyntheticNote.session(rootExtra: { a in
            [("NBNoteTakingSessionHandwritingLanguageKey", a.string("en_US")),
             ("NBNoteTakingSessionIsHighlighterBehindTextKey", .bool(true))]
        }))
        let (_, first) = try importFile(with, ext: "note", into: vault)
        XCTAssertEqual(first.meta.lang, "en-US")
        let (_, second) = try importFile(AttachmentFixtures.package(session: SyntheticNote.session()), ext: "note",
                                         into: vault, options: .init(overwrite: true))
        XCTAssertNil(second.meta.lang)
        XCTAssertFalse(second.meta.markersBehindText)
    }
}

/// `Tests/SempereNotabilityTests/Fixtures/synthetic-gaps.note` and `synthetic-gaps.ntb`, the CLI
/// tests' notes for the import gaps (PDF index text, language, highlighter
/// flag, paper colour; `.ntb` PDF and image files). Generated here;
/// `SEMPERE_UPDATE_FIXTURES=1 swift test --filter CLIGapsFixtureTests` rewrites them.
final class CLIGapsFixtureTests: XCTestCase {
    static var dir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SempereNotabilityTests/Fixtures")
    }

    static func notePackage() -> Data {
        let session = SyntheticNote.session(typed: "", pdfPages: 2, rootExtra: { a in
            [("NBNoteTakingSessionHandwritingLanguageKey", a.string("es_ES")),
             ("NBNoteTakingSessionIsHighlighterBehindTextKey", .bool(true))]
        }, attrsExtra: { a in
            let color = a.object("UIColor", [("UIRed", .real(1)), ("UIGreen", .real(0.97)), ("UIBlue", .real(0.88)),
                                             ("UIAlpha", .real(1))])
            return [("paperStyle", a.object("Notability.NBPaperStyle", [("paperColor", color)]))]
        })
        let index = TestZip.write([.init(path: "PDFTextIndex.txt", data: Data("Teorema espectral\u{0C}Valores propios\u{0C}".utf8)),
                                     .init(path: "PDFMetadataIndex.plist", data: BPlist.encode(.dict([("version", .int(1))])))])
        return AttachmentFixtures.package(session: session,
                                          pdf: AttachmentFixtures.pdf(pages: [(612, 792), (612, 792)]),
                                          extra: [("NBPDFIndex/PDFIndex.zip", index)],
                                          thumbnails: [("thumb.png", 48, 62)])
    }

    static func bundlePackage() -> Data {
        let pdf = AttachmentFixtures.pdf(pages: [(612, 792), (612, 792)], texts: ["Kernel of a linear map", "Rank nullity"])
        let png = AttachmentFixtures.png(width: 40, height: 20)
        let pdfName = NotabilityGapsTests.hashName(pdf, "pdf"), pngName = NotabilityGapsTests.hashName(png, "png")
        var strokes = SyntheticBundle.strokesMatchingSyntheticNote()
        strokes[1].page = 1
        let bundle = SyntheticBundle.noteBundle(title: "Synthetic PDF bundle", strokes: strokes,
                                                extraRecords: [NotabilityGapsTests.pdfRecord(50, name: .string(pdfName)),
                                                               NotabilityGapsTests.mediaRecord(60, name: pngName, page: 0,
                                                                                               rect: (100, 400, 200, 100))],
                                                createdMs: 1_700_000_500_000)
        return SyntheticBundle.package(bundle, extra: [(pdfName, pdf), (pngName, png)])
    }

    func check(_ data: Data, _ name: String) throws {
        let url = Self.dir.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["SEMPERE_UPDATE_FIXTURES"] == "1" { try data.write(to: url) }
        XCTAssertEqual(try Data(contentsOf: url), data, "run with SEMPERE_UPDATE_FIXTURES=1 to regenerate \(name)")
    }

    func testFixturesAreCurrent() throws {
        try check(Self.notePackage(), "synthetic-gaps.note")
        try check(Self.bundlePackage(), "synthetic-gaps.ntb")
    }
}
