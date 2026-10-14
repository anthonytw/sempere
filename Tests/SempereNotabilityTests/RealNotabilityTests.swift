import Age
import Foundation
import ImportTestSupport
import SempereRender
import Sempere
import XCTest
@testable import SempereImport
@testable import SempereNotability

/// Tests against a real Notability backup. Skipped unless
/// `SEMPERE_NOTABILITY_SAMPLES` names a backup zip (or a directory of
/// `.note` files), or several separated by `:` (a backup Drive split into
/// parts); CI never has personal data.
///
/// - `SEMPERE_NOTABILITY_RENDER_DIR`: also write each rendered first page
///   and its Notability thumbnail there as PNGs, for eyeballing.
/// - `SEMPERE_NOTABILITY_ONLY`: render only notes whose path contains this
///   text, including notes on PDFs, without asserting (for eyeballing).
/// - `SEMPERE_NOTABILITY_BULK_VAULT`: `testBulkImport` imports every note
///   into a fresh vault at that path (must not exist) and prints a report.
final class RealNotabilityTests: XCTestCase {
    static var samples: [URL]? {
        ProcessInfo.processInfo.environment["SEMPERE_NOTABILITY_SAMPLES"].map {
            $0.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
    }

    /// Every `.note` and `.ntb` source in the samples.
    func allSources() throws -> [NotabilityImporter.Source] {
        guard let urls = Self.samples else { throw XCTSkip("SEMPERE_NOTABILITY_SAMPLES not set") }
        return try urls.flatMap { try NotabilityImporter.sources($0) }
    }

    /// (label, package) of every `.note` in the samples.
    func allNotes() throws -> [(String, NotePackage)] {
        try allSources().filter { $0.format == .note }.map { ($0.label, try $0.load()) }
    }

    /// Every `.ntb` that has a `.note` of the same note (same creation time)
    /// holds the same strokes: each bundle stroke matches a `.note` curve
    /// (same point count and colour) point for point, within half-float
    /// precision, after the bundle's page offset and margin are undone.
    func testBundlesMatchTheirNotes() throws {
        let sources = try allSources()
        var notesByCreated: [Int64: NotabilityNote] = [:]
        func ms(_ d: Date?) -> Int64? { d.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } }
        var bundles: [NotabilityNote] = []
        for s in sources {
            autoreleasing {
                guard let note = try? s.parse(), let c = ms(note.metadata.created) else { return }
                if s.format == .ntb { bundles.append(note) } else { notesByCreated[c] = note }
            }
        }
        var pairs = 0, strokes = 0, matched = 0, clamped = 0, notesFullyMatched = 0
        var errors: [Double] = []
        for b in bundles {
            guard let c = ms(b.metadata.created), let note = notesByCreated[c] else { continue }
            pairs += 1
            var byKey: [String: [NotabilityNote.Curve]] = [:]
            func key(_ c: NotabilityNote.Curve, _ cell: Int) -> String { "\(c.points.count)-\(c.color)-\(cell)" }
            func cell(_ c: NotabilityNote.Curve) -> Int { Int((c.points[0].x / 2).rounded(.down)) }
            for curve in note.curves where !curve.points.isEmpty {
                byKey[key(curve, cell(curve)), default: []].append(curve)
            }
            var unmatched = 0
            for curve in b.curves {
                strokes += 1
                if curve.originClamped { clamped += 1; continue }
                // Shape relative to the first point, plus the first point's x
                // (y differs by the page stride on notes on PDF pages).
                let candidates = ((cell(curve) - 1)...(cell(curve) + 1)).flatMap { byKey[key(curve, $0)] ?? [] }
                let best = candidates.map { other -> Double in
                    var e = abs(other.points[0].x - curve.points[0].x)
                    for (p, q) in zip(curve.points, other.points) {
                        e = max(e, abs((p.x - curve.points[0].x) - (q.x - other.points[0].x)),
                                abs((p.y - curve.points[0].y) - (q.y - other.points[0].y)))
                    }
                    return e
                }.min()
                if let best, best < 1 { matched += 1; errors.append(best) } else { unmatched += 1 }
            }
            if unmatched == 0 { notesFullyMatched += 1 }
        }
        errors.sort()
        func q(_ f: Double) -> Double { errors.isEmpty ? .nan : errors[min(errors.count - 1, Int(Double(errors.count) * f))] }
        print("NTB: \(bundles.count) bundles, \(pairs) with a .note; strokes \(strokes), matched \(matched), "
              + "clamped origin \(clamped); bundles fully matched \(notesFullyMatched); point error p50 \(q(0.5)) "
              + "p99 \(q(0.99)) p99.9 \(q(0.999)) max \(errors.last ?? .nan)")
        XCTAssertGreaterThan(pairs, 0)
        XCTAssertGreaterThanOrEqual(Double(matched), 0.99 * Double(strokes - clamped))
        XCTAssertLessThan(q(0.999), 0.25)
    }

