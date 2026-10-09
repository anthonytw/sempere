import Age
import CZlib
import Foundation
import ImportTestSupport
import Sempere
import TempDirSupport
import XCTest
@testable import SempereImport
@testable import SempereNotability

/// A scratch directory, a fresh vault in it, and a one-file import.
class NotabilityTestCase: TempDirTestCase {
    func makeVault() throws -> Vault {
        let identity = try NativeIdentity.generate(.postQuantum)
        return try Vault.create(at: tmp.appendingPathComponent("V-\(UUID().uuidString).sempere"),
                                recipients: [identity.recipient], identities: [identity])
    }

    /// Writes `data` as a `.<ext>` file and imports it, expecting one note that imports cleanly.
    func importFile(_ data: Data, ext: String = "note", into vault: Vault, options: NotabilityImporter.Options = .init())
        throws -> (NotabilityImporter.NoteResult, NoteState) {
        let path = tmp.appendingPathComponent("N-\(UUID().uuidString).\(ext)")
        try data.write(to: path)
        var clock = HybridClock()
        let report = try NotabilityImporter.import(paths: [path], into: vault, device: DeviceID("0a0b0c0d")!,
                                                   clock: &clock, options: options)
        let r = try XCTUnwrap(report.notes.first)
        XCTAssertEqual(r.status, .ok, "\(r.status)")
        return (r, try vault.reconstruct(noteId: try XCTUnwrap(r.noteId)))
    }
}

// MARK: - Synthetic Notability note

/// Builds a small `.note` package shaped like Notability's (format version 9):
/// three pen curves (one dashed), one highlighter, dot paper, tags, and a
/// two-page handwriting index. Nothing in it comes from a real note.
enum SyntheticNote {
    static let uuid = "5A1E0000-0000-4000-8000-000000000001"
    static let created = Date(timeIntervalSinceReferenceDate: 700_000_000)
    static let width = 716.8
    static let pageHeight = 716.8 * 21 / 16
    /// The file name of the note's PDF under `PDFs/`.
    static let pdfName = "00000000-0000-4000-8000-0000000000AA.pdf"

    struct CurveSpec {
        var points: [(Float, Float)]
        var fw: [Float]
        var width: Float
        var rgba: [UInt8]
        var style: UInt8
    }

    static var curves: [CurveSpec] {
        [
            // One Bézier segment, a gentle arc on page 1.
            CurveSpec(points: [(100, 100), (110, 90), (130, 90), (140, 100)], fw: [0.5, 1.0],
                      width: 1.4, rgba: [0, 0, 0, 255], style: 3),
            // Two segments, blue.
            CurveSpec(points: [(100, 150), (105, 150), (115, 150), (120, 150), (125, 150), (135, 160), (140, 170)],
                      fw: [1, 0.75, 0.5], width: 1.867, rgba: [0x00, 0x6F, 0xFF, 0xFF], style: 3),
            // Highlighter across the first line.
            CurveSpec(points: [(95, 95), (110, 95), (130, 95), (145, 95)], fw: [1, 1],
                      width: 28, rgba: [0xFF, 0xFF, 0x00, 0x6B], style: 4),
            // On page 2, dashed.
            CurveSpec(points: [(200, Float(pageHeight) + 50), (210, Float(pageHeight) + 50),
                               (220, Float(pageHeight) + 50), (230, Float(pageHeight) + 50)],
                      fw: [1, 1], width: 1.4, rgba: [0xED, 0x36, 0x24, 0xFF], style: 3),
        ]
    }

    static func f32(_ v: [Float]) -> Data {
        var d = Data()
        for x in v { var b = x.bitPattern.littleEndian; d.append(Data(bytes: &b, count: 4)) }
        return d
    }

    static func i32(_ v: [Int32]) -> Data {
        var d = Data()
        for x in v { var b = x.littleEndian; d.append(Data(bytes: &b, count: 4)) }
        return d
    }

    static func half(_ x: Double) -> UInt16 {
        if x.isInfinite { return 0x7C00 }
        return Float16Bits.encode(x)
    }

