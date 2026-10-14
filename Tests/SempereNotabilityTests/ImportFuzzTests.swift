import Foundation
import ImportTestSupport
import FuzzSupport
import SempereRender
import Sempere
import XCTest

@testable import SempereImport
@testable import SempereNotability

/// Seeded mutation fuzzing of the importer's parsers: the zip reader (bombs,
/// overlapping entries, bad CRCs, ZIP64 fields), binary plists and keyed
/// archives (cyclic UIDs, deep nesting, huge counts), and a whole `.note`
/// (per-curve arrays, half floats) through conversion to note state.
final class ImportFuzzTests: XCTestCase {
    static func typed(_ body: () throws -> Void) -> String? {
        do { try body() } catch is ImportError {
        } catch is RenderError {
        } catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    func assertClean(_ report: FuzzReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(report.cases, 0, file: file, line: line)
        for f in report.failures { XCTFail("\(f)", file: file, line: line) }
    }

    /// Parses a note and runs everything an import does with it, short of
    /// writing to a vault: conversion, ops, JSON encoding and a render.
    static func importNote(_ pkg: NotePackage) throws {
        let note = try NotabilityNote.parse(package: pkg)
        let state = NotabilityImporter.convert(note, notebook: nil)
        _ = NotabilityImporter.dropped(note)
        _ = NotabilityImporter.noteId(for: note)
        let ops = NotabilityImporter.ops(for: state)
        _ = try InkJSON.encoder().encode(ops)
        _ = try PNGWriter.render(note: state, png: PNGOptions(scale: 0.05, maxPixels: 200_000))
    }

    func testFuzzZip() throws {
        let files: [TestZip.File] = [
            .init(path: "a/", data: Data(), deflate: false),
            .init(path: "a/one.txt", data: Data(repeating: 0x41, count: 5000)),
            .init(path: "a/two.bin", data: Data((0..<300).map { UInt8($0 & 0xFF) }), deflate: false),
            .init(path: "../escape", data: Data("x".utf8)),
        ]
        let seeds = [TestZip.write(files), TestZip.write(files, zip64: true), SyntheticNote.package()]
        assertClean(Fuzz.run("zip", seeds: seeds, quick: 2500, maxSize: 512 << 10) { input in
            Self.typed {
                let zip = try ZipArchive(data: input)
                for e in zip.entries.prefix(64) { _ = try? zip.read(e, maxSize: 16 << 20) }
            }
        })
    }

    func testFuzzKeyedArchives() throws {
        let seeds = [SyntheticNote.session(), SyntheticNote.metadata(), SyntheticNote.handwritingIndex(),
                     SyntheticNote.session(pdfPages: 2, paperSize: "custom:0.75")]
        assertClean(Fuzz.run("bplist", seeds: seeds, quick: 2000, maxSize: 256 << 10) { input in
            Self.typed {
                _ = try? NotabilityNote.parseRecognition(input)
                _ = try? NotabilityNote.parseRecordingCount(input)
                _ = try? NotabilityNote.dashedCurves(input)
                let a = try KeyedArchive(data: input)
                for key in a.top.keys {
                    // Walk every reachable object a few levels deep, as the importer does.
                    func walk(_ n: KeyedArchive.Node, _ depth: Int) throws {
                        guard depth < 6 else { return }
                        switch n {
                        case .object(_, let fields): for k in fields.keys.sorted().prefix(32) { try walk(a.field(n, k), depth + 1) }
                        case .dict(let d): for k in d.keys.sorted().prefix(32) { try walk(a.field(n, k), depth + 1) }
                        case .array: for e in try a.elements(n).prefix(32) { try walk(e, depth + 1) }
                        default: break
                        }
                    }
                    try walk(a.root(key), 0)
                }
            }
        })
    }

    /// XML plists (Notability's `Recordings/library.plist`) through the strict reader.
    func testFuzzXMLPlists() throws {
        let seeds = [SyntheticNote.recordingsLibrary(), SyntheticNote.recordingsLibrary(recordings: 3),
                     Data(#"<plist><array><integer>-4</integer><real>1.5</real><true/><date>2026-10-05T12:00:00Z</date><data>AAEC</data><string>&lt;&#x41;&amp;</string></array></plist>"#.utf8)]
        assertClean(Fuzz.run("xmlplist", seeds: seeds, quick: 2000, maxSize: 64 << 10) { input in
            Self.typed {
                _ = try? NotabilityNote.parseRecordingCount(input)
                _ = try PlistValue.parse(input, allowXML: true)
            }
        })
    }

    /// A whole note: one package file mutated (so the zip stays valid), or
    /// the package itself, or a note with generated hostile curve arrays.
    func testFuzzNotabilityNotes() throws {
        let parts = SyntheticNote.files()
        let seeds = parts.map(\.1) + [SyntheticNote.package()]
        assertClean(Fuzz.run("notability", seeds: seeds, quick: 500, maxSize: 512 << 10, generate: Self.hostileNote) { input in
            Self.typed {
                if input.starts(with: [0x50, 0x4B]) {
                    try Self.importNote(NotePackage(data: input))
                    return
                }
                // Put the mutated bytes in place of the part they came from (by size class).
                for (i, part) in parts.enumerated() where i == input.count % parts.count || part.0.hasSuffix("Session.plist") {
                    var files = parts
                    files[i].1 = input
                    let zip = TestZip.write(files.map { .init(path: $0.0, data: $0.1, deflate: false) })
                    try Self.importNote(NotePackage(data: zip))
                }
            }
        })
    }

    /// `.ntb` bundles (merged from main, #31) through the whole scan an import
    /// does: parse, the duplicate plan over two copies (dates turned into
    /// milliseconds, stroke prints compared), conversion and JSON encoding,
    /// under the harness's time and memory watchdog.
    func testFuzzNtbBundles() throws {
        let seeds = [NotabilityFuzzTests.seedBundle(),
                     SyntheticBundle.noteBundle(strokes: SyntheticBundle.strokesMatchingSyntheticNote()),
                     UntrustedImportTests.sharedTitleBundle(records: 3, titleBytes: 100)]
        assertClean(Fuzz.run("ntb", seeds: seeds, quick: 1500, maxSize: 256 << 10) { input in
            Self.typed {
                let note = try NotabilityBundle.parse(bundle: input)
                let source = NotabilityImporter.Source(label: "x.ntb", notebook: nil, format: .ntb, modified: nil,
                                                       load: { NotePackage(zip: try ZipArchive(data: SyntheticBundle.package(input))) })
                _ = NotabilityImporter.plan([source, source])
                let state = NotabilityImporter.convert(note, key: "fuzz")
                _ = try InkJSON.encoder().encode(NotabilityImporter.ops(for: state))
            }
        })
    }

    /// `.ntb` bundles with PDF and media records naming top-level files: the
    /// mutated `noteBundle` next to real attachment files, through parsing,
    /// attachment resolution (PDF pages, images, PDF text) and conversion.
    func testFuzzNtbAttachments() throws {
        let pkg = try NotePackage(data: CLIGapsFixtureTests.bundlePackage())
        let files = try pkg.paths.filter { $0 != "noteBundle" }.map { ($0, try pkg.read($0)) }
        let seeds = [try pkg.read("noteBundle")]
        assertClean(Fuzz.run("ntbattach", seeds: seeds, quick: 300, maxSize: 64 << 10) { input in
            Self.typed {
                let zip = TestZip.write([.init(path: "noteBundle", data: input, deflate: false)]
                                          + files.map { .init(path: $0.0, data: $0.1, deflate: false) })
                let pkg = try NotePackage(data: zip)
                let note = try NotabilityBundle.parse(package: pkg)
                let a = NotabilityAttachments.resolve(note, package: pkg)
                let state = NotabilityImporter.convert(note, key: "fuzz", attachments: a)
                _ = try InkJSON.encoder().encode(NotabilityImporter.ops(for: state))
            }
        })
    }

    /// Notability's PDF indexes (`PDFIndex.zip` entries, `PDFIndex.fb`) through their readers.
    func testFuzzPDFIndexes() throws {
        let zipSeed = TestZip.write([.init(path: "PDFTextIndex.txt", data: Data("one\u{0C}two\u{0C}".utf8)),
                                       .init(path: "PDFMetadataIndex.plist",
                                             data: BPlist.encode(.dict([("o", .array([.int(0), .int(4)]))])))])
        let fbSeed = SyntheticBundle.handwritingIndex([.init(index: 0, text: "first", boxes: []),
                                                       .init(index: 1, text: "second", boxes: [])])
        assertClean(Fuzz.run("pdfindex", seeds: [zipSeed, fbSeed], quick: 1500, maxSize: 64 << 10) { input in
            var notes: [String] = []
            _ = NotabilityPDFIndex.noteIndex(input, pageCount: 2, notes: &notes)
            _ = NotabilityPDFIndex.bundleIndex(input, notes: &notes)
            if let plist = try? PlistValue.parse(input, allowXML: true) {
                _ = NotabilityPDFIndex.split("abcdefgh", offsetsIn: plist, pageCount: 2)
            }
            return nil
        })
    }

    /// `.ntb` handwriting indexes (`ios/HandwritingIndex.fb`) through the reader and the merge.
    func testFuzzNtbHandwritingIndexes() throws {
        let seeds = [SyntheticBundle.handwritingIndex([
            .init(index: 0, text: "hi you", boxes: [(36, 20, 8, 10), (44, 20, 4, 10), nil, (60, 22, 9, 10), (69, 22, 9, 10), (78, 22, 9, 10)]),
            .init(index: 1, text: "two", boxes: [(40, 30, 10, 12), (50, 30, 10, 12), (60, 30, 10, 12)])])]
        assertClean(Fuzz.run("ntbindex", seeds: seeds, quick: 2000, maxSize: 64 << 10) { input in
            Self.typed {
                var note = try NotabilityBundle.parse(bundle: SyntheticBundle.noteBundle(strokes: SyntheticBundle.strokesMatchingSyntheticNote()))
                note.recognition = try NotabilityBundle.parseHandwritingIndex(input, inset: note.paper.insetX)
                _ = NotabilityImporter.recognition(note)
            }
        })
    }

    /// The `shapes` plist bytes (strict reader) through the shape converter.
    func testFuzzShapes() throws {
        let seeds = [NotabilityBackupTests.shapesPlist(), UntrustedImportTests.sharedShapesPlist(references: 4, segments: 6)]
        assertClean(Fuzz.run("shapes", seeds: seeds, quick: 2000, maxSize: 64 << 10) { input in
            var problem: String?
            let untyped = Self.typed {
                let (curves, _) = try NotabilityShapes.curves(input)
                let points = curves.reduce(0) { $0 + $1.points.count }
                if points > NotabilityShapes.pointsPerByte * input.count + NotabilityShapes.pointAllowance {
                    problem = "\(input.count) bytes decoded into \(points) points"
                }
            }
            return untyped ?? problem
        })
    }

    /// Curve arrays with lengths and values chosen to break the parser's
    /// arithmetic: counts that overflow when summed, NaN and infinite
    /// floats, huge widths, `numcurves` far beyond the arrays.
    static func hostileNote(_ rng: inout FuzzRNG) -> Data {
        let floats: [Float] = [0, 1, -1, .nan, .infinity, -.infinity, 1e38, -1e38, 1e6, 999_999, 3.4e38, .leastNonzeroMagnitude]
        let counts = [0, 1, 2, 3, 4, 7, 1000, Int(Int32.max), -1]
        var curves: [SyntheticNote.CurveSpec] = []
        for _ in 0..<(1 + rng.below(4)) {
            let n = max(rng.pick([1, 2, 4, 7, 10, 3001]), 1)
            // Mostly sane coordinates, so the widths and counts below are what fails.
            let pts = (0..<n).map { _ in
                rng.oneIn(6) ? (rng.pick(floats), rng.pick(floats)) : (Float(rng.below(2000)), Float(rng.below(9000)))
            }
            let fwCount = rng.oneIn(2) ? (n - 1) / 3 + 1 : rng.pick(counts.filter { $0 >= 0 && $0 < 5000 })
            curves.append(.init(points: pts, fw: (0..<fwCount).map { _ in rng.pick(floats) }, width: rng.pick(floats),
                                rgba: [0, 0, 0, 255], style: UInt8(truncatingIfNeeded: rng.below(6))))
        }
        var files = SyntheticNote.files(curves: curves, paperSize: rng.pick(["letter", "custom:0", "custom:1e-300", "custom:nan"]))
        if rng.oneIn(3) {
            // Overwrite numcurves / numpoints with something inconsistent.
            files = files.map { f in
                guard f.0.hasSuffix("Session.plist") else { return f }
                return (f.0, SyntheticNote.session(curves: curves, numcurvesOverride: rng.pick(counts)))
            }
        }
        return TestZip.write(files.map { .init(path: $0.0, data: $0.1, deflate: rng.oneIn(2)) })
    }

    /// A note with a PDF and images through attachment resolution and
    /// conversion: mutated sessions (media objects, page layout) and
    /// mutated PDFs and images must only ever drop attachments.
    func testFuzzAttachments() throws {
        let pdf = AttachmentFixtures.pdf(pages: [(612, 792), (1024, 768)])
        let jpeg = AttachmentFixtures.jpeg(width: 40, height: 30)
        let session = SyntheticNote.session(pdfPages: 2, media: { a in
            [AttachmentFixtures.imageObject(&a, file: "Images/p.jpg", origin: (5, 5), size: (40, 30), scale: 0.5,
                                            extra: [("rotation", .real(0.3)), ("cropRect", a.string("{{0, 0}, {0.5, 1}}"))])]
        })
        let seeds = [session, pdf, jpeg]
        assertClean(Fuzz.run("attachments", seeds: seeds, quick: 300, maxSize: 128 << 10) { input in
            Self.typed {
                // The input stands in for each part in turn.
                let variants: [(Data, Data, Data)] = [(input, pdf, jpeg), (session, input, jpeg), (session, pdf, input)]
                for (s, p, j) in variants {
                    let zip = AttachmentFixtures.package(session: s, pdf: p, extra: [("Images/p.jpg", j)])
                    let pkg = try NotePackage(data: zip)
                    guard let note = try? NotabilityNote.parse(package: pkg) else { continue }
                    let a = NotabilityAttachments.resolve(note, package: pkg)
                    let state = NotabilityImporter.convert(note, attachments: a)
                    _ = NotabilityImporter.dropped(note, attachments: a)
                    for item in state.pages[0].items where item.validationError != nil {
                        throw ImportError.package("invalid item: \(item.validationError ?? "")")
                    }
                    _ = try InkJSON.encoder().encode(NotabilityImporter.ops(for: state))
                }
            }
        })
    }

    /// Typed text (both archive shapes), the recordings library, audio files
    /// and `eventTokens` through resolution and conversion; each part mutated in turn.
    func testFuzzTextAndRecordings() throws {
        let session = SyntheticNote.session(attributed: { a in
            let ranges = [a.dict([("rangeKey", a.string("{0, 4}")), ("fontName", a.string("Times-Bold")), ("fontSize", .real(20)),
                                  ("color", a.string("#112233FF"))])]
            return a.dict([("stringKey", a.string("Head\nline 線形\n\nnext")), ("subRangesKey", a.array(ranges))])
        }, eventTokens: [0, 10, -1, 20])
        let ns = SyntheticNote.session(attributed: { a in
            let font = a.object("UIFont", [("NSName", a.string("Menlo")), ("NSSize", .real(9))])
            return a.object("NSAttributedString", [("NSString", a.string("abc def")),
                                                    ("NSAttributes", a.array([a.dict([("NSFont", font)])])),
                                                    ("NSAttributeInfo", a.data(Data([3, 0, 4, 0])))])
        })
        let library = AttachmentFixtures.library([("r", "<key>fileName</key><string>a.m4a</string><key>duration</key><real>5</real>")])
        let m4a = AttachmentFixtures.m4a(seconds: 5), caf = AttachmentFixtures.caf(seconds: 1)
        assertClean(Fuzz.run("text-recordings", seeds: [session, ns, library, m4a, caf], quick: 300, maxSize: 128 << 10) { input in
            Self.typed {
                _ = AudioContainer.read(input)
                let variants: [(Data, Data, Data)] = [(input, library, m4a), (session, input, m4a), (session, library, input)]
                for (s, l, audio) in variants {
                    let zip = AttachmentFixtures.package(session: s, extra: [("Recordings/library.plist", l), ("Recordings/a.m4a", audio)])
                    let pkg = try NotePackage(data: zip)
                    guard let note = try? NotabilityNote.parse(package: pkg) else { continue }
                    let a = NotabilityAttachments.resolve(note, package: pkg)
                    let state = NotabilityImporter.convert(note, attachments: a)
                    for item in state.pages[0].items where item.validationError != nil {
                        throw ImportError.package("invalid item: \(item.validationError ?? "")")
                    }
                    _ = try InkJSON.encoder().encode(NotabilityImporter.ops(for: state))
                }
            }
        })
    }
}
