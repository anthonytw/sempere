import Foundation
import Sempere
import SempereImport
import SempereRender

/// What the app asks of an import (the importer's own flags and the two the app handles itself).
/// The defaults are the CLI's (`docs/cli.md`): everything is imported, image metadata stripped, PDF page
/// text stored, no handwriting reading afterwards.
public struct ImportOptions: Equatable, Sendable {
    /// The importer's flags by option id; an id not set has the importer's default.
    public var values = ImporterOptionValues()
    /// The text of PDF pages for search, from PDFKit (`--pdf-text`).
    public var pdfText = true
    /// Read the handwriting of pages the source app never indexed, afterwards (`--recognize missing`).
    public var recognizeMissing = false

    public init(values: ImporterOptionValues = ImporterOptionValues(), pdfText: Bool = true, recognizeMissing: Bool = false) {
        self.values = values
        self.pdfText = pdfText
        self.recognizeMissing = recognizeMissing
    }

    /// The values passed to `importer`: only the options the app offers (`appTitle`) may be set; every other
    /// option (`--overwrite`, `--tag`) keeps the importer's default, so an import from the app never replaces a
    /// note that is already in the vault (and may be open in an editor).
    func appValues(for importer: any VaultImporter) -> ImporterOptionValues {
        let offered = Set(importer.options.filter { $0.appTitle != nil }.map(\.id))
        return ImporterOptionValues(values.values.filter { offered.contains($0.key) })
    }
}

/// The report of an import as the app shows it: totals of what was imported and of what the importer left
/// out, and its warnings, which name file names and field names of the user's own backup, never note text. The rows'
/// names (`Row.label`) and the saved report (`ImportSummary.reportText`) are the app's words.
public struct ImportDetails: Equatable, Sendable {
    /// A counted line of the report: the importer's count id, and its English words for an id the app does not know.
    public struct Row: Equatable, Sendable, Identifiable {
        public var key: String
        public var english: String
        public var count: Int
        public var id: String { key }

        init(key: String, english: String, count: Int) {
            self.key = key
            self.english = english
            self.count = count
        }

        init(_ count: ImporterCount) {
            self.init(key: count.id, english: count.english, count: count.count)
        }
    }

    public var imported: [Row] = []
    public var notImported: [Row] = []
    /// `"<file name>: <warning>"`, at most `maxWarnings` of them, each cut to `maxWarningLength` characters.
    public var warnings: [String] = []
    /// Warnings beyond `maxWarnings`.
    public var moreWarnings = 0
    /// Every note's line as `sempere import <id> -v` prints it (English; file names and titles of the user's own
    /// backup), for the saved report.
    public var noteLines: [String] = []
    /// When the import ran; nil for a report not made from an importer's result (nothing to save).
    public var date: Date?
    /// Reading the handwriting afterwards was asked for, and what it did.
    public var recognitionAsked = false
    public var recognizedPages = 0
    public var recognitionFailed = 0

    static let maxWarnings = 300
    static let maxWarningLength = 400

    public init() {}

    public init(_ result: ImporterResult) {
        imported = result.imported.map(Row.init)
        notImported = result.leftOut.map(Row.init)
        var all: [String] = []
        for n in result.notes {
            let name = (n.source as NSString).lastPathComponent
            for w in n.warnings { all.append("\(name): \(w)") }
        }
        warnings = all.prefix(Self.maxWarnings).map { String($0.prefix(Self.maxWarningLength)) }
        moreWarnings = max(0, all.count - Self.maxWarnings)
    }

    /// Nothing to show beyond the summary lines (the text report can still be saved).
    public var isEmpty: Bool { imported.isEmpty && notImported.isEmpty && warnings.isEmpty && moreWarnings == 0 }
}

/// What an import did, for the alert after it (its `title` and `message` are the app's words).
public struct ImportSummary: Equatable, Sendable {
    /// The importer's display name ("Notability").
    public var source = ""
    public var imported = 0
    public var skipped = 0
    public var failed = 0
    /// Notes not imported because the import was canceled (counted in `skipped` by the importer, not here).
    public var cancelled = 0
    /// The import was stopped with Cancel.
    public var wasCancelled = false
    /// Source names (file names, never note content) of the notes that failed, with why.
    public var failures: [String] = []
    /// Nothing to import was found in what was picked.
    public var nothingFound = false
    /// What was imported and left out, and the importer's warnings (the report sheet).
    public var details = ImportDetails()

    /// `failures` are (source path, why); only the file name is kept.
    public init(source: String = "", imported: Int, skipped: Int, failed: Int, failures: [(source: String, why: String)],
         nothingFound: Bool = false) {
        self.source = source
        self.imported = imported
        self.skipped = skipped
        self.failed = failed
        self.failures = failures.map { "\(($0.source as NSString).lastPathComponent): \($0.why)" }
        self.nothingFound = nothingFound
    }

    public init(source: String, result: ImporterResult, at date: Date = Date()) {
        self.init(source: source, imported: result.importedCount, skipped: result.skippedCount - result.cancelledCount,
                  failed: result.failedCount,
                  failures: result.notes.compactMap { note in
                      guard case .failed(let why) = note.status else { return nil }
                      return (note.source, why)
                  },
                  nothingFound: result.notes.isEmpty)
        cancelled = result.cancelledCount
        wasCancelled = result.cancelled
        details = ImportDetails(result)
        details.noteLines = result.presentation(ImporterStyle(verbose: true)).lines.map(\.text)
        details.date = date
    }
}

