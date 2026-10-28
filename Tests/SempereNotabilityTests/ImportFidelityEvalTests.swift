import Age
import Foundation
import ImportTestSupport
import SempereRender
import VaultTestSupport
import Sempere
import XCTest
@testable import SempereImport
@testable import SempereNotability

/// Stage 1 of the import fidelity evaluation (`docs/import-notability.md`,
/// "Fidelity evaluation"; driven by `scripts/import-eval.sh`). Skipped unless
/// both `SEMPERE_NOTABILITY_SAMPLES` (a backup zip or directory of `.note`
/// files, or several separated by `:`) and `SEMPERE_EVAL_DIR` (a scratch
/// directory, emptied first) are set; CI never has personal data.
///
/// Imports every note into a fresh scratch vault `<dir>/vault.sempere`
/// (identity `<dir>/identity.key`), then for every imported note writes
/// `<dir>/oracle/<id8>/`, where `id8` is the first 8 hex digits of the vault
/// note id (itself a hash of Notability's uuid, so nothing names the note):
///
/// - `thumb*.png`: Notability's thumbnails, unchanged;
/// - `ours-<thumb>.png`: the first Notability page of the note as stored in
///   the vault, rendered by `PNGWriter` without paper (transparent) at the
///   thumbnail's width (page width 612 pt → thumbnail width), cropped to one
///   `breakHeight`;
/// - `page1.pdf` (+ `pdfPage` in the JSON): the PDF the first page sits on;
/// - when the backup holds Notability's own PDF export of the note (a `.pdf`
///   next to the `.note`): `notability.pdf`, `ours-page-NNN.png` for every
///   export page (one `breakHeight` each, `evalScale` px/pt, no paper), and
///   for notes made from a PDF the PDFs the pages sit on (`src-K.pdf`) with
///   the PDF page of every Notability page (`pdfLayout` in the JSON);
/// - `meta.json`: counts and geometry, no titles or text.
///
/// `<dir>/import.json` holds the aggregate import report.
final class ImportFidelityEvalTests: XCTestCase {
    func testExportEvaluationInputs() throws {
        let env = ProcessInfo.processInfo.environment
        guard let samples = env["SEMPERE_NOTABILITY_SAMPLES"].map({
                  $0.split(separator: ":").map { URL(fileURLWithPath: String($0)) } }),
              let dir = env["SEMPERE_EVAL_DIR"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("SEMPERE_NOTABILITY_SAMPLES and SEMPERE_EVAL_DIR not set")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.appendingPathComponent("oracle"), withIntermediateDirectories: true)

        let identity = try NativeIdentity.generate(.postQuantum)
        try (identity.string + "\n").write(to: dir.appendingPathComponent("identity.key"), atomically: true,
                                           encoding: .utf8)
        let vault = try TestVaults.create(at: dir.appendingPathComponent("vault.sempere"), identities: [identity])
        var clock = HybridClock()
        let report = try NotabilityImporter.import(paths: samples, into: vault, device: DeviceID("e0a1e0a1")!,
                                                   clock: &clock)
        let sources = Dictionary(try samples.flatMap { try NotabilityImporter.sources($0) }.map { ($0.label, $0) },
                                 uniquingKeysWith: { a, _ in a })
        let companions = try CompanionPDFs(samples)
        var reasons: [String: Int] = [:]
        for n in report.notes {
            switch n.status {
            case .ok: reasons[n.extraVersion ? "imported: separate version" : "imported: \(n.format.rawValue)", default: 0] += 1
            case .skipped(let why): reasons["skipped: " + (why.split(separator: ":").first.map(String.init) ?? why), default: 0] += 1
            case .failed: reasons["failed", default: 0] += 1
            }
        }
        let summary: [String: Any] = [
            "notes": report.notes.count, "imported": report.imported, "skipped": report.skipped,
            "failed": report.failed, "strokes": report.strokes, "inputs": samples.count,
            "ntb": report.notes.filter { $0.format == .ntb }.count,
            "extraVersions": report.notes.filter(\.extraVersion).count, "outcomes": reasons,
            "withNotabilityPDF": report.notes.filter { $0.status == .ok && companions.has($0.source) }.count,
        ]
        try json(summary).write(to: dir.appendingPathComponent("import.json"))

        var written = 0
        for result in report.notes where result.status == .ok {
            guard let id = result.noteId, let source = sources[result.source] else {
                XCTFail("imported note without id or source"); continue
            }
            let error: Error? = autoreleasing {
                do {
                let id8 = String(id.uuidString.lowercased().prefix(8))
                let out = dir.appendingPathComponent("oracle").appendingPathComponent(id8)
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                let pkg = try source.load()
                let note = try source.parse()
                let state = try vault.reconstruct(noteId: id)
                try export(note: note, package: pkg, state: state, id: id, to: out)
                if let pdf = try companions.read(result.source) {
                    try exportPages(note: note, package: pkg, state: state, notabilityPDF: pdf, to: out)
                }
                return nil
                } catch { return error }
            }
            if let error { throw error }
            written += 1
        }
        XCTAssertEqual(written, report.imported)
        print("EVAL: exported \(written) notes to \(dir.path)")
    }