    /// Every note parses and converts; the mapping is self-consistent.
    func testEveryNoteParsesAndConverts() throws {
        var curves = 0, failures: [String] = []
        for (label, pkg) in try allNotes() {
            do {
                let note = try NotabilityNote.parse(package: pkg)
                let state = NotabilityImporter.convert(note)
                XCTAssertEqual(state.pages.count, 1)
                XCTAssertEqual(state.pages[0].strokes.count, note.curves.count, label)
                XCTAssertGreaterThan(note.paper.width, 0)
                curves += note.curves.count
            } catch {
                failures.append("\(label): \(error)")
            }
        }
        XCTAssertEqual(failures, [])
        print("parsed curves: \(curves)")
    }

    /// Every recognised page's `pageContentOrigin`, moved down by the page's
    /// offset (`(n - 1) × pageHeight`), lands on the top-left of the ink on
    /// that page (with a small allowance, below). This checks the page geometry of every note with
    /// recognition, including notes on PDF pages (whose stride is not the
    /// paper's), which the thumbnail comparison skips.
    func testRecognitionOriginsMatchInkOnEveryPage() throws {
        var checked = 0, pdfChecked = 0, misses: [String] = []
        for (index, (_, pkg)) in try allNotes().enumerated() {
            let note = try NotabilityNote.parse(package: pkg)
            let h = note.paper.pageHeight
            let points = note.curves.flatMap(\.points)
            for (n, page) in note.recognition.sorted(by: { $0.key < $1.key }) where !page.characterBoxes.isEmpty {
                // The origin is the top-left of the page's ink less about 0.7
                // units: some ink touches its top edge and some its left edge.
                let x0 = page.origin.x + 0.7, y0 = Double(n - 1) * h + page.origin.y + 0.7
                let tol = 3.0   // stroke widths and control points blur the edges
                let topEdge = points.contains { abs($0.y - y0) < tol && $0.x > x0 - tol }
                let leftEdge = points.contains { abs($0.x - x0) < tol && $0.y > y0 - tol && $0.y < Double(n) * h }
                checked += 1
                if note.pdfPageCount > 0 { pdfChecked += 1 }
                if !topEdge || !leftEdge {
                    misses.append("note #\(index) page \(n): top edge \(topEdge), left edge \(leftEdge)")
                }
            }
        }
        print("recognition origins checked: \(checked) pages (\(pdfChecked) on PDF notes), \(misses.count) off")
        // The 130-note sample had none off. The full 2026-10 backup has about
        // 2.5 % off (59 of 2315 pages, after the stride fix): notes on PDFs
        // with inserted paper pages (pages of two heights, one stride assumed)
        // and recognition indexes Notability did not refresh after edits.
        XCTAssertLessThanOrEqual(misses.count * 25, checked, "\(misses)")
        XCTAssertGreaterThan(pdfChecked, 0, "no PDF note with recognition in the samples")
    }

    /// Notes that import with no strokes really have no ink: no curves and
    /// no recognised handwriting, except a recognition index Notability left
    /// behind after all the ink was erased (its `.ntb` has no strokes either),
    /// which is counted. An index with no pages is not ink.
    func testNotesWithoutCurvesAreInkless() throws {
        var pdfOnly = 0, blank = 0, inked = 0, staleIndex = 0
        for (_, pkg) in try allNotes() {
            let note = try NotabilityNote.parse(package: pkg)
            guard note.curves.isEmpty else { inked += 1; continue }
            if !note.recognition.isEmpty { staleIndex += 1 }
            if note.pdfPageCount > 0 { pdfOnly += 1 } else { blank += 1 }
        }
        print("notes with ink: \(inked); without: \(pdfOnly) PDF-only, \(blank) blank; "
              + "\(staleIndex) with recognised text but no ink")
        XCTAssertLessThanOrEqual(staleIndex, 2)
    }