    /// - Parameters:
    ///   - pdfPages: lay the note out on that many pages of one imported PDF
    ///     (`pdfFiles` + `pageLayoutArray`), as Notability does for a note
    ///     made from a PDF.
    ///   - paperSize: the `paperSize` attribute (`letter`, `custom:<w/h>`, …).
    ///   - styles: replaces `curvesstyles` (e.g. a short array).
    ///   - shapes: a `shapes` plist for the spatial hash.
    ///   - numcurvesOverride: a `numcurves` / `numpoints` value that disagrees
    ///     with the arrays (for corrupt-input tests).
    ///   - typed: the typed text (`attributedString.stringKey`).
    ///   - layout: replaces the `pageLayoutArray` built for `pdfPages`: per
    ///     Notability page its document page number, PDF file name (nil for a
    ///     paper page) and PDF page number.
    ///   - media: builds the `mediaObjects` entries.
    ///   - paperIdentifier: the `paperIdentifier` attribute (`TemplatePDF:<uuid>:#FFFFFF`, …).
    static func session(typed: String = "typed words", curves cs: [CurveSpec] = curves, pdfPages: Int = 0, paperSize: String = "letter",
                        styles: Data? = nil, shapes: Data? = nil, created: Date = created,
                        numcurvesOverride: Int? = nil, layout: [(Int, String?, Int)]? = nil,
                        media: ((inout KeyedArchiveBuilder) -> [BValue])? = nil,
                        paperIdentifier: String = "Legacy:13",
                        attributed: ((inout KeyedArchiveBuilder) -> BValue)? = nil,
                        eventTokens: [Int32]? = nil,
                        rootExtra: ((inout KeyedArchiveBuilder) -> [(String, BValue)])? = nil,
                        attrsExtra: ((inout KeyedArchiveBuilder) -> [(String, BValue)])? = nil) -> Data {
        var a = KeyedArchiveBuilder()
        let nodes = cs.map { $0.fw.count }.reduce(0, +)
        let totalPoints = cs.map { $0.points.count }.reduce(0, +)
        var unit: [Float] = []
        for _ in 0..<nodes { unit += [0, 1] }   // azimuth unit vector (0, 1): π/2
        let dash = BPlist.encode(.dict([("objectPatterns", .dict([("3", .dict([("pattern", .int(1))]))]))]))
        let hash = a.object("InkedSpatialHash", [
            ("numcurves", .int(Int64(numcurvesOverride ?? cs.count))),
            ("numpoints", .int(Int64(numcurvesOverride ?? totalPoints))),
            ("numfractionalwidths", .int(Int64(nodes))),
            ("curvesnumpoints", a.data(i32(cs.map { Int32($0.points.count) }))),
            ("curvespoints", a.data(f32(cs.flatMap { $0.points.flatMap { [$0.0, $0.1] } }))),
            ("curveswidth", a.data(f32(cs.map(\.width)))),
            ("curvesfractionalwidths", a.data(f32(cs.flatMap(\.fw)))),
            ("curvesforces", a.data(f32(Array(repeating: 1, count: nodes)))),
            ("curvesaltitudeangles", a.data(f32(Array(repeating: Float.pi / 2, count: nodes)))),
            ("curvesazimuthunitvector", a.data(f32(unit))),
            ("curvescolors", a.data(Data(cs.flatMap(\.rgba)))),
            ("curvesstyles", a.data(styles ?? Data(cs.map(\.style)))),
            ("curveUUIDs", a.data(Data(repeating: 0xAB, count: 16 * cs.count))),
            ("dashStyles", a.data(dash)),
            ("groupsArrays", a.array([])),
            ("bezierPathsDataDictionary", a.dict([])),
        ] + (shapes.map { [("shapes", a.data($0))] } ?? [])
          + (eventTokens.map { [("eventTokens", a.data(i32($0)))] } ?? []))
        let overlay = a.object("HandwritingObject", [("SpatialHash", hash)])
        let attributed = attributed.map { $0(&a) }
            ?? a.dict([("stringKey", a.string(typed)), ("subRangesKey", a.array([]))])
        let reflow = a.object("NBReflowStateLocked", [("pageWidthInDocumentCoordsKey", .real(width)),
                                                     ("nativeLayoutDeviceStringKey", a.string("iPad"))])
        var pdfFiles: [BValue] = [], pageLayout: [BValue] = []
        if pdfPages > 0 || layout != nil {
            let name = pdfName
            let file = a.object("PDFFile", [("pdfFileName", a.string(name)), ("contentBoxVersion", .int(1)),
                                            ("highlights", a.array([])), ("type", .int(0)), ("version", .int(2))])
            pdfFiles = [file]
            let entries = layout ?? (1...max(pdfPages, 1)).map { ($0, name, $0) }
            pageLayout = entries.map { doc, fileName, page in
                var fields: [(String, BValue)] = [("kPageLayoutDocumentPageNumberKey", .int(Int64(doc))),
                                                  ("kPageLayoutPageIsBookmarkedKey", .bool(false))]
                if let fileName {
                    fields += [("kPageLayoutPDFFileNameKey", a.string(fileName)), ("kPageLayoutPDFIsOriginalPageKey", .bool(true)),
                               ("kPageLayoutPDFPageNumberKey", .int(Int64(page))), ("kPageLayoutPDFFileKey", file)]
                }
                return a.dict(fields)
            }
        }
        let mediaObjects = media.map { $0(&a) } ?? []
        let rich = a.object("FormattedString", [
            ("attributedString", attributed), ("Handwriting Overlay", overlay), ("reflowState", reflow),
            ("pdfFiles", a.array(pdfFiles)), ("mediaObjects", a.array(mediaObjects)),
            ("pageLayoutArray", a.array(pageLayout)),
        ])
        let attrs = a.object("GLModel.PaperAttributes", [
            ("paperIdentifier", a.string(paperIdentifier)), ("paperSize", a.string(paperSize)),
            ("paperOrientation", a.string("portrait")),
            ("paperSizingBehavior", a.string("lockedWidth:716.8:iPad")),
            ("lineStyle2", a.string("Dots:false:true:0.25")),
        ] + (attrsExtra.map { $0(&a) } ?? []))
        let layout = a.object("Notability.NoteDocumentPaperLayoutModel", [("documentPaperAttributes", attrs)])
        let root = a.object("NoteTakingSession", [
            ("name", a.object("NSMutableData", [("NS.data", .data(Data("Synthetic note".utf8)))])),
            ("subject", a.string("unsortedNotesKey")),
            ("tags", a.string("")),
            ("creationDate", a.date(created)),
            ("sessionFormatVersion", .int(9)),
            ("NBNoteTakingSessionBundleVersionNumberKey", a.string("14.2.6")),
            ("NBNoteTakingSessionDocumentPaperLayoutModelKey", layout),
            ("richText", rich),
        ] + (rootExtra.map { $0(&a) } ?? []))
        return a.archive(top: [("$0", root)])
    }