    /// Writes one note's thumbnails, first-page renders, PDF and metadata.
    func export(note: NotabilityNote, package pkg: NotePackage, state: NoteState, id: UUID, to out: URL) throws {
        let state = Self.inkOnly(state)
        let size = state.meta.pageSize
        let breakHeight = size.breakHeight ?? size.width * 21 / 16
        let strokes = state.pages.flatMap(\.strokes)

        var thumbs: [[String: Any]] = []
        let names = pkg.paths.filter { p in
            let base = p.split(separator: "/").last.map(String.init) ?? p
            return base.hasPrefix("thumb") && base.hasSuffix(".png") && p.split(separator: "/").count <= 2
        }
        for path in names.sorted() {
            let base = String(path.split(separator: "/").last ?? "")
            let data = try pkg.read(path)
            guard let (w, h) = NotabilityNote.pngSize(data), w > 0 else { continue }
            try data.write(to: out.appendingPathComponent(base))
            // Our first page at the thumbnail's width: a finite page one break tall.
            var meta = state.meta
            meta.pageSize = PageSize(width: size.width, height: breakHeight, infinite: false)
            let scale = Double(w) / size.width
            var pngs: [Data] = []
            for page in state.pages {
                pngs += try PNGWriter.render(page: page, meta: meta, options: RenderOptions(paper: false),
                                             png: PNGOptions(scale: scale))
            }
            if let first = pngs.first { try first.write(to: out.appendingPathComponent("ours-" + base)) }
            thumbs.append(["name": base, "width": w, "height": h])
        }

        var pdf: [String: Any]?
        if let (file, page) = try firstPDFPage(pkg),
           let path = pkg.paths.first(where: { $0.hasSuffix("/PDFs/" + file) || $0.hasSuffix("PDFs/" + file) }) {
            try pkg.read(path).write(to: out.appendingPathComponent("page1.pdf"))
            pdf = ["page": page]
        }

        var lo = (x: Double.infinity, y: Double.infinity), hi = (x: -Double.infinity, y: -Double.infinity)
        for s in strokes {
            for p in s.points {
                lo = (min(lo.x, p.x), min(lo.y, p.y)); hi = (max(hi.x, p.x), max(hi.y, p.y))
            }
        }
        let colors = Set(strokes.map { s in String(format: "%02x%02x%02x", s.ink.color.r, s.ink.color.g, s.ink.color.b) })
        let dropped = NotabilityImporter.dropped(note)
        var meta: [String: Any] = [
            "id": id.uuidString.lowercased(),
            "strokes": strokes.count,
            "markers": strokes.filter { $0.ink.tool == .marker }.count,
            "strokesOnPage1": strokes.filter { s in s.points.contains { $0.y < breakHeight } }.count,
            "dashed": dropped.dashedStrokes,
            "unknownStyle": dropped.unknownStyleStrokes,
            "pdfs": note.pdfCount, "pdfPages": note.pdfPageCount,
            "media": note.mediaCount, "recordings": note.recordingCount,
            "typedChars": dropped.typedTextCharacters,
            "formatVersion": note.formatVersion ?? 0,
            "documentWidth": note.paper.width, "documentPageHeight": note.paper.pageHeight,
            "sizingBehavior": note.paper.sizingBehavior ?? "", "paperSize": note.paper.size ?? "",
            "paperKind": state.meta.paper.kind.rawValue, "paperIdentifier": note.paper.identifier ?? "",
            "pageWidth": size.width, "pageHeight": size.height, "breakHeight": breakHeight,
            "bands": max(Int((size.height / breakHeight).rounded(.up)), 1),
            "colors": colors.sorted(),
            "thumbs": thumbs,
        ]
        if strokes.contains(where: { !$0.points.isEmpty }) {
            meta["inkBounds"] = [lo.x, lo.y, hi.x, hi.y]
        }
        if let pdf { meta["pdf"] = pdf }
        try json(meta).write(to: out.appendingPathComponent("meta.json"))
    }

    /// The note without its items: the evaluation compares ink, and composites
    /// the source PDF page itself (rendered without the note's blobs, a
    /// background would be a placeholder with diagonals that reads as ink).
    static func inkOnly(_ state: NoteState) -> NoteState {
        var s = state
        for i in s.pages.indices { s.pages[i].items = [] }
        return s
    }