    #if os(macOS)
    /// Renders the first Notability page of real notes and compares it with
    /// Notability's own thumbnail: same aspect ratio, and the ink's bounding
    /// box in the same place.
    func testRenderedFirstPageMatchesThumbnail() throws {
        let renderDir = ProcessInfo.processInfo.environment["SEMPERE_NOTABILITY_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inkimport-fid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let renderDir { try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true) }

        let only = ProcessInfo.processInfo.environment["SEMPERE_NOTABILITY_ONLY"]
        var checked = 0, index = 0
        for (label, pkg) in try allNotes() {
            if let only, !label.contains(only) { continue }
            guard let thumbPath = pkg.paths.first(where: { $0.hasSuffix("/thumb12x.png") }) else { continue }
            let note = try NotabilityNote.parse(package: pkg)
            // Notes on imported PDFs show the PDF in the thumbnail; skip them.
            guard only != nil || (note.pdfCount == 0 && note.curves.count >= 50 && note.mediaCount == 0) else { continue }
            let state = NotabilityImporter.convert(note)
            // The page's breakHeight paginates it like Notability.
            let pdf = try PDFWriter.render(note: state)
            index += 1
            let name = "n\(index)"
            let pdfURL = tmp.appendingPathComponent("\(name).pdf")
            try pdf.write(to: pdfURL)
            let thumbURL = tmp.appendingPathComponent("\(name)-thumb.png")
            try pkg.read(thumbPath).write(to: thumbURL)
            let rendered = try bitmap(pdfURL, tmp.appendingPathComponent("\(name).bmp"))
            let thumb = try bitmap(thumbURL, tmp.appendingPathComponent("\(name)-thumb.bmp"))
            // Some thumbnails are stale and show blank paper: nothing to compare.
            guard let tb = thumb.inkBox() ?? (only != nil ? (0, 0, 1, 1) : nil) else { continue }
            if let renderDir {
                try sips(pdfURL, "png", renderDir.appendingPathComponent("\(name)-sempere.png"))
                try FileManager.default.copyItem(at: thumbURL, to: renderDir.appendingPathComponent("\(name)-notability.png"))
                print("\(name): \(label)")
            }

            if only != nil { checked += 1; continue }
            let ra = Double(rendered.height) / Double(rendered.width)
            let ta = Double(thumb.height) / Double(thumb.width)
            XCTAssertEqual(ra, ta, accuracy: 0.01, "aspect \(label)")
            let rb = try XCTUnwrap(rendered.inkBox(), label)
            for (a, b, what) in [(rb.0, tb.0, "left"), (rb.1, tb.1, "top"), (rb.2, tb.2, "right"), (rb.3, tb.3, "bottom")] {
                XCTAssertEqual(a, b, accuracy: 0.02, "\(what) edge of ink, \(label)")
            }
            print(String(format: "%@: aspect %.4f vs %.4f; ink box %.3f %.3f %.3f %.3f vs %.3f %.3f %.3f %.3f", name, ra, ta,
                         rb.0, rb.1, rb.2, rb.3, tb.0, tb.1, tb.2, tb.3))
            checked += 1
            if checked >= 8, ProcessInfo.processInfo.environment["SEMPERE_FIDELITY_ALL"] == nil { break }
        }
        XCTAssertGreaterThanOrEqual(checked, only == nil ? 5 : 1, "not enough real notes with ink and thumbnails")
    }

    struct Bitmap {
        var width: Int, height: Int
        var pixels: [UInt8]   // RGBA, top-down

        /// Bounding box of dark (ink) pixels, as fractions of width/height.
        func inkBox() -> (Double, Double, Double, Double)? {
            var x0 = width, y0 = height, x1 = -1, y1 = -1
            for y in 0..<height {
                for x in 0..<width {
                    let i = 4 * (y * width + x)
                    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                    let lum = 0.3 * Double(r) + 0.59 * Double(g) + 0.11 * Double(b)
                    // Dark ink, or grey (thin, antialiased) ink; not the bluish paper pattern.
                    let grey = max(r, g, b) - min(r, g, b) < 16
                    guard pixels[i + 3] > 128, lum < 110 || (grey && lum < 200) else { continue }
                    x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
                }
            }
            guard x1 >= 0 else { return nil }
            return (Double(x0) / Double(width), Double(y0) / Double(height),
                    Double(x1 + 1) / Double(width), Double(y1 + 1) / Double(height))
        }
    }

    func sips(_ input: URL, _ format: String, _ output: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-s", "format", format, input.path, "--out", output.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ImportError.io("sips failed on \(input.lastPathComponent)") }
    }

    /// Converts with `sips` to BMP and decodes it.
    func bitmap(_ input: URL, _ bmp: URL) throws -> Bitmap {
        try sips(input, "bmp", bmp)
        let d = try Data(contentsOf: bmp)
        func u32(_ i: Int) -> Int { Int(d.u32(i)) }
        let offset = u32(10), width = u32(18)
        let rawHeight = Int32(bitPattern: d.u32(22))
        let bpp = Int(d.u16(28))
        let height = Int(abs(rawHeight))
        let stride = (width * bpp / 8 + 3) / 4 * 4
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = rawHeight > 0 ? height - 1 - y : y
            for x in 0..<width {
                let s = d.startIndex + offset + row * stride + x * bpp / 8
                let o = 4 * (y * width + x)
                px[o] = d[s + 2]; px[o + 1] = d[s + 1]; px[o + 2] = d[s]
                px[o + 3] = bpp == 32 ? d[s + 3] : 255
            }
        }
        return Bitmap(width: width, height: height, pixels: px)
    }
    #endif