    static func metadata(subject: String = "Fixtures", tags: String = "alpha, beta", uuid: String = uuid,
                         created: Date = created, modified: Date? = nil) -> Data {
        var b = KeyedArchiveBuilder()
        let d = b.dict([
            ("noteName", b.string("Synthetic note")),
            ("noteSubject", b.string(subject)),
            ("noteTags", b.string(tags)),
            ("noteCreationDateKey", b.date(created)),
            ("noteModifiedDateKey", b.date(modified ?? created.addingTimeInterval(60))),
            ("uuidKey", b.string(uuid)),
            ("notePackagePath", b.string("Synthetic note")),
        ])
        return b.archive(top: [("root", d)])
    }

    /// Two recognised pages. Page 1: "ab cd" over the first curve; page 2: "x".
    static func handwritingIndex() -> Data {
        func rects(_ boxes: [(Double, Double, Double, Double)?]) -> Data {
            var d = Data()
            for b in boxes {
                let v = b.map { [$0.0, $0.1, $0.2, $0.3] } ?? [.infinity, .infinity, 0, 0]
                for x in v { let h = half(x); d.append(contentsOf: [UInt8(h & 0xFF), UInt8(h >> 8)]) }
            }
            return d
        }
        let page1 = BValue.dict([
            ("text", .string("ab cd")),
            ("pageContentOrigin", .array([.real(99), .real(89)])),
            ("characterRects", .data(rects([(0, 0, 10, 12), (10, 1, 10, 11), nil, (25, 0, 8, 12), (33, 2, 8, 10)]))),
            ("sha256Hash", .data(Data(repeating: 0, count: 32))),
        ])
        let page2 = BValue.dict([
            ("text", .string("x")),
            ("pageContentOrigin", .array([.real(199), .real(49)])),
            ("characterRects", .data(rects([(0, 0, 32, 2)]))),
        ])
        return BPlist.encode(.dict([("version", .int(7)), ("minCompatibleVersion", .int(7)),
                                    ("pages", .dict([("1", page1), ("2", page2)]))]))
    }

