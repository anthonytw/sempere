import Foundation
import Sempere
import SempereImport
import SempereRender
import UniformTypeIdentifiers

/// What the app asks of an import (the importer's own flags and the two the app handles itself).
/// The defaults are the CLI's (`docs/cli.md`): everything is imported, image metadata stripped, PDF page
/// text stored, no handwriting reading afterwards.
struct ImportOptions: Equatable, Sendable {
    /// The importer's flags by option id; an id not set has the importer's default.
    var values = ImporterOptionValues()
    /// The text of PDF pages for search, from PDFKit (`--pdf-text`).
    var pdfText = true
    /// Read the handwriting of pages the source app never indexed, afterwards (`--recognize missing`).
    var recognizeMissing = false

    /// The values passed to `importer`: only the options the app offers (`appTitle`) may be set; every other
    /// option (`--overwrite`, `--tag`) keeps the importer's default, so an import from the app never replaces a
    /// note that is already in the vault (and may be open in an editor).
    func appValues(for importer: any VaultImporter) -> ImporterOptionValues {
        let offered = Set(importer.options.filter { $0.appTitle != nil }.map(\.id))
        return ImporterOptionValues(values.values.filter { offered.contains($0.key) })
    }
}

/// The report of an import as the app shows it: totals of what was imported and of what the importer left
/// out, and its warnings, which name file names and field names of the user's own backup, never note text.
struct ImportDetails: Equatable, Sendable {
    /// A counted line of the report.
    struct Row: Equatable, Sendable, Identifiable {
        var label: String
        var count: Int
        var id: String { label }
    }

    var imported: [Row] = []
    var notImported: [Row] = []
    /// `"<file name>: <warning>"`, at most `maxWarnings` of them, each cut to `maxWarningLength` characters.
    var warnings: [String] = []
    /// Warnings beyond `maxWarnings`.
    var moreWarnings = 0
    /// Reading the handwriting afterwards was asked for, and what it did.
    var recognitionAsked = false
    var recognizedPages = 0
    var recognitionFailed = 0

    static let maxWarnings = 300
    static let maxWarningLength = 400

    init() {}

    init(_ result: ImporterResult) {
        imported = result.imported.map { Row(label: Self.label($0), count: $0.count) }
        notImported = result.leftOut.map { Row(label: Self.label($0), count: $0.count) }
        var all: [String] = []
        for n in result.notes {
            let name = (n.source as NSString).lastPathComponent
            for w in n.warnings { all.append("\(name): \(w)") }
        }
        warnings = all.prefix(Self.maxWarnings).map { String($0.prefix(Self.maxWarningLength)) }
        moreWarnings = max(0, all.count - Self.maxWarnings)
    }

    /// Nothing to show beyond the summary lines.
    var isEmpty: Bool { imported.isEmpty && notImported.isEmpty && warnings.isEmpty && moreWarnings == 0 }

    /// The localized name of a counted line: the ids the importers use today have catalog entries; an id
    /// the app does not know shows the importer's English words.
    static func label(_ count: ImporterCount) -> String {
        switch count.id {
        // Imported
        case "pdfPages": return String(localized: "PDF pages", comment: "Import report row")
        case "pdfTextPages": return String(localized: "PDF pages with text for search", comment: "Import report row")
        case "images": return String(localized: "Images", comment: "Import report row")
        case "textItems": return String(localized: "Text boxes", comment: "Import report row")
        case "recordings": return String(localized: "Recordings", comment: "Import report row")
        case "transcripts": return String(localized: "Transcripts", comment: "Import report row")
        case "recLinkedStrokes": return String(localized: "Strokes linked to a recording", comment: "Import report row")
        // Left out
        case "typedTextCharacters": return String(localized: "Typed text (characters)", comment: "Import report: not imported")
        case "pdfs": return String(localized: "PDF files", comment: "Import report: not imported")
        case "media": return String(localized: "Images and other media", comment: "Import report: not imported")
        case "pdfHighlights": return String(localized: "PDF highlights", comment: "Import report: not imported")
        case "templatePDFs": return String(localized: "Template PDF paper", comment: "Import report: not imported")
        case "recLinks": return String(localized: "Links from strokes to recordings", comment: "Import report: not imported")
        case "dashedStrokes": return String(localized: "Dashed strokes (imported solid)", comment: "Import report: not imported")
        case "unknownStyleStrokes":
            return String(localized: "Strokes of an unknown style (imported as pen)", comment: "Import report: not imported")
        case "defaultedAttributeStrokes":
            return String(localized: "Strokes with a missing style, color or width", comment: "Import report: not imported")
        case "unsupportedShapes": return String(localized: "Shapes not converted", comment: "Import report: not imported")
        case "unsupportedStrokes": return String(localized: "Strokes of a kind not understood", comment: "Import report: not imported")
        case "clampedStrokes": return String(localized: "Strokes whose position was not stored", comment: "Import report: not imported")
        case "bundleRecordsWithoutFile":
            return String(localized: "Attachments with no file in the backup", comment: "Import report: not imported")
        case "bundleFilesUnreferenced": return String(localized: "Attachment files no note names", comment: "Import report: not imported")
        default: return count.english
        }
    }
}

/// What an import did, for the alert after it.
struct ImportSummary: Equatable, Sendable {
    /// The importer's display name ("Notability").
    var source = ""
    var imported = 0
    var skipped = 0
    var failed = 0
    /// Source names (file names, never note content) of the notes that failed, with why.
    var failures: [String] = []
    /// Nothing to import was found in what was picked.
    var nothingFound = false
    /// What was imported and left out, and the importer's warnings (the report sheet).
    var details = ImportDetails()

