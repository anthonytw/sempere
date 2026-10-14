import Age
import Foundation
import ImportTestSupport
import SempereRender
import Sempere
import XCTest

@testable import SempereImport
@testable import SempereNotability

/// Regression tests for corrupt or hostile Notability packages (see
/// `ImportFuzzTests`): each fails with `ImportError` or imports cleanly.
final class UntrustedImportTests: XCTestCase {
    func curve(width: Float, fw: [Float] = [1, 1]) -> SyntheticNote.CurveSpec {
        .init(points: [(10, 10), (20, 10), (30, 10), (40, 10)], fw: fw, width: width, rgba: [0, 0, 0, 255], style: 3)
    }

    /// Non-finite or absurd widths parsed fine and then failed much later as
    /// an `EncodingError` (JSON cannot hold NaN or infinity) or produced
    /// infinite geometry.
    func testNonFiniteOrHugeWidthsAreRejected() throws {
        for w: Float in [.nan, .infinity, -.infinity, 3e38] {
            XCTAssertThrowsError(try NotabilityNote.parse(data: SyntheticNote.package(curves: [curve(width: w)])), "\(w)") { e in
                XCTAssertTrue(e is ImportError, "\(e)")
            }
        }
        // Fractional widths: non-finite ones fall back to 1; huge products are rejected.
        let note = try NotabilityNote.parse(data: SyntheticNote.package(curves: [curve(width: 2, fw: [.nan, .infinity])]))
        let state = NotabilityImporter.convert(note)
        XCTAssertNoThrow(try InkJSON.encoder().encode(NotabilityImporter.ops(for: state)))
        XCTAssertThrowsError(try NotabilityNote.parse(data: SyntheticNote.package(curves: [curve(width: 2, fw: [3e38, 1])])))
    }

    /// A paper pitch that overflows to infinity, a NaN recognition origin and
    /// a page key near `Int.max` used to reach the vault as NaN / infinity
    /// (an `EncodingError` at write time) or as words 10¹⁸ pages down.
    func testPaperPitchAndRecognitionOriginAreSanitised() throws {
        let (kind, spacing) = NotabilityNote.paperStyle(lineStyle2: "Dots:1e308", lineStyle: nil, width: 716.8, size: nil)
        XCTAssertEqual(kind, .dot)
        XCTAssertNil(spacing)
        XCTAssertNil(NotabilityNote.paperStyle(lineStyle2: "Lines:a:b:1e306", lineStyle: nil, width: 716.8, size: nil).1)

        let page = BValue.dict([("text", .string("hi")), ("pageContentOrigin", .array([.real(.nan), .real(.infinity)])),
                                ("characterRects", .data(Data([0, 0x3C, 0, 0x3C, 0, 0x3C, 0, 0x3C])))])
        let index = BPlist.encode(.dict([("pages", .dict([("1", page), ("9223372036854775807", page)]))]))
        let rec = try NotabilityNote.parseRecognition(index)
        XCTAssertEqual(Array(rec.keys), [1])
        XCTAssertEqual(rec[1]?.origin, NotabilityNote.Point(x: 0, y: 0))
        var note = try NotabilityNote.parse(data: SyntheticNote.package())
        note.recognition = rec
        XCTAssertNoThrow(try InkJSON.encoder().encode(NotabilityImporter.ops(for: NotabilityImporter.convert(note))))
    }

    /// A package directory from a shared folder: a symlink to a file outside
    /// it is not followed, and a file over the size limit is refused before
    /// it is read into memory.
    func testPackageDirectoryIgnoresSymlinksAndCapsReads() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("untrusted-pkg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pkg = tmp.appendingPathComponent("Shared.note")
        try SyntheticNote.writeDirectory(pkg)
        let secret = tmp.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: secret)
        let link = pkg.appendingPathComponent("Synthetic note/HandwritingIndex/leak.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let package = try NotePackage(directory: pkg)
        XCTAssertFalse(package.paths.contains { $0.hasSuffix("leak.plist") }, "\(package.paths)")
        XCTAssertNoThrow(try NotabilityNote.parse(package: package))

        let big = tmp.appendingPathComponent("big.bin")
        try Data(count: 4097).write(to: big)
        XCTAssertThrowsError(try NotePackage.readFile(big, maxSize: 4096)) { e in XCTAssertTrue(e is ImportError) }
        XCTAssertEqual(try NotePackage.readFile(big, maxSize: 4097).count, 4097)
    }

