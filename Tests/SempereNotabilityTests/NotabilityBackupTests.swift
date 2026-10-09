import Age
import Foundation
import ImportTestSupport
import Sempere
import XCTest
@testable import SempereImport
@testable import SempereNotability

/// Whole-backup behaviour on synthetic data: copies and versions of one
/// note, short per-curve arrays, shapes, and `.ntb` bundles
/// (`docs/import-notability.md`, "Duplicates and versions", ".ntb format").
final class NotabilityBackupTests: NotabilityTestCase {
    func run(_ files: [TestZip.File], vault: Vault? = nil, name: String = "backup.zip") throws
        -> (NotabilityImporter.ImportReport, Vault) {
        let url = tmp.appendingPathComponent(name)
        try TestZip.write(files).write(to: url)
        let v = try vault ?? makeVault()
        var clock = HybridClock()
        return (try NotabilityImporter.import(paths: [url], into: v, device: DeviceID("0a0b0c0d")!, clock: &clock), v)
    }

    let t0 = SyntheticNote.created

    /// The synthetic curves without the last one (an "older version").
    var fewerCurves: [SyntheticNote.CurveSpec] { Array(SyntheticNote.curves.dropLast()) }

    /// One curve the other versions do not have.
    var otherCurve: SyntheticNote.CurveSpec {
        .init(points: [(300, 300), (310, 310), (320, 320), (330, 330)], fw: [1, 1], width: 1.4,
              rgba: [0, 0, 0, 255], style: 3)
    }

    // MARK: Zip entry times

    func testZipEntryModificationTime() throws {
        let (t, d) = TestZip.dos(2023, 12, 11, 16, 15, 24)
        let zip = try ZipArchive(data: TestZip.write([.init(path: "a", data: Data("x".utf8), dosTime: t, dosDate: d),
                                                        .init(path: "b", data: Data("y".utf8))]))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(zip.entries[0].modified,
                       utc.date(from: DateComponents(year: 2023, month: 12, day: 11, hour: 16, minute: 15, second: 24)))
        XCTAssertNil(zip.entries[1].modified)   // zeroed DOS fields are not a date
    }

    // MARK: Copies and versions