    /// `failures` are (source path, why); only the file name is kept.
    init(source: String = "", imported: Int, skipped: Int, failed: Int, failures: [(source: String, why: String)],
         nothingFound: Bool = false) {
        self.source = source
        self.imported = imported
        self.skipped = skipped
        self.failed = failed
        self.failures = failures.map { "\(($0.source as NSString).lastPathComponent): \($0.why)" }
        self.nothingFound = nothingFound
    }

    init(source: String, result: ImporterResult) {
        self.init(source: source, imported: result.importedCount, skipped: result.skippedCount, failed: result.failedCount,
                  failures: result.notes.compactMap { note in
                      guard case .failed(let why) = note.status else { return nil }
                      return (note.source, why)
                  },
                  nothingFound: result.notes.isEmpty)
        details = ImportDetails(result)
    }

    var title: String {
        failed > 0 ? String(localized: "Import Finished with Errors", comment: "Alert title after an import from another app")
            : String(localized: "\(source) Import", comment: "Alert title after an import from another app (the app's name)")
    }

    /// Whole sentences, one per line (never joined fragments: docs/localization.md).
    var message: String {
        if nothingFound {
            return String(localized: "No notes from \(source) were found in what you picked.",
                          comment: "Import result when the chosen files held nothing to import (the app's name)")
        }
        var lines = [String(localized: "\(imported) notes imported.", comment: "Import result: notes written")]
        if skipped > 0 {
            lines.append(String(localized: "\(skipped) notes skipped (already in the vault, or a copy of a note imported from another file).",
                                comment: "Import result"))
        }
        if details.recognitionAsked, details.recognizedPages > 0 {
            lines.append(String(localized: "Handwriting read on \(details.recognizedPages) pages.",
                                comment: "Import result: pages the app read after the import"))
        }
        if details.recognitionFailed > 0 {
            lines.append(String(localized: "Handwriting could not be read in \(details.recognitionFailed) notes.",
                                comment: "Import result: notes the app could not read after the import"))
        }
        if failed > 0 {
            lines.append(String(localized: "\(failed) notes failed:", comment: "Import result, followed by one line per note"))
            lines += failures.prefix(5)
            if failures.count > 5 {
                lines.append(String(localized: "…and \(failures.count - 5) more.", comment: "After the first failed notes of an import"))
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Notes from other apps into the open vault: the registered importers (`AppImporters`, the CLI runs the same
/// ones with `sempere import <id>`) with their options (`ImportOptions`, asked in `ImportOptionsSheet`), the PDF
/// page text from PDFKit; the result is the alert's summary and the full report (`ImportDetails`).
extension AppModel {
    /// What `importer` reads: its files, folders of them and zip archives (a backup; pick every part of a split one).
    static func importTypes(for importer: any VaultImporter) -> [UTType] {
        var types: [UTType] = [.zip, .folder]
        for ext in importer.fileExtensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    /// Imports `urls` (security-scoped, from the file picker) into the open vault with `importer`, filing every
    /// note under `notebook` (nil: the importer's own rule).
    ///
    /// Writes through the model's one `DeviceClock` (`withClock`) under the edit gate, like every other write; in
    /// iCloud Drive the writes are one coordinated write on `notes/`. Existing notes are never overwritten, so no
    /// open editor's note changes. The result is in `importSummary`.
    func importFromApp(_ importer: any VaultImporter, urls: [URL], notebook: String?,
                       options: ImportOptions = ImportOptions()) async throws {
        guard !urls.isEmpty else { return }
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        try requireWritableVault()   // format.md §7.3
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let gen = generation
        let result: ImporterResult
        do {
            await editGate.acquire()
            defer { editGate.release() }
            try ensureCurrent(gen)
            let clock = try deviceClockForWriting()
            let device = clock.device
            let notes = isCloudVault ? vault.url.appendingPathComponent("notes", isDirectory: true) : nil
            let extractor: (any PDFTextExtracting)? = importer.usesPDFText && options.pdfText ? PDFKitTextExtractor() : nil
            let request = ImporterRequest(paths: urls, vault: vault, device: device, options: options.appValues(for: importer),
                                          pdfText: extractor, notebook: NotebookPath.canonical(notebook))
            let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
            defer { for (url, s) in zip(urls, scoped) where s { url.stopAccessingSecurityScopedResource() } }
            result = try await clock.withClock(save: true) { c in
                try CloudVault.coordinatedWrite(notes) {
                    try importer.run(request, clock: &c)
                }
            }
            try ensureCurrent(gen)
        }
        let written = result.writtenNotes
        if !written.isEmpty { try await refresh(written) }
        var summary = ImportSummary(source: importer.displayName, result: result)
        if options.recognizeMissing, importer.supportsRecognizeAfter {
            summary.details.recognitionAsked = true
            await recognizeImported(written, into: &summary, generation: gen)
        }
        try ensureCurrent(gen)
        importSummary = summary
    }

    /// `--recognize missing`: reads the pages of the notes just written that the source app never indexed
    /// (`RecognitionPolicy.needsRecognition`), one delta per note, outside the import's edit gate (each note's
    /// write takes it). The device's recognizer, else Vision; a note that fails is counted.
    private func recognizeImported(_ ids: [UUID], into summary: inout ImportSummary, generation gen: Int) async {
        let reader: any PageRecognizing = recognizer ?? VisionPageRecognizer()
        for id in ids {
            guard gen == generation, !Task.isCancelled else { return }
            do {
                if let done = try await recognizeNote(id, with: reader) { summary.details.recognizedPages += done.pagesRecognized }
            } catch is CancellationError {
                return
            } catch {
                summary.details.recognitionFailed += 1
            }
        }
    }
}