    /// A NaN or far-future creation date became the delta's `wall`, which was
    /// written as "" or a 7-digit year that no reader could decode. Such dates
    /// are dropped (the import falls back to another date, or now).
    func testUnwritableDatesAreDropped() throws {
        for t in [Double.nan, .infinity, 1e300, -1e18] {
            var b = KeyedArchiveBuilder()
            let d = b.dict([("noteName", b.string("n")), ("noteCreationDateKey", .date(Date(timeIntervalSinceReferenceDate: t))),
                            ("uuidKey", b.string(SyntheticNote.uuid))])
            var files = SyntheticNote.files()
            files = files.map { $0.0.hasSuffix("metadata.plist") ? ($0.0, b.archive(top: [("root", d)])) : $0 }
            let zip = TestZip.write(files.map { .init(path: $0.0, data: $0.1) })
            let note = try NotabilityNote.parse(data: zip)
            // Session.plist's creation date is the fallback.
            XCTAssertEqual(note.metadata.created, SyntheticNote.created, "\(t)")
        }
    }

    // MARK: Full-backup readers (merged from main, #31)

    /// An `.ntb` bundle whose creation time is `Int64.max` milliseconds:
    /// `NotabilityImporter.plan` turned it back into milliseconds with
    /// `Int64(Double)`, which traps at 2^63. Such dates are now dropped, as
    /// for a `.note`, and the bundle imports.
    func testBundleWithAbsurdCreationTimeImportsWithoutTrapping() throws {
        for ms in [Int64.max, Int64.min, 253_402_300_800_000] {
            let bundle = SyntheticBundle.noteBundle(strokes: [], createdMs: ms)
            let note = try NotabilityBundle.parse(bundle: bundle)
            XCTAssertNil(note.metadata.created, "\(ms)")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("untrusted-ntb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("x.ntb")
        try SyntheticBundle.package(SyntheticBundle.noteBundle(strokes: [], createdMs: .max)).write(to: file)
        let identity = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: tmp.appendingPathComponent("V.sempere"), recipients: [identity.recipient],
                                     identities: [identity])
        var clock = HybridClock()
        let report = try NotabilityImporter.import(paths: [file], into: vault, device: DeviceID("0a0b0c0d")!, clock: &clock)
        XCTAssertEqual(report.notes.map(\.status), [.ok])
    }

    /// A `.note` rejects widths beyond ±10⁶; an `.ntb` stroke with a width of
    /// 3·10³⁸ was imported as it was (one fractional width away from an
    /// infinite point width). It is now an unsupported stroke.
    func testBundleWidthsAreBoundedLikeNotes() throws {
        var s = SyntheticBundle.strokesMatchingSyntheticNote()
        s[0].width = 3e38
        let note = try NotabilityBundle.parse(bundle: SyntheticBundle.noteBundle(strokes: s))
        XCTAssertEqual(note.unsupportedStrokes, 1)
        XCTAssertEqual(note.curves.count, 1)
        XCTAssertNoThrow(try InkJSON.encoder().encode(NotabilityImporter.ops(for: NotabilityImporter.convert(note))))
    }

    /// A bundle of 2 000 records all referencing one document record whose
    /// title is a 256 KiB string (FlatBuffers references can be shared):
    /// every record decoded the title again, 512 MB of work from 270 KB.
    /// Titles now count against the decode budget like geometry does.
    func testSharedBundleTitleIsCharged() throws {
        let bundle = Self.sharedTitleBundle(records: 2000, titleBytes: 256 << 10)
        XCTAssertThrowsError(try NotabilityBundle.parse(bundle: bundle)) { e in XCTAssertTrue(e is ImportError, "\(e)") }
        // The same layout with a few records is an ordinary bundle.
        XCTAssertEqual(try NotabilityBundle.parse(bundle: Self.sharedTitleBundle(records: 3, titleBytes: 100)).metadata.name,
                       String(repeating: "t", count: 100))
    }

    /// A hand-built FlatBuffers bundle: a record vector of `records`
    /// references to one document record with a `titleBytes`-long title.
    static func sharedTitleBundle(records: Int, titleBytes: Int) -> Data {
        var b = [UInt8](repeating: 0, count: 4)
        func u16(_ v: Int) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) { b += (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } }
        func patch(_ at: Int, _ v: Int) { for k in 0..<4 { b[at + k] = UInt8(v >> (8 * k) & 0xFF) } }
        // vtables: root (field 6 at 4), record (type at 4, payload at 8), one-field tables (field 0 at 4).
        let vtRoot = b.count; u16(18); u16(8); for f in 0..<7 { u16(f == 6 ? 4 : 0) }
        let vtRecord = b.count; u16(16); u16(12); for f in 0..<6 { u16(f == 4 ? 4 : f == 5 ? 8 : 0) }
        let vtOne = b.count; u16(6); u16(8); u16(4)
        let root = b.count; u32(root - vtRoot); let rootRef = b.count; u32(0)
        let vector = b.count; u32(records)
        let refs = b.count; for _ in 0..<records { u32(0) }
        let record = b.count; u32(record - vtRecord); b += [1, 0, 0, 0]; let payloadRef = b.count; u32(0)
        let doc = b.count; u32(doc - vtOne); let titleTableRef = b.count; u32(0)
        let titleTable = b.count; u32(titleTable - vtOne); let stringRef = b.count; u32(0)
        let string = b.count; u32(titleBytes); b += [UInt8](repeating: 0x74, count: titleBytes)
        patch(0, root); patch(rootRef, vector - rootRef)
        for i in 0..<records { patch(refs + 4 * i, record - (refs + 4 * i)) }
        patch(payloadRef, doc - payloadRef); patch(titleTableRef, titleTable - titleTableRef)
        patch(stringRef, string - stringRef)
        return Data(b)
    }