/// Notes from other apps into the open vault: the registered importers (`BuiltInImporters`, the CLI runs the same
/// ones with `sempere import <id>`) with their options (`ImportOptions`, asked in `ImportOptionsSheet`), the PDF
/// page text from PDFKit; the result is the alert's summary and the full report (`ImportDetails`).
extension AppModelCore {
    /// What `importer` reads: its files, folders of them and zip archives (a backup; pick every part of a split one).
    /// The app's picker takes them as `UTType`s (`importTypes(for:)`).
    nonisolated public static func importFileKinds(for importer: any VaultImporter) -> [ImportFileKind] {
        [.zip, .folder] + importer.fileExtensions.map { .fileExtension($0) }
    }

    /// Imports `urls` (security-scoped, from the file picker) into the open vault with `importer`, filing every
    /// note under `notebook` (nil: the importer's own rule).
    ///
    /// Writes through the model's one `DeviceClock` (`withClock`) under the edit gate, like every other write.
    /// Existing notes are never overwritten, so no
    /// open editor's note changes. The result is in `importSummary`.
    public func importFromApp(_ importer: any VaultImporter, urls: [URL], notebook: String?,
                       options: ImportOptions = ImportOptions()) async throws {
        guard !urls.isEmpty else { return }
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        try requireWritableVault()   // format.md §7.3
        guard !isImporting else { return }
        isImporting = true
        let relay = ImportProgressRelay { [weak self] in self?.importProgress = $0 }
        let cancellation = ImporterCancellation()
        importProgress = ImporterProgress(phase: .finding, done: 0, total: 0)
        importCancellation = importer.supportsCancel ? cancellation : nil
        defer {
            relay.finish()
            isImporting = false
            importProgress = nil
            importCancellation = nil
        }
        let gen = generation
        let result: ImporterResult
        do {
            await editGate.acquire()
            defer { editGate.release() }
            try ensureCurrent(gen)
            let clock = try deviceClockForWriting()
            let device = clock.device
            let extractor: (any PDFTextExtracting)? = importer.usesPDFText && options.pdfText ? services.pdfTextExtractor : nil
            // A HEIC image of the source is converted the way a picked photo is with Photo Privacy on (location and
            // camera data gone), unless the import keeps image metadata.
            let preparation = services.attachmentPreparation
            let request = ImporterRequest(paths: urls, vault: vault, device: device, options: options.appValues(for: importer),
                                          pdfText: extractor, notebook: NotebookPath.canonical(notebook),
                                          progress: { relay.post($0) }, cancellation: cancellation,
                                          convertHEIC: { try preparation.prepareImage($0, privacy: true) })
            let bookmarks = services.bookmarks
            let scoped = urls.map { bookmarks.startAccessing($0) }
            defer { for (url, s) in zip(urls, scoped) where s { bookmarks.stopAccessing(url) } }
            result = try await clock.withClock(save: true) { c in try importer.run(request, clock: &c) }
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
        lastImportReport = summary
    }

    /// Cancel on the import's progress: the importer stops after the note it is writing (`ImporterCancellation`);
    /// what was written stays, and the summary says how many were not imported.
    public func cancelImport() {
        importCancellation?.cancel()
    }

    /// `--recognize missing`: reads the pages of the notes just written that the source app never indexed
    /// (`RecognitionPolicy.needsRecognition`), one delta per note, outside the import's edit gate (each note's
    /// write takes it). The device's recognizer, else the platform's (`services.makePageRecognizer`: Vision in the
    /// app; none headless, and then nothing is read); a note that fails is counted.
    private func recognizeImported(_ ids: [UUID], into summary: inout ImportSummary, generation gen: Int) async {
        guard let reader = recognizer ?? services.makePageRecognizer() else { return }
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

/// What an importer reads, for the file picker (the app's `UTType`s).
public enum ImportFileKind: Equatable, Sendable {
    case zip
    case folder
    /// Files with this extension (no dot).
    case fileExtension(String)
}

/// Carries progress reports made on a working thread (an importer's, a copy's) to the model on the main actor: only
/// the latest one is shown, at most one hop is queued at a time, and nothing arrives after `finish`.
final class ProgressRelay<Progress: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Progress?
    private var queued = false
    private var finished = false
    private let deliverTo: @MainActor (Progress) -> Void

    @MainActor init(deliver: @escaping @MainActor (Progress) -> Void) { deliverTo = deliver }

    func post(_ progress: Progress) {
        lock.lock()
        latest = progress
        let hop = !queued && !finished
        if hop { queued = true }
        lock.unlock()
        guard hop else { return }
        Task { @MainActor [self] in deliver() }
    }

    @MainActor private func deliver() {
        lock.lock()
        let progress = finished ? nil : latest
        queued = false
        lock.unlock()
        if let progress { deliverTo(progress) }
    }

    /// No report reaches the model after this (the work ended).
    func finish() {
        lock.lock(); finished = true; lock.unlock()
    }
}

/// An import's progress reports (`AppModelCore.importFromApp`).
typealias ImportProgressRelay = ProgressRelay<ImporterProgress>
