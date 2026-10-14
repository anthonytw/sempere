import Foundation
import Sempere
import SempereImport
import SempereRender

/// The Notability importer as a host sees it (`VaultImporter`): its options, a run, and the CLI's
/// output for the result. The CLI and the app know this type by the registry entry only.
public struct NotabilityVaultImporter: VaultImporter {
    public init() {}

    public let id = "notability"
    public let displayName = "Notability"
    public let abstract = "Import Notability .note files into a vault."
    public let discussion = """
        Each PATH is a .note or .ntb file, an unzipped .note package directory, a folder searched
        recursively for both, or a zip of them (Notability's backup; pass every part of a split
        backup). Copies of one note are resolved across all paths: the newest .note with ink is imported,
        copies with no other ink are skipped, and a copy holding ink the chosen one lacks is
        imported as a separate note. Notes already in the vault are skipped unless --overwrite.
        PDF pages become page backgrounds, images image items, typed text text items and
        recordings the note's recordings; files are stored encrypted in the note's att/ folder (image
        metadata stripped unless --keep-image-metadata). --no-attachments imports ink only. The device id and clock come from
        $XDG_STATE_HOME/sempere/device.json; --dry-run leaves both and the vault untouched.
        Exit 1 if any note failed.
        """
    public let pathHelp = "A .note or .ntb file, a .note package, a folder, or a zip of notes."
    public let fileExtensions = ["note", "ntb"]
    public let usesPDFText = true
    public let supportsRecognizeAfter = true

    public let options: [ImporterOptionSpec] = [
        .init(id: "overwrite", kind: .flag(defaultOn: false), cliName: "overwrite",
              help: "Re-import notes that are already in the vault (replaces their pages)."),
        .init(id: "scale", kind: .flag(defaultOn: true), cliName: "no-scale",
              help: "Keep Notability's document units instead of scaling to 612 pt width."),
        .init(id: "folderTags", kind: .flag(defaultOn: true), cliName: "no-folder-tags",
              help: "Do not tag notes with their Notability folder names (tagging is on by default).",
              appTitle: "Tag Notes with Their Notability Folders"),
        .init(id: "tag", kind: .list(valueName: "tag"), cliName: "tag", help: "Add this tag to every imported note (repeatable)."),
        .init(id: "attachments", kind: .flag(defaultOn: true), cliName: "no-attachments",
              help: "Import ink only: no PDF backgrounds, images, typed text or recordings (reported as dropped).",
              appTitle: "Attachments"),
        .init(id: "keepImageMetadata", kind: .flag(defaultOn: false), cliName: "keep-image-metadata",
              help: "Store images with their camera and location metadata (stripped by default).",
              appTitle: "Keep Photo Metadata"),
    ]

    public func run(_ request: ImporterRequest, clock: inout HybridClock) throws -> ImporterResult {
        let o = request.options
        let attachments = o.bool("attachments", default: true)
        let options = NotabilityImporter.Options(overwrite: o.bool("overwrite", default: false), notebook: request.notebook,
                                                 scaleToLetterWidth: o.bool("scale", default: true),
                                                 tagsFromFolders: o.bool("folderTags", default: true), extraTags: o.list("tag"),
                                                 attachments: attachments,
                                                 keepImageMetadata: o.bool("keepImageMetadata", default: false),
                                                 pdfText: request.pdfText)
        let report = try NotabilityImporter.import(paths: request.paths, into: request.vault, device: request.device,
                                                   clock: &clock, options: options)
        return Self.result(report, noAttachments: !attachments)
    }