    static func png(width: Int, height: Int) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        for v in [width, height] { d.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        d.append(contentsOf: [8, 6, 0, 0, 0, 0, 0, 0, 0])
        return d
    }

    /// The package's files (path inside the package, bytes).
    /// - Parameters:
    ///   - thumbnails: `(name, width, height)` of the thumbnails to include.
    ///   - handwriting: include the two-page handwriting index.
    static func files(curves cs: [CurveSpec] = curves, subject: String = "Fixtures",
                      tags: String = "alpha, beta", pdfPages: Int = 0,
                      thumbnails: [(String, Int, Int)] = [("thumb.png", 48, 63)],
                      handwriting: Bool = true, paperSize: String = "letter", uuid: String = uuid,
                      created: Date = created, modified: Date? = nil, styles: Data? = nil,
                      shapes: Data? = nil) -> [(String, Data)] {
        let dir = "Synthetic note/"
        // Notability writes this one file as an XML plist (the rest are binary).
        let library = recordingsLibrary()
        var out = [
            (dir + "Session.plist", session(curves: cs, pdfPages: pdfPages, paperSize: paperSize, styles: styles,
                                            shapes: shapes, created: created)),
            (dir + "metadata.plist", metadata(subject: subject, tags: tags, uuid: uuid, created: created,
                                              modified: modified)),
            (dir + "Recordings/library.plist", library),
        ]
        if handwriting { out.append((dir + "HandwritingIndex/index.plist", handwritingIndex())) }
        if pdfPages > 0 { out.append((dir + "PDFs/00000000-0000-4000-8000-0000000000AA.pdf", Data("%PDF-1.4\n".utf8))) }
        for (name, w, h) in thumbnails { out.append((dir + name, png(width: w, height: h))) }
        return out
    }

    /// `Recordings/library.plist` as Notability writes it: an XML plist with
    /// Apple's DOCTYPE and a `recordings` dictionary.
    static func recordingsLibrary(recordings: Int = 0) -> Data {
        let entries = (0..<recordings).map { "\t\t<key>rec-\($0)</key>\n\t\t<dict/>\n" }.joined()
        let dict = recordings == 0 ? "\t<dict/>\n" : "\t<dict>\n\(entries)\t</dict>\n"
        return Data(("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>application version</key>
            \t<string>1</string>
            \t<key>library-format-version</key>
            \t<string>1.0</string>
            \t<key>recordings</key>

            """ + dict + "</dict>\n</plist>\n").utf8)
    }

    /// The `.note` package bytes.
    static func package(curves cs: [CurveSpec] = curves, subject: String = "Fixtures",
                        tags: String = "alpha, beta", pdfPages: Int = 0,
                        thumbnails: [(String, Int, Int)] = [("thumb.png", 48, 63)],
                        handwriting: Bool = true, paperSize: String = "letter", uuid: String = uuid,
                        created: Date = created, modified: Date? = nil, styles: Data? = nil,
                        shapes: Data? = nil) -> Data {
        TestZip.write([.init(path: "Synthetic note/", data: Data(), deflate: false)]
            + files(curves: cs, subject: subject, tags: tags, pdfPages: pdfPages, thumbnails: thumbnails,
                    handwriting: handwriting, paperSize: paperSize, uuid: uuid, created: created, modified: modified,
                    styles: styles, shapes: shapes)
                .map { .init(path: $0.0, data: $0.1, deflate: !$0.0.hasSuffix(".png")) })
    }

    /// Writes the package unzipped, as a `.note` directory.
    static func writeDirectory(_ url: URL) throws {
        for (path, data) in files() {
            let f = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: f)
        }
    }
}

/// IEEE binary16 encoding for finite values (round to nearest).
enum Float16Bits {
    static func encode(_ x: Double) -> UInt16 {
        let f = Float(x)
        let bits = f.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exp = Int((bits >> 23) & 0xFF) - 127 + 15
        let mant = bits & 0x7F_FFFF
        if f == 0 { return sign }
        if exp <= 0 { return sign }   // flush tiny values (unused by fixtures)
        if exp >= 31 { return sign | 0x7C00 }
        let m = UInt16((mant + 0x1000) >> 13)
        return sign | UInt16(exp) << 10 &+ m
    }
}