    /// Imports everything into a fresh vault and prints the report.
    func testBulkImport() throws {
        guard let target = ProcessInfo.processInfo.environment["SEMPERE_NOTABILITY_BULK_VAULT"] else {
            throw XCTSkip("SEMPERE_NOTABILITY_BULK_VAULT not set")
        }
        guard let samples = Self.samples else { throw XCTSkip("SEMPERE_NOTABILITY_SAMPLES not set") }
        let identity = try NativeIdentity.generate(.postQuantum)
        let vault = try Vault.create(at: URL(fileURLWithPath: target), recipients: [identity.recipient],
                                     identities: [identity])
        var clock = HybridClock()
        let started = Date()
        let report = try NotabilityImporter.import(paths: samples, into: vault, device: DeviceID("1a2b3c4d")!,
                                                   clock: &clock)
        let elapsed = Date().timeIntervalSince(started)
        for n in report.notes where n.status != .ok {
            print("NOT OK \(n.status) \(n.source)")
        }
        let slowest = report.notes.max { $0.seconds < $1.seconds }
        var dropped = NotabilityImporter.Dropped()
        for n in report.notes {
            dropped.typedTextCharacters += n.dropped.typedTextCharacters; dropped.pdfs += n.dropped.pdfs
            dropped.pdfPages += n.dropped.pdfPages
            dropped.media += n.dropped.media; dropped.recordings += n.dropped.recordings
            dropped.dashedStrokes += n.dropped.dashedStrokes; dropped.unknownStyleStrokes += n.dropped.unknownStyleStrokes
            dropped.pdfHighlights += n.dropped.pdfHighlights; dropped.templatePDFs += n.dropped.templatePDFs
        }
        // Attachments (D1, D2): totals, and every warning with its numbers and
        // names folded so that equal causes group (no note content in them).
        var attached = NotabilityImporter.ImportedAttachments()
        var causes: [String: Int] = [:]
        for n in report.notes where n.status == .ok {
            let a = n.attachments
            attached.pdfs += a.pdfs; attached.pdfPages += a.pdfPages; attached.templatePages += a.templatePages
            attached.images += a.images; attached.blobs += a.blobs; attached.blobBytes += a.blobBytes
            for w in n.warnings {
                let folded = w.replacingOccurrences(of: "[0-9A-Fa-f-]{36}(\\.pdf)?", with: "<uuid>", options: .regularExpression)
                    .replacingOccurrences(of: "[0-9]+(\\.[0-9]+)?", with: "N", options: .regularExpression)
                causes[folded, default: 0] += 1
            }
        }
        print("BULK: attachments \(attached)")
        for (cause, count) in causes.sorted(by: { $0.value > $1.value }) { print("BULK: warning ×\(count): \(cause)") }
        // D1's acceptance: every PDF page of a .note imports.
        let pdfMissing = report.notes.filter { $0.status == .ok && $0.format == .note && $0.dropped.pdfPages > 0 }
        for n in pdfMissing { print("BULK: PDF pages not imported: \(n.dropped.pdfPages) in \(n.source)") }
        XCTAssertEqual(pdfMissing.count, 0, "notes whose PDF pages did not import")
        print("""
        BULK: notes \(report.notes.count) ok \(report.imported) skipped \(report.skipped) failed \(report.failed)
        BULK: notes without strokes \(report.notes.filter { $0.status == .ok && $0.strokes == 0 }.count) \
        (\(report.notes.filter { $0.status == .ok && $0.strokes == 0 && $0.dropped.pdfPages > 0 }.count) on PDF pages)
        BULK: strokes \(report.strokes) recognised pages \(report.notes.reduce(0) { $0 + $1.recognizedPages })
        BULK: wall \(String(format: "%.1f", elapsed)) s; slowest \(String(format: "%.2f", slowest?.seconds ?? 0)) s \(slowest?.source ?? "")
        BULK: dropped \(dropped)
        """)
        // Every written note reconstructs.
        for n in report.notes where n.status == .ok {
            guard let id = n.noteId else { XCTFail("no id for \(n.source)"); continue }
            let state = try vault.reconstruct(noteId: id)
            XCTAssertEqual(state.pages.first?.strokes.count, n.strokes, n.source)
        }
        // A second run skips everything.
        let again = try NotabilityImporter.import(paths: samples, into: vault, device: DeviceID("1a2b3c4d")!,
                                                  clock: &clock)
        XCTAssertEqual(again.imported, 0)
    }
}