    /// The host-neutral result of a report.
    static func result(_ report: NotabilityImporter.ImportReport, noAttachments: Bool) -> ImporterResult {
        let notes = report.notes.map { n -> ImporterNoteOutcome in
            let status: ImporterNoteOutcome.Status
            switch n.status {
            case .ok: status = .imported
            case .skipped(let why): status = .skipped(why)
            case .failed(let why): status = .failed(why)
            }
            return ImporterNoteOutcome(source: n.source, noteID: n.noteId, status: status, warnings: n.warnings)
        }
        let written = report.notes.filter { $0.status == .ok }
        func total(_ value: (NotabilityImporter.NoteResult) -> Int) -> Int { written.reduce(0) { $0 + value($1) } }
        let imported = [
            ImporterCount(id: "pdfPages", english: "PDF pages", count: total { $0.attachments.pdfPages }),
            ImporterCount(id: "pdfTextPages", english: "PDF pages with text for search", count: total { $0.attachments.pdfTextPages }),
            ImporterCount(id: "images", english: "Images", count: total { $0.attachments.images }),
            ImporterCount(id: "textItems", english: "Text boxes", count: total { $0.attachments.textItems }),
            ImporterCount(id: "recordings", english: "Recordings", count: total { $0.attachments.recordings }),
            ImporterCount(id: "transcripts", english: "Transcripts", count: total { $0.attachments.transcripts }),
            ImporterCount(id: "recLinkedStrokes", english: "Strokes linked to a recording", count: total { $0.attachments.recLinkedStrokes }),
        ].filter { $0.count > 0 }
        var left: [NotabilityImporter.Dropped.Kind: Int] = [:]
        for n in written { for (kind, count) in n.dropped.nonZero { left[kind, default: 0] += count } }
        let leftOut = NotabilityImporter.Dropped.Kind.allCases.compactMap { kind in
            left[kind].map { ImporterCount(id: kind.rawValue, english: kind.english, count: $0) }
        }
        return ImporterResult(notes: notes, imported: imported, leftOut: leftOut) { style, recognition in
            present(report, noAttachments: noAttachments, style: style, recognition: recognition)
        }
    }

    private struct ImportNoteJSON: Encodable {
        var source: String
        var status: String
        var reason: String?
        var id: String?
        var title: String?
        var notebook: String?
        var strokes: Int
        var recognizedPages: Int
        var originalWidth: Double?
        var dropped: Dropped
        var seconds: Double
        var format: String
        var shapes: Int
        var duplicateOf: String?
        var extraVersion: Bool
        var selection: String?
        var attachments: Attachments
        var warnings: [String]
        /// `meta.lang` (BCP 47), when the note has a handwriting language.
        var lang: String?
        var markersBehindText: Bool
        /// `#RRGGBBAA` from `paperColor`, when the note has one.
        var paperColor: String?

        struct Dropped: Encodable {
            var typedTextCharacters: Int, pdfs: Int, pdfPages: Int, media: Int, recordings: Int
            var pdfHighlights: Int, templatePDFs: Int, recLinks: Int
            var dashedStrokes: Int, unknownStyleStrokes: Int
            var defaultedAttributeStrokes: Int, unsupportedShapes: Int, unsupportedStrokes: Int, clampedStrokes: Int
            var bundleRecordsWithoutFile: Int, bundleFilesUnreferenced: Int, pdfTextPages: Int
        }

        struct Attachments: Encodable {
            var pdfs: Int, pdfPages: Int, templatePages: Int, images: Int, textItems: Int, textCharacters: Int
            var recordings: Int, recLinkedStrokes: Int, transcripts: Int, blobs: Int, blobBytes: Int64
            var pdfTextPages: Int, pdfTextFromIndex: Int, pdfTextExtracted: Int
            var bundlePDFRecords: Int, bundleMediaRecords: Int, bundleFiles: Int, bundleFilesImported: Int
        }