    /// The same note in two folders (a reorganised Drive backup keeps both):
    /// imported once, from the copy Notability modified last.
    func testIdenticalCopiesImportOnceNewestChosen() throws {
        let older = SyntheticNote.package(modified: t0.addingTimeInterval(100))
        let newer = SyntheticNote.package(modified: t0.addingTimeInterval(200))
        let (report, vault) = try run([
            .init(path: "Notability/Old place/A.note", data: newer),     // newest content…
            .init(path: "Notability/New place/A.note", data: older),
        ])
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.skipped, 1)
        let ok = try XCTUnwrap(report.notes.first { $0.status == .ok })
        XCTAssertTrue(ok.source.hasSuffix("Old place/A.note"))      // …wins over the path order
        XCTAssertEqual(ok.notebook, "Old place")
        XCTAssertEqual(ok.selection, "chosen from 2 copies of this note: newest modification date")
        let skipped = try XCTUnwrap(report.notes.first { $0.status != .ok })
        XCTAssertEqual(skipped.duplicateOf, ok.source)
        guard case .skipped(let why) = skipped.status else { return XCTFail() }
        XCTAssertTrue(why.hasPrefix("duplicate: same note"), why)
        XCTAssertEqual(skipped.noteId, ok.noteId)
        XCTAssertEqual(try vault.noteIDs().count, 1)
    }

    /// Equal modification dates: the newer zip entry wins, then the path.
    func testTieBreakByFileTimeThenPath() throws {
        let pkg = SyntheticNote.package()
        let (a, ad) = TestZip.dos(2021, 8, 1), (b, bd) = TestZip.dos(2023, 12, 11)
        var (report, _) = try run([
            .init(path: "Notability/X/A.note", data: pkg, dosTime: a, dosDate: ad),
            .init(path: "Notability/Y/A.note", data: pkg, dosTime: b, dosDate: bd),
        ])
        XCTAssertTrue(try XCTUnwrap(report.notes.first { $0.status == .ok }).source.hasSuffix("Y/A.note"))
        XCTAssertEqual(report.notes.first { $0.status == .ok }?.selection,
                       "chosen from 2 copies of this note: same modification date; newest file")
        (report, _) = try run([.init(path: "Notability/Y/A.note", data: pkg), .init(path: "Notability/X/A.note", data: pkg)],
                              name: "b.zip")
        XCTAssertTrue(try XCTUnwrap(report.notes.first { $0.status == .ok }).source.hasSuffix("X/A.note"))
    }

    /// An older version whose strokes are all in the newer one is skipped.
    func testOlderSubsetVersionSkipped() throws {
        let (report, vault) = try run([
            .init(path: "Notability/A/old.note", data: SyntheticNote.package(curves: fewerCurves, modified: t0.addingTimeInterval(10))),
            .init(path: "Notability/A/new.note", data: SyntheticNote.package(modified: t0.addingTimeInterval(20))),
        ])
        XCTAssertEqual(report.imported, 1)
        let skipped = try XCTUnwrap(report.notes.first { $0.status != .ok })
        XCTAssertTrue(skipped.source.hasSuffix("old.note"))
        guard case .skipped(let why) = skipped.status else { return XCTFail() }
        XCTAssertTrue(why.hasPrefix("older version: every stroke is in the version imported"), why)
        XCTAssertEqual(try vault.noteIDs().count, 1)
        XCTAssertEqual(try vault.reconstruct(noteId: XCTUnwrap(report.notes.first { $0.status == .ok }?.noteId))
                        .pages[0].strokes.count, 4)
    }

    /// An older version holding a stroke the newest lacks (erased later) is
    /// imported as a separate note with a derived id, so no ink is lost; a
    /// second run finds both in the vault.
    func testVersionWithOtherSempereImportedSeparately() throws {
        let files: [TestZip.File] = [
            .init(path: "Notability/A/new.note", data: SyntheticNote.package(curves: fewerCurves,
                                                                             modified: t0.addingTimeInterval(20))),
            .init(path: "Notability/A/old.note", data: SyntheticNote.package(curves: SyntheticNote.curves + [otherCurve],
                                                                             modified: t0.addingTimeInterval(10))),
        ]
        let (report, vault) = try run(files)
        XCTAssertEqual(report.imported, 2)
        let primary = try XCTUnwrap(report.notes.first { $0.source.hasSuffix("new.note") })
        let extra = try XCTUnwrap(report.notes.first { $0.source.hasSuffix("old.note") })
        XCTAssertFalse(primary.extraVersion)
        XCTAssertTrue(extra.extraVersion)
        XCTAssertEqual(extra.duplicateOf, primary.source)
        XCTAssertEqual(extra.selection, "imported separately: 2 of its 5 strokes are not in the version imported from \(primary.source)")
        XCTAssertNotEqual(extra.noteId, primary.noteId)
        XCTAssertEqual(primary.noteId, UUID.derived(from: "sempere-notability:" + SyntheticNote.uuid))
        let state = try vault.reconstruct(noteId: XCTUnwrap(extra.noteId))
        XCTAssertTrue(state.meta.title.hasPrefix("Synthetic note (version modified "), state.meta.title)
        XCTAssertEqual(state.pages[0].strokes.count, 5)
        XCTAssertEqual(state.meta.notebook, "A")

        // Deterministic ids: the same backup again is entirely "already in the vault".
        let (again, _) = try run(files, vault: vault, name: "again.zip")
        XCTAssertEqual(again.notes.map(\.status), [.skipped("already in the vault"), .skipped("already in the vault")])
        XCTAssertEqual(Set(again.notes.compactMap(\.noteId)), Set(report.notes.compactMap(\.noteId)))
    }

    /// A straight line at the given height (same shape and x as any other).
    func line(y: Float, rgba: [UInt8] = [0, 0, 0, 255]) -> SyntheticNote.CurveSpec {
        let xs: [Float] = [100, 200, 300, 400]
        return .init(points: xs.map { ($0, y) }, fw: [1, 1], width: 1.4, rgba: rgba, style: 3)
    }

    /// Regression: the containment check ignored y, so an older copy holding
    /// a second, identical-looking line further down (erased later) was
    /// skipped as an "older version" and that line was lost.
    func testOlderCopyWithSameShapeAtAnotherHeightIsKept() throws {
        let (report, vault) = try run([
            .init(path: "Notability/A/new.note", data: SyntheticNote.package(curves: [line(y: 100)],
                                                                             modified: t0.addingTimeInterval(20))),
            .init(path: "Notability/A/old.note", data: SyntheticNote.package(curves: [line(y: 100), line(y: 500)],
                                                                             modified: t0.addingTimeInterval(10))),
        ])
        XCTAssertEqual(report.imported, 2, "\(report.notes.map(\.status))")
        let extra = try XCTUnwrap(report.notes.first { $0.source.hasSuffix("old.note") })
        XCTAssertTrue(extra.extraVersion)
        XCTAssertEqual(try vault.reconstruct(noteId: XCTUnwrap(extra.noteId)).pages[0].strokes.count, 2)
    }

    /// Two older copies that differ in ink but share format, modification
    /// date and stroke count used to derive the same id: the second was then
    /// skipped as "duplicate of an earlier note in this import" and its ink
    /// lost. Ids are content-addressed now, and do not depend on file times.
    func testExtraVersionsWithSameDateAndCountGetDistinctStableIds() throws {
        let same = t0.addingTimeInterval(10)
        func files(_ dos: (UInt16, UInt16)) -> [TestZip.File] { [
            .init(path: "Notability/A/new.note", data: SyntheticNote.package(curves: [line(y: 100)],
                                                                             modified: t0.addingTimeInterval(20)),
                  dosTime: dos.0, dosDate: dos.1),
            .init(path: "Notability/B/v1.note", data: SyntheticNote.package(curves: [line(y: 100), line(y: 300, rgba: [255, 0, 0, 255])],
                                                                            modified: same), dosTime: dos.0, dosDate: dos.1),
            .init(path: "Notability/C/v2.note", data: SyntheticNote.package(curves: [line(y: 100), line(y: 700, rgba: [0, 0, 255, 255])],
                                                                            modified: same), dosTime: dos.0, dosDate: dos.1),
        ] }
        let (report, vault) = try run(files(TestZip.dos(2024, 1, 2)))
        XCTAssertEqual(report.imported, 3, "\(report.notes.map(\.status))")
        XCTAssertEqual(Set(report.notes.compactMap(\.noteId)).count, 3)
        // A later download of the same backup (other file times, other order):
        // every note is found again, nothing new is written.
        let (again, _) = try run(Array(files(TestZip.dos(2025, 6, 7)).reversed()), vault: vault, name: "later.zip")
        XCTAssertEqual(again.notes.map(\.status), Array(repeating: .skipped("already in the vault"), count: 3))
        XCTAssertEqual(Set(again.notes.compactMap(\.noteId)), Set(report.notes.compactMap(\.noteId)))
        XCTAssertEqual(try vault.noteIDs().count, 3)
    }

    /// The same sources in any order and any split over zips give the same
    /// choices, ids and vault content.
    func testOrderOfInputsDoesNotChangeTheResult() throws {
        let createdMs = Int64((SyntheticNote.created.timeIntervalSince1970 * 1000).rounded())
        let entries: [TestZip.File] = [
            .init(path: "Notability/A/x.note", data: SyntheticNote.package(curves: fewerCurves, modified: t0.addingTimeInterval(20))),
            .init(path: "Notability/B/x.note", data: SyntheticNote.package(modified: t0.addingTimeInterval(30))),
            .init(path: "Notability/C/x.note", data: SyntheticNote.package(curves: SyntheticNote.curves + [otherCurve],
                                                                           modified: t0.addingTimeInterval(10))),
            .init(path: "Notability/C/x.ntb", data: SyntheticBundle.package(SyntheticBundle.noteBundle(
                strokes: SyntheticBundle.strokesMatchingSyntheticNote(), createdMs: createdMs))),
            .init(path: "Notability/D/lone.ntb", data: SyntheticBundle.package(SyntheticBundle.noteBundle(
                title: "Lone", strokes: SyntheticBundle.strokesMatchingSyntheticNote()))),
        ]
        func outcome(_ parts: [[TestZip.File]]) throws -> [String] {
            let vault = try makeVault()
            var urls: [URL] = []
            for (i, part) in parts.enumerated() {
                let url = tmp.appendingPathComponent("part-\(UUID().uuidString)-\(i).zip")
                try TestZip.write(part).write(to: url)
                urls.append(url)
            }
            var clock = HybridClock()
            let report = try NotabilityImporter.import(paths: urls, into: vault, device: DeviceID("0a0b0c0d")!, clock: &clock)
            XCTAssertEqual(report.failed, 0)
            // Per written note: id, title, notebook, tags and every stroke's id and first point.
            return try vault.noteIDs().sorted { $0.uuidString < $1.uuidString }.map { id in
                let st = try vault.reconstruct(noteId: id)
                let strokes = st.pages.flatMap(\.strokes).map { "\($0.id) \($0.points[0].x) \($0.points[0].y)" }
                return "\(id) \(st.meta.title) \(st.meta.notebook ?? "-") \(st.meta.tags) \(strokes)"
            }
        }
        let reference = try outcome([entries])
        XCTAssertEqual(reference.count, 3)   // the note, the version with other ink, the lone bundle
        XCTAssertEqual(try outcome([Array(entries.reversed())]), reference)
        XCTAssertEqual(try outcome([[entries[4], entries[2]], [entries[1]], [entries[3], entries[0]]]), reference)
        XCTAssertEqual(try outcome([[entries[0]], [entries[3], entries[1]], [entries[4], entries[2]]]), reference)
    }

    /// Regression: the ranking compared ".note before .ntb unless the .note is
    /// empty" pairwise, which is not a consistent order when a group holds an
    /// empty newest `.note`, an inked older `.note` and an inked `.ntb`: the
    /// note chosen (and so every id) depended on the order of the inputs.
    func testRankingIsIndependentOfInputOrder() throws {
        let createdMs = Int64((SyntheticNote.created.timeIntervalSince1970 * 1000).rounded())
        let entries: [TestZip.File] = [
            .init(path: "Notability/A/x.note", data: SyntheticNote.package(curves: [], handwriting: false,
                                                                           modified: t0.addingTimeInterval(30))),
            .init(path: "Notability/B/x.ntb", data: SyntheticBundle.package(SyntheticBundle.noteBundle(
                strokes: SyntheticBundle.strokesMatchingSyntheticNote(), createdMs: createdMs))),
            .init(path: "Notability/C/x.note", data: SyntheticNote.package(modified: t0.addingTimeInterval(10))),
        ]
        // One zip per copy (entries inside a zip are read in path order), passed in every order.
        let zips = try entries.enumerated().map { i, e -> URL in
            let url = tmp.appendingPathComponent("copy-\(i).zip")
            try TestZip.write([e]).write(to: url)
            return url
        }
        var outcomes = Set<String>()
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            var clock = HybridClock()
            let report = try NotabilityImporter.import(paths: order.map { zips[$0] }, into: makeVault(),
                                                       device: DeviceID("0a0b0c0d")!, clock: &clock)
            outcomes.insert(report.notes.sorted { $0.source < $1.source }
                .map { "\($0.source) \($0.status) \($0.noteId?.uuidString ?? "-")" }.joined(separator: "\n"))
        }
        XCTAssertEqual(outcomes.count, 1, outcomes.joined(separator: "\n---\n"))
        // The inked .note is the note; the empty newer .note and the .ntb are not written.
        let only = try XCTUnwrap(outcomes.first)
        XCTAssertTrue(only.contains("C/x.note ok \(UUID.derived(from: "sempere-notability:" + SyntheticNote.uuid).uuidString)"),
                      only)
    }

    /// Copies split over several zips (Drive splits large backups) are resolved together.
    func testCopiesAcrossZips() throws {
        let a = tmp.appendingPathComponent("part-1.zip"), b = tmp.appendingPathComponent("part-2.zip")
        try TestZip.write([.init(path: "Notability/A/x.note", data: SyntheticNote.package(modified: t0))]).write(to: a)
        try TestZip.write([.init(path: "Notability/B/x.note",
                                   data: SyntheticNote.package(modified: t0.addingTimeInterval(5)))]).write(to: b)
        var clock = HybridClock()
        let report = try NotabilityImporter.import(paths: [a, b], into: makeVault(), device: DeviceID("0a0b0c0d")!,
                                                   clock: &clock)
        XCTAssertEqual(report.imported, 1)
        XCTAssertTrue(try XCTUnwrap(report.notes.first { $0.status == .ok }).source.hasPrefix(b.path))
        XCTAssertEqual(report.notes.first { $0.status != .ok }?.duplicateOf, report.notes[1].source)
    }

    /// A `.note` without ink and an `.ntb` of the same note with ink: the
    /// bundle is imported as the note (under the uuid), the empty `.note` skipped.
    func testInkedBundleWinsOverEmptyNote() throws {
        let createdMs = Int64((SyntheticNote.created.timeIntervalSince1970 * 1000).rounded())
        let bundle = SyntheticBundle.noteBundle(strokes: SyntheticBundle.strokesMatchingSyntheticNote(), createdMs: createdMs)
        let (report, vault) = try run([
            .init(path: "Notability/A/x.note", data: SyntheticNote.package(curves: [], handwriting: false)),
            .init(path: "Notability/A/x.ntb", data: SyntheticBundle.package(bundle)),
        ])
        let ntb = try XCTUnwrap(report.notes.first { $0.format == .ntb })
        XCTAssertEqual(ntb.status, .ok)
        XCTAssertEqual(ntb.selection, "chosen from 2 copies of this note: the .ntb holds ink and the .note none")
        XCTAssertEqual(ntb.noteId, UUID.derived(from: "sempere-notability:" + SyntheticNote.uuid))
        XCTAssertEqual(report.notes.first { $0.format == .note }?.status.isSkipped, true)
        XCTAssertEqual(try vault.reconstruct(noteId: XCTUnwrap(ntb.noteId)).pages[0].strokes.count, 2)
    }

    // MARK: Tags

    /// Folder path segments become tags (case-insensitive, first spelling
    /// wins, Notability's own tags first), fixed tags are added, and an
    /// overwrite after the note moved drops the old folder's tags.
    func testFolderAndExtraTags() throws {
        let pkg = SyntheticNote.package(tags: "alpha, Research")
        let first = tmp.appendingPathComponent("first.zip"), moved = tmp.appendingPathComponent("moved.zip")
        try TestZip.write([.init(path: "Notability/research/Daily  log/A.note", data: pkg)]).write(to: first)
        try TestZip.write([.init(path: "Notability/Archive/A.note", data: pkg)]).write(to: moved)
        let vault = try makeVault()
        var clock = HybridClock()
        let options = NotabilityImporter.Options(tagsFromFolders: true, extraTags: ["imported", "ALPHA"])
        let report = try NotabilityImporter.import(paths: [first], into: vault, device: DeviceID("0a0b0c0d")!,
                                                   clock: &clock, options: options)
        let id = try XCTUnwrap(report.notes[0].noteId)
        var state = try vault.reconstruct(noteId: id)
        XCTAssertEqual(state.meta.tags, ["alpha", "Research", "Daily log", "imported"])
        XCTAssertEqual(state.meta.notebook, "research/Daily  log")   // the notebook path is unchanged

        var over = options
        over.overwrite = true
        _ = try NotabilityImporter.import(paths: [moved], into: vault, device: DeviceID("0a0b0c0d")!, clock: &clock,
                                          options: over)
        state = try vault.reconstruct(noteId: id)
        XCTAssertEqual(state.meta.tags, ["alpha", "Research", "Archive", "imported"])

        // Off (the library default): only Notability's tags.
        let plain = try NotabilityImporter.import(paths: [first], into: makeVault(), device: DeviceID("0a0b0c0d")!,
                                                  clock: &clock)
        XCTAssertEqual(plain.notes[0].status, .ok)
        XCTAssertEqual(NotabilityImporter.tags(for: try NotabilityNote.parse(data: pkg), folder: "X/Y",
                                               options: .init()), ["alpha", "Research"])
    }

    // MARK: Per-curve arrays

    /// `curvesstyles` (and `curveswidth`, `curvescolors`) shorter than the
    /// curve count: the note imports, the missing entries are defaulted and counted.
    func testShortPerCurveArraysAreDefaulted() throws {
        for missing in 1...3 {
            let styles = Data(SyntheticNote.curves.dropLast(missing).map(\.style))
            let note = try NotabilityNote.parse(data: SyntheticNote.package(styles: styles))
            XCTAssertEqual(note.curves.count, 4)
            XCTAssertEqual(note.defaultedCurveAttributes, ["curvesstyles": missing])
            XCTAssertEqual(note.defaultedCurves, missing)
            XCTAssertEqual(note.curves.suffix(missing).map(\.style), Array(repeating: NotabilityNote.penStyle, count: missing))
            XCTAssertEqual(NotabilityImporter.dropped(note).defaultedAttributeStrokes, missing)
        }
        // Int32 styles, one short.
        var i32 = Data()
        for s in SyntheticNote.curves.dropLast().map({ Int32($0.style) }) {
            var v = s.littleEndian
            i32.append(Data(bytes: &v, count: 4))
        }
        let note = try NotabilityNote.parse(data: SyntheticNote.package(styles: i32))
        XCTAssertEqual(note.curves.map(\.style), [3, 3, 4, 3])
        XCTAssertEqual(note.defaultedCurves, 1)

        let (report, _) = try run([.init(path: "Notability/A/s.note",
                                         data: SyntheticNote.package(styles: Data([3, 3])))])
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.notes[0].strokes, 4)
        XCTAssertEqual(report.notes[0].dropped.defaultedAttributeStrokes, 2)
    }

    // MARK: Shapes

    static func shapesPlist() -> Data {
        // A path: move, cubic, line, close.
        var path = Data([0x25, 0xB3, 0xE5, 0x48, 4, 0, 0, 0, 0, 3, 1, 4])
        for v in [400.0, 400, 410, 390, 430, 390, 440, 400, 440, 420] {
            var b = v.bitPattern.littleEndian
            path.append(Data(bytes: &b, count: 8))
        }
        let appearance = BValue.dict([("style", .int(3)), ("strokeWidth", .real(2)),
                                      ("strokeColor", .dict([("rgba", .array([.real(1), .real(0), .real(0), .real(1)]))]))])
        let line = BValue.dict([("startPt", .array([.real(10), .real(20)])), ("endPt", .array([.real(110), .real(20)])),
                                ("rect", .array([])), ("appearance", appearance)])
        let corners = BValue.array([.array([.real(0), .real(100)]), .array([.real(200), .real(100)]),
                                    .array([.real(200), .real(0)]), .array([.real(0), .real(0)])])
        let circle = BValue.dict([("rotatedRect", .dict([("corners", corners)])), ("appearance", appearance)])
        let partial = BValue.dict([("strokePath", .data(path)), ("appearance", appearance)])
        let broken = BValue.dict([("strokePath", .data(Data([1, 2, 3]))), ("appearance", appearance)])
        return BPlist.encode(.dict([("shapes", .array([line, circle, partial, broken])),
                                    ("indices", .array([.int(1), .int(2), .int(3), .int(4)])),
                                    ("kinds", .array([.string("line"), .string("circle"), .string("partialshape"),
                                                      .string("partialshape")]))]))
    }

    func testShapesImportAsStrokes() throws {
        let note = try NotabilityNote.parse(data: SyntheticNote.package(shapes: Self.shapesPlist()))
        XCTAssertEqual(note.shapeCount, 3)
        XCTAssertEqual(note.unsupportedShapes, 1)
        XCTAssertEqual(note.curves.count, 7)
        let line = note.curves[4], circle = note.curves[5], path = note.curves[6]
        XCTAssertEqual(line.points.first, .init(x: 10, y: 20))
        XCTAssertEqual(line.points.last, .init(x: 110, y: 20))
        XCTAssertEqual(line.width, 2)
        XCTAssertEqual(line.color, Color(r: 255, g: 0, b: 0, a: 255))
        // The ellipse touches the midpoint of every side of its rectangle.
        XCTAssertEqual(circle.points.count, 13)
        for (i, expected) in [(0, (200.0, 50.0)), (3, (100.0, 0.0)), (6, (0.0, 50.0)), (9, (100.0, 100.0))] {
            XCTAssertEqual(circle.points[i].x, expected.0, accuracy: 1e-9)
            XCTAssertEqual(circle.points[i].y, expected.1, accuracy: 1e-9)
        }
        XCTAssertEqual(circle.points.first, circle.points.last)
        // move, cubic, line (as a straight Bézier) and close back to the start.
        XCTAssertEqual(path.points.count, 10)
        XCTAssertEqual(path.points[3], .init(x: 440, y: 400))
        XCTAssertEqual(path.points[6], .init(x: 440, y: 420))
        XCTAssertEqual(path.points[9], .init(x: 400, y: 400))
        XCTAssertEqual(path.fractionalWidths.count, 4)
        XCTAssertEqual(NotabilityImporter.dropped(note).unsupportedShapes, 1)
        let state = NotabilityImporter.convert(note)
        XCTAssertEqual(state.pages[0].strokes.count, 7)
    }

    // MARK: .ntb

    func testBundleStrokesPagesAndPieces() throws {
        let s1 = SyntheticBundle.StrokeSpec(origin: (100, 50), segments: [((1, 0), (2, 0), (3, 1), false)])
        var s2 = SyntheticBundle.StrokeSpec(page: 2, origin: (200, 60), segments: [
            ((0, 1), (0, 2), (1, 3), false), ((0, 0), (0, 0), (10, 0), true), ((11, 1), (12, 2), (13, 3), false),
        ], rgba: [0xFF, 0xFF, 0, 0x6B], width: 6, highlighter: true, dashed: true)
        s2.wide = true
        let unsupported = SyntheticBundle.StrokeSpec(origin: (10, 10), segments: [((1, 1), (2, 2), (3, 3), false)], kind: 7)
        let bundle = SyntheticBundle.noteBundle(strokes: [s1, s2, unsupported], lines: [((50, 70), (100, 0))],
                                                extraRecords: [SyntheticBundle.record(50, type: 2, payload: [0: .u32(0)])])
        let note = try NotabilityBundle.parse(package: NotePackage(data: SyntheticBundle.package(bundle)))
        XCTAssertEqual(note.sourceFormat, .ntb)
        XCTAssertEqual(note.metadata.name, "Synthetic bundle")
        XCTAssertNil(note.metadata.uuid)
        XCTAssertEqual(note.metadata.created?.timeIntervalSince1970 ?? 0, 1_700_000_000.123, accuracy: 1e-6)
        XCTAssertEqual(note.bundleModified?.timeIntervalSince1970 ?? 0, 1_700_000_002.123, accuracy: 1e-6)
        XCTAssertEqual(note.paper.width, 716.8, accuracy: 1e-4)
        XCTAssertEqual(note.paper.pageHeight, 940.8, accuracy: 1e-3)
        XCTAssertEqual(note.paper.kind, .dot)
        XCTAssertEqual(note.paper.spacing ?? 0, 16.6, accuracy: 1e-4)
        XCTAssertEqual(note.pdfCount, 1)
        XCTAssertEqual(note.unsupportedStrokes, 1)
        // The report says which kind it was (GA-27), so a backup survey shows what to decode next.
        XCTAssertEqual(note.unsupportedKinds, ["stroke of geometry kind 7": 1])
        // s1, s2 in two pieces (the jump), then the line.
        XCTAssertEqual(note.curves.count, 4)
        XCTAssertEqual(note.shapeCount, 1)
        let m = Double(SyntheticBundle.margin)
        XCTAssertEqual(note.curves[0].points.map(\.x), [100 - m, 101 - m, 102 - m, 103 - m].map { $0 }, accuracy: 1e-3)
        XCTAssertEqual(note.curves[0].points.last?.y ?? 0, 51, accuracy: 1e-3)
        let page2 = 2 * Double(SyntheticBundle.height)
        XCTAssertEqual(note.curves[1].points.count, 4)
        XCTAssertEqual(note.curves[1].points[0].y, 60 + page2, accuracy: 1e-3)
        XCTAssertEqual(note.curves[2].points.count, 4)
        XCTAssertEqual(note.curves[2].points[0].x, 210 - m, accuracy: 1e-3)    // the jump target
        XCTAssertEqual(note.curves[2].points[3].x, 213 - m, accuracy: 1e-3)
        XCTAssertEqual(note.curves[2].points[3].y, 63 + page2, accuracy: 1e-3)
        XCTAssertTrue(note.curves[1].isHighlighter)
        XCTAssertTrue(note.curves[1].dashed && note.curves[2].dashed)
        XCTAssertEqual(note.curves[1].width, 6)
        XCTAssertEqual(note.curves[1].color, Color(r: 0xFF, g: 0xFF, b: 0, a: 0x6B))
        XCTAssertEqual(note.curves[0].fractionalWidths, [1, 1])
        XCTAssertEqual(note.curves[3].points.first?.x ?? 0, 50 - m, accuracy: 1e-3)
        XCTAssertEqual(note.curves[3].points.last?.x ?? 0, 150 - m, accuracy: 1e-3)
        XCTAssertEqual(note.curves[3].color, Color(r: 0xED, g: 0x36, b: 0x24, a: 0xFF))
    }

    /// Bundle points are page coordinates whatever margin the document
    /// record holds (newer letter notes record 36): the stroke lands at its
    /// page x after import.
    func testBundlePointsArePageCoordinates() throws {
        let s = SyntheticBundle.StrokeSpec(origin: (100, 50), segments: [((1, 0), (2, 0), (3, 1), false)])
        let note = try NotabilityBundle.parse(bundle: SyntheticBundle.noteBundle(strokes: [s], pageWidth: 612,
                                                                                  pageHeight: 792, margin: 36))
        XCTAssertEqual(note.paper.width, 612)
        let state = NotabilityImporter.convert(note)
        XCTAssertEqual(state.pages[0].strokes[0].points[0].x, 100, accuracy: 1e-3)
        XCTAssertEqual(state.pages[0].strokes[0].points[0].y, 50, accuracy: 1e-3)
    }

    /// Bundles written as a log carry erase records listing removed record
    /// ids: those strokes are not imported.
    func testBundleEraseRecordsRemoveStrokes() throws {
        let a = SyntheticBundle.StrokeSpec(origin: (100, 50), segments: [((1, 0), (2, 0), (3, 1), false)])
        let b = SyntheticBundle.StrokeSpec(origin: (200, 50), segments: [((1, 0), (2, 0), (3, 1), false)])
        // Strokes are records 1 and 2 (see SyntheticBundle.noteBundle); erase record 1.
        let bundle = SyntheticBundle.noteBundle(strokes: [a, b], extraRecords: [SyntheticBundle.erase([1])])
        let note = try NotabilityBundle.parse(bundle: bundle)
        XCTAssertEqual(note.curves.count, 1)
        XCTAssertEqual(note.erasedRecords, 1)
        XCTAssertEqual(note.curves[0].points[0].x, 200 - 716.8 / 38.4, accuracy: 1e-3)
    }

    func testBundleOriginClampedAtPageEdge() throws {
        let s = SyntheticBundle.StrokeSpec(origin: (SyntheticBundle.width, 50), segments: [((1, 0), (2, 0), (3, 1), false)])
        let note = try NotabilityBundle.parse(bundle: SyntheticBundle.noteBundle(strokes: [s]))
        XCTAssertTrue(note.curves[0].originClamped)
        XCTAssertEqual(NotabilityImporter.dropped(note).clampedStrokes, 1)
    }

    func testCorruptBundleFailsCleanly() throws {
        let good = SyntheticBundle.noteBundle(strokes: SyntheticBundle.strokesMatchingSyntheticNote())
        for cut in [0, 3, 16, good.count / 2, good.count - 3] {
            XCTAssertThrowsError(try NotabilityBundle.parse(bundle: good.prefix(cut)), "cut at \(cut)")
        }
        XCTAssertThrowsError(try NotabilityBundle.parse(package: NotePackage(data: TestZip.write([
            .init(path: "version", data: Data("1".utf8)),
        ]))))
        let (report, _) = try run([.init(path: "Notability/A/bad.ntb", data: SyntheticBundle.package(good.prefix(good.count / 2)))])
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.notes[0].format, .ntb)
    }

    /// An `.ntb` next to the `.note` of the same note (same creation time) is
    /// reported as superseded; an `.ntb` without a `.note` is imported.
    func testBundlePairedWithNoteIsSupersededAndLoneBundleImports() throws {
        let createdMs = Int64((SyntheticNote.created.timeIntervalSince1970 * 1000).rounded())
        let paired = SyntheticBundle.noteBundle(strokes: SyntheticBundle.strokesMatchingSyntheticNote(), createdMs: createdMs)
        let lone = SyntheticBundle.noteBundle(title: "Only a bundle",
                                              strokes: SyntheticBundle.strokesMatchingSyntheticNote())
        let files: [TestZip.File] = [
            .init(path: "Notability/A/x.note", data: SyntheticNote.package()),
            .init(path: "Notability/A/x.ntb", data: SyntheticBundle.package(paired)),
            .init(path: "Notability/B/y.ntb", data: SyntheticBundle.package(lone)),
        ]
        let (report, vault) = try run(files)
        XCTAssertEqual(report.notes.count, 3)
        XCTAssertEqual(report.imported, 2)
        let note = try XCTUnwrap(report.notes.first { $0.source.hasSuffix("x.note") })
        let sup = try XCTUnwrap(report.notes.first { $0.source.hasSuffix("x.ntb") })
        let alone = try XCTUnwrap(report.notes.first { $0.source.hasSuffix("y.ntb") })
        XCTAssertEqual(note.status, .ok)
        XCTAssertEqual(note.selection, "chosen from 2 copies of this note: a .note is preferred over .ntb copies")
        XCTAssertEqual(sup.format, .ntb)
        XCTAssertEqual(sup.status, .skipped("superseded: .ntb copy of the note imported from \(note.source) (the .note is used)"))
        XCTAssertEqual(alone.status, .ok)
        XCTAssertEqual(alone.format, .ntb)
        XCTAssertEqual(alone.strokes, 2)
        XCTAssertEqual(alone.notebook, "B")
        XCTAssertEqual(alone.noteId, UUID.derived(from: "sempere-notability:ntb-created:\(SyntheticBundle.createdMs)"))
        let state = try vault.reconstruct(noteId: XCTUnwrap(alone.noteId))
        XCTAssertEqual(state.meta.title, "Only a bundle")
        XCTAssertEqual(state.meta.paper.kind, .dot)
        // Same ink as the .note converts to the same place on the page.
        let fromNote = NotabilityImporter.convert(try NotabilityNote.parse(data: SyntheticNote.package()))
        let a = fromNote.pages[0].strokes.filter { $0.ink.tool == .pen }.prefix(2).map { $0.points[0] }
        let b = state.pages[0].strokes.map { $0.points[0] }
        for (p, q) in zip(a, b) {
            XCTAssertEqual(p.x, q.x, accuracy: 0.01)
            XCTAssertEqual(p.y, q.y, accuracy: 0.01)
        }
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath,
                            line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}

private extension NotabilityImporter.Status {
    var isSkipped: Bool { if case .skipped = self { return true }; return false }
}