    /// A `shapes` plist whose array references one shape 5 000 times, that
    /// shape's `strokePath` holding 1 000 cubic segments: 55 KB that
    /// decoded into 15 M points (240 MB). Decoding is now capped by the
    /// plist's size.
    func testSharedShapeReferencesDoNotAmplify() throws {
        let data = Self.sharedShapesPlist(references: 5000, segments: 1000)
        XCTAssertLessThan(data.count, 60_000)
        XCTAssertThrowsError(try NotabilityShapes.curves(data)) { e in
            guard case ImportError.package? = e as? ImportError else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try NotabilityNote.parse(data: SyntheticNote.package(shapes: data)))
        // A few references are fine.
        let few = try NotabilityShapes.curves(Self.sharedShapesPlist(references: 3, segments: 10))
        XCTAssertEqual(few.curves.count, 3)
        XCTAssertEqual(few.curves[0].points.count, 31)
    }

    /// `{shapes: [s, s, …]}` with `s = {strokePath: <move + segments cubics>}`,
    /// every array entry a 1-byte reference to the same object.
    static func sharedShapesPlist(references n: Int, segments k: Int) -> Data {
        var path: [UInt8] = [0x25, 0xB3, 0xE5, 0x48] + (0..<4).map { UInt8((1 + k) >> (8 * $0) & 0xFF) }
        path += [0] + [UInt8](repeating: 3, count: k)
        for i in 0..<(1 + 3 * k) {
            for v in [Double(i % 500), Double(i % 300)] { withUnsafeBytes(of: v.bitPattern.littleEndian) { path += $0 } }
        }
        func be(_ v: Int, _ width: Int) -> [UInt8] { (0..<width).reversed().map { UInt8(v >> (8 * $0) & 0xFF) } }
        let objects: [[UInt8]] = [
            [0xD1, 1, 2],                                                     // {shapes: array}
            [0x56] + Array("shapes".utf8),
            [0xAF, 0x12] + be(n, 4) + [UInt8](repeating: 3, count: n),        // n references to object 3
            [0xD1, 4, 5],                                                     // {strokePath: data}
            [0x5A] + Array("strokePath".utf8),
            [0x4F, 0x12] + be(path.count, 4) + path,
        ]
        var out = Array("bplist00".utf8)
        var offsets: [Int] = []
        for o in objects { offsets.append(out.count); out += o }
        let table = out.count
        for o in offsets { out += be(o, 4) }
        out += [0, 0, 0, 0, 0, 0, 4, 1] + be(objects.count, 8) + be(0, 8) + be(table, 8)
        return Data(out)
    }