        init(_ r: NotabilityImporter.NoteResult) {
            source = r.source; id = r.noteId?.uuidString.lowercased(); title = r.title; notebook = r.notebook
            strokes = r.strokes; recognizedPages = r.recognizedPages; originalWidth = r.originalWidth
            seconds = r.seconds
            format = r.format.rawValue; shapes = r.shapes; duplicateOf = r.duplicateOf
            extraVersion = r.extraVersion; selection = r.selection
            let a = r.attachments
            attachments = Attachments(pdfs: a.pdfs, pdfPages: a.pdfPages, templatePages: a.templatePages, images: a.images,
                                      textItems: a.textItems, textCharacters: a.textCharacters, recordings: a.recordings,
                                      recLinkedStrokes: a.recLinkedStrokes, transcripts: a.transcripts, blobs: a.blobs, blobBytes: a.blobBytes,
                                      pdfTextPages: a.pdfTextPages, pdfTextFromIndex: a.pdfTextFromIndex,
                                      pdfTextExtracted: a.pdfTextExtracted, bundlePDFRecords: a.bundlePDFRecords,
                                      bundleMediaRecords: a.bundleMediaRecords, bundleFiles: a.bundleFiles,
                                      bundleFilesImported: a.bundleFilesImported)
            warnings = r.warnings
            lang = r.lang; markersBehindText = r.markersBehindText; paperColor = r.paperColor
            let d = r.dropped
            dropped = Dropped(typedTextCharacters: d.typedTextCharacters, pdfs: d.pdfs, pdfPages: d.pdfPages, media: d.media,
                              recordings: d.recordings, pdfHighlights: d.pdfHighlights, templatePDFs: d.templatePDFs,
                              recLinks: d.recLinks,
                              dashedStrokes: d.dashedStrokes,
                              unknownStyleStrokes: d.unknownStyleStrokes,
                              defaultedAttributeStrokes: d.defaultedAttributeStrokes,
                              unsupportedShapes: d.unsupportedShapes, unsupportedStrokes: d.unsupportedStrokes,
                              clampedStrokes: d.clampedStrokes, bundleRecordsWithoutFile: d.bundleRecordsWithoutFile,
                              bundleFilesUnreferenced: d.bundleFilesUnreferenced, pdfTextPages: d.pdfTextPages)
            switch r.status {
            case .ok: status = "imported"
            case .skipped(let why): status = "skipped"; reason = why
            case .failed(let why): status = "failed"; reason = why
            }
        }
    }