    /// Pixels per point of the full-page renders compared with Notability's PDF export.
    static let evalScale = 1.5

    /// Every export page of the note at `evalScale` (no paper, transparent),
    /// Notability's own PDF of it, and for a note on PDF pages the source
    /// PDFs and the PDF page under each Notability page.
    func exportPages(note: NotabilityNote, package pkg: NotePackage, state: NoteState, notabilityPDF: Data,
                     to out: URL) throws {
        let state = Self.inkOnly(state)
        try notabilityPDF.write(to: out.appendingPathComponent("notability.pdf"))
        var count = 0
        for page in state.pages {
            let pngs = try PNGWriter.render(page: page, meta: state.meta, options: RenderOptions(paper: false),
                                            png: PNGOptions(scale: Self.evalScale))
            for png in pngs {
                count += 1
                try png.write(to: out.appendingPathComponent(String(format: "ours-page-%03d.png", count)))
            }
        }
        var files: [String: Int] = [:]
        var layout: [Any] = []
        if note.sourceFormat == .note {
            for (name, page) in try pdfLayout(pkg) {
                guard let name, let path = pkg.paths.first(where: { $0.hasSuffix("PDFs/" + name) }) else {
                    layout.append(NSNull()); continue
                }
                if files[name] == nil {
                    files[name] = files.count
                    try pkg.read(path).write(to: out.appendingPathComponent("src-\(files[name] ?? 0).pdf"))
                }
                layout.append([files[name] ?? 0, page])
            }
        }
        let info: [String: Any] = ["pages": count, "scale": Self.evalScale, "pdfLayout": layout,
                                   "breakHeight": state.meta.pageSize.breakHeight ?? 0]
        try json(info).write(to: out.appendingPathComponent("pages.json"))
    }

    /// The PDF file name and 1-based page number of the note's first page,
    /// from `richText.pageLayoutArray`, if the note is made from a PDF.
    func firstPDFPage(_ pkg: NotePackage) throws -> (String, Int)? {
        guard let first = try pdfLayout(pkg).first, let name = first.0 else { return nil }
        return (name, first.1)
    }

    /// Per Notability page of a note made from a PDF: the PDF file name (nil
    /// for an inserted paper page) and 1-based page number, from
    /// `richText.pageLayoutArray`. Empty for a note on paper or an `.ntb`.
    func pdfLayout(_ pkg: NotePackage) throws -> [(String?, Int)] {
        guard let sessionPath = pkg.paths.first(where: { $0.hasSuffix("/Session.plist") || $0 == "Session.plist" })
        else { return [] }
        let session = try KeyedArchive(data: pkg.read(sessionPath))
        let root = try session.root(anyOf: ["$0", "root"])
        let richText = try session.field(root, "richText")
        return try session.elements(session.field(richText, "pageLayoutArray")).map { entry in
            let name = try session.field(entry, "kPageLayoutPDFFileNameKey").string
                ?? (try? session.field(session.field(entry, "kPageLayoutPDFFileKey"), "pdfFileName").string) ?? nil
            return (name, Int(try session.field(entry, "kPageLayoutPDFPageNumberKey").int ?? 1))
        }
    }

    /// Notability's own PDF export of each note in the backup: the `.pdf` with
    /// the same path as the `.note` (Drive backups hold both).
    struct CompanionPDFs {
        var zips: [String: ZipArchive] = [:]

        init(_ inputs: [URL]) throws {
            for url in inputs where url.pathExtension.lowercased() == "zip" {
                zips[url.path] = try ZipArchive(url: url)
            }
        }

        func location(_ label: String) -> (ZipArchive, ZipArchive.Entry)? {
            guard let bang = label.lastIndex(of: "!"), let zip = zips[String(label[..<bang])] else { return nil }
            let entry = String(label[label.index(after: bang)...])
            guard entry.lowercased().hasSuffix(".note") else { return nil }
            guard let e = zip.entry(String(entry.dropLast(5)) + ".pdf") else { return nil }
            return (zip, e)
        }

        func has(_ label: String) -> Bool {
            if location(label) != nil { return true }
            return label.lowercased().hasSuffix(".note")
                && FileManager.default.fileExists(atPath: String(label.dropLast(5)) + ".pdf")
        }

        func read(_ label: String) throws -> Data? {
            if let (zip, e) = location(label) { return try zip.read(e) }
            let path = String(label.dropLast(5)) + ".pdf"
            guard label.lowercased().hasSuffix(".note"), FileManager.default.fileExists(atPath: path) else { return nil }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