    /// Two copies of one note (same uuid) whose strokes all share a point
    /// count, colour and x but differ in height: every stroke of the copy
    /// was compared with every stroke of the chosen one (30 000² = 9·10⁸
    /// comparisons, over a minute). Comparisons are now budgeted; past the
    /// budget a stroke counts as missing, so the copy is imported as a
    /// separate version and no ink is lost.
    func testDuplicateDetectionIsNotQuadratic() throws {
        func prints(_ n: Int, y: Double) -> [NotabilityImporter.StrokePrint] {
            (0..<n).map { _ in
                NotabilityImporter.StrokePrint(NotabilityNote.Curve(
                    points: [.init(x: 100, y: y), .init(x: 110, y: y + 5)], fractionalWidths: [1], width: 1,
                    color: Color(r: 0, g: 0, b: 0, a: 255), style: NotabilityNote.penStyle), format: .note)
            }
        }
        var index = NotabilityImporter.PrintIndex()
        index.insert(prints(30_000, y: 0))
        let t0 = Date()
        XCTAssertEqual(index.missing(prints(30_000, y: 1000)), 30_000)
        // The budget is about 1.6·10⁷ comparisons, the quadratic scan 9·10⁸ (55 times more:
        // minutes even on a fast machine). 10 s was too tight for debug builds on CI's macOS
        // runners, which take 10–11 s for the budgeted scan; 60 s still catches the regression.
        XCTAssertLessThan(Date().timeIntervalSince(t0), 60)
        // Matching strokes are still found.
        XCTAssertEqual(index.missing(prints(100, y: 0)), 0)
    }

    /// A stroke at y = 900 000 made a two-stroke note 1 100 pages long once
    /// long notes were cut into pages (fuzz case 482: 540 pages, 8.7 s to
    /// render): blank sheets past `maxBlankSheets` are left out.
    func testStrayFarPointDoesNotMakeThousandsOfPages() throws {
        let far = SyntheticNote.CurveSpec(points: [(10, 900_000), (20, 900_000), (30, 900_010), (40, 900_010)], fw: [1, 1],
                                          width: 2, rgba: [0, 0, 0, 255], style: 3)
        let note = try NotabilityNote.parse(data: SyntheticNote.package(curves: [curve(width: 2), far]))
        let state = NotabilityImporter.convert(note)
        let blank = state.pages.filter { $0.strokes.isEmpty && $0.items.isEmpty && $0.recognition == nil }
        XCTAssertEqual(blank.count, NotabilityImporter.maxBlankSheets)
        XCTAssertLessThanOrEqual(state.pages.count, NotabilityImporter.maxBlankSheets + 3)
        XCTAssertEqual(state.pages.flatMap(\.strokes).count, 2)
        XCTAssertFalse(state.meta.pageSize.infinite)
        for page in state.pages {
            for s in page.strokes {
                let ty = s.transform?.ty ?? 0
                XCTAssertTrue(s.points.allSatisfy { $0.y + ty <= state.meta.pageSize.height }, "\(ty)")
            }
        }
        XCTAssertNoThrow(try InkJSON.encoder().encode(NotabilityImporter.ops(for: state)))
    }
}