    static func present(_ report: NotabilityImporter.ImportReport, noAttachments: Bool, style: ImporterStyle,
                        recognition: ImporterRecognition?) -> ImporterPresentation {
        let written = report.notes.filter { $0.status == .ok }
        let ntb = written.filter { $0.format == .ntb }
        var lines: [ImporterPresentation.Line] = []
        func out(_ s: String) { lines.append(.init(s)) }
        func err(_ s: String) { lines.append(.init(s, isError: true)) }
        func info(_ s: @autoclosure () -> String) { if !style.quiet && !style.json { out(s()) } }
        if style.json {
            struct Summary: Encodable {
                var dryRun: Bool, notes: Int, imported: Int, skipped: Int, failed: Int, strokes: Int
                var ntb: Int, extraVersions: Int
                var pdfPages: Int, images: Int, textItems: Int, recordings: Int, recLinkedStrokes: Int, transcripts: Int
                var blobs: Int, blobBytes: Int64, droppedPDFPages: Int, droppedMedia: Int
                /// Counts to compare with a backup (docs/import-notability.md "Report").
                var pdfs: Int, ntbPDFPages: Int, ntbImages: Int, ntbDroppedPDFs: Int
                var pdfTextPages: Int, pdfTextFromIndex: Int, pdfTextExtracted: Int, pdfPagesWithoutText: Int
                var languages: [String: Int], markersBehindText: Int, paperColors: Int
            }
            struct Out: Encodable {
                var summary: Summary; var notes: [ImportNoteJSON]; var recognized: [AnyEncodable]?
            }
            return finish(AnyEncodable(Out(summary: Summary(dryRun: style.dryRun, notes: report.notes.count, imported: report.imported,
                                                     skipped: report.skipped, failed: report.failed, strokes: report.strokes,
                                                     ntb: report.notes.filter { $0.format == .ntb }.count,
                                                     extraVersions: report.notes.filter(\.extraVersion).count,
                                                     pdfPages: written.reduce(0) { $0 + $1.attachments.pdfPages },
                                                     images: written.reduce(0) { $0 + $1.attachments.images },
                                                     textItems: written.reduce(0) { $0 + $1.attachments.textItems },
                                                     recordings: written.reduce(0) { $0 + $1.attachments.recordings },
                                                     recLinkedStrokes: written.reduce(0) { $0 + $1.attachments.recLinkedStrokes },
                                                     transcripts: written.reduce(0) { $0 + $1.attachments.transcripts },
                                                     blobs: written.reduce(0) { $0 + $1.attachments.blobs },
                                                     blobBytes: written.reduce(0) { $0 + $1.attachments.blobBytes },
                                                     droppedPDFPages: written.reduce(0) { $0 + $1.dropped.pdfPages },
                                                     droppedMedia: written.reduce(0) { $0 + $1.dropped.media },
                                                     pdfs: written.reduce(0) { $0 + $1.attachments.pdfs },
                                                     ntbPDFPages: ntb.reduce(0) { $0 + $1.attachments.pdfPages },
                                                     ntbImages: ntb.reduce(0) { $0 + $1.attachments.images },
                                                     ntbDroppedPDFs: ntb.reduce(0) { $0 + $1.dropped.pdfs },
                                                     pdfTextPages: written.reduce(0) { $0 + $1.attachments.pdfTextPages },
                                                     pdfTextFromIndex: written.reduce(0) { $0 + $1.attachments.pdfTextFromIndex },
                                                     pdfTextExtracted: written.reduce(0) { $0 + $1.attachments.pdfTextExtracted },
                                                     pdfPagesWithoutText: written.reduce(0) { $0 + $1.dropped.pdfTextPages },
                                                     languages: written.reduce(into: [:]) { m, n in if let l = n.lang { m[l, default: 0] += 1 } },
                                                     markersBehindText: written.filter(\.markersBehindText).count,
                                                     paperColors: written.filter { $0.paperColor != nil }.count),
                                    notes: report.notes.map(ImportNoteJSON.init),
                                    recognized: recognition?.results)), report, recognition)
        }
        var rows = style.quiet ? [] : [["STATUS", "TITLE", "NOTEBOOK", "STROKES", "TEXT", "SOURCE"]]
        for n in report.notes {
            let status: String
            switch n.status {
            case .ok: status = style.dryRun ? "would import" : "imported"
            case .skipped: status = "skipped"
            case .failed: status = "FAILED"
            }
            rows.append([status, n.title.map { $0.isEmpty ? "(untitled)" : $0 } ?? "-", n.notebook ?? "-",
                         String(n.strokes), String(n.recognizedPages), n.source])
        }
        if !rows.isEmpty { out(ImporterPresentation.table(rows)) }
        for n in report.notes {
            switch n.status {
            case .skipped(let why) where !style.quiet: out("skipped \(n.source): \(why)")
            case .failed(let why): err("failed \(n.source): \(why)")
            default: break
            }
            if n.status == .ok, n.extraVersion, !style.quiet, let why = n.selection {
                out("separate version \(n.source): \(why)")
            }
            if n.status == .ok, n.strokes == 0, n.dropped.pdfPages > 0, !style.quiet {
                out("no ink in \(n.source), and \(n.dropped.pdfPages) of its PDF page(s) were not imported"
                      + (noAttachments ? " (--no-attachments)" : ""))
            }
            if style.verbose, n.status == .ok {
                for w in n.warnings { out("attachments \(n.source): \(w)") }
            }
            if style.verbose, !n.dropped.isEmpty {
                let parts = n.dropped.nonZero.map { "\($0.count) \($0.kind.english)" }
                out("not imported from \(n.source): " + parts.joined(separator: ", "))
            }
        }
        info("\(style.dryRun ? "Dry run: " : "")\(report.imported) \(style.dryRun ? "would be imported" : "imported"), "
                    + "\(report.skipped) skipped, \(report.failed) failed; \(report.strokes) strokes.")
        if let recognition {
            info("Recognition: \(recognition.pagesRead) page(s) without Notability's text \(style.dryRun ? "would be read" : "read") in "
                 + "\(recognition.notesRead) note(s).")
            for r in recognition.failures { err("recognition failed for \(r.note): \(r.error)") }
        }
        return finish(nil, report, recognition, lines: lines)
    }

    /// The result of the CLI command: the lines (or JSON) and the failure that sets the exit status.
    private static func finish(_ json: AnyEncodable?, _ report: NotabilityImporter.ImportReport, _ recognition: ImporterRecognition?,
                               lines: [ImporterPresentation.Line] = []) -> ImporterPresentation {
        var failure: String?
        if report.notes.isEmpty {
            failure = "no .note or .ntb files found in the given paths"
        } else if report.failed > 0 {
            failure = "\(report.failed) note(s) failed to import"
        } else if let unread = recognition?.failures.count, unread > 0 {
            failure = "\(unread) imported note(s) could not be recognised"
        }
        return ImporterPresentation(json: json, lines: lines, failure: failure)
    }
}
