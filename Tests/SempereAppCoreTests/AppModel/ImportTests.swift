import Foundation
import Sempere
@testable import SempereAppCore
import SempereImport
import TempDirSupport
import Testing

/// An importer that writes nothing: a double for the model's generic import path.
struct FakeImporter: VaultImporter {
    var id = "fake"
    var displayName = "Fake"
    var abstract = "Import fake things."
    var discussion = ""
    var pathHelp = "A fake file."
    var fileExtensions = ["fake"]
    var options: [ImporterOptionSpec] = [
        .init(id: "attachments", kind: .flag(defaultOn: true), cliName: "no-attachments", help: "x", appTitle: "Attachments"),
        .init(id: "keepImageMetadata", kind: .flag(defaultOn: false), cliName: "keep-image-metadata", help: "x", appTitle: "Keep Photo Metadata"),
    ]
    var usesPDFText = true
    var supportsRecognizeAfter = true
    /// What `run` reports.
    var notes: [ImporterNoteOutcome] = []
    var imported: [ImporterCount] = []
    var leftOut: [ImporterCount] = []

    func run(_ request: ImporterRequest, clock: inout HybridClock) throws -> ImporterResult {
        ImporterResult(notes: notes, imported: imported, leftOut: leftOut) { _, _ in ImporterPresentation() }
    }
}

/// An importer over `count` notes that reports progress and stops when cancelled, as the Notability importer does
/// (device check c23: the owner saw no progress during a long import). At note `atNote` it calls `hook` on its own
/// thread and goes on once it returns, so a test acts mid-import without racing it.
struct SlowFakeImporter: VaultImporter {
    var id = "slow"
    var displayName = "Slow"
    var abstract = ""
    var discussion = ""
    var pathHelp = ""
    var fileExtensions = ["slow"]
    var options: [ImporterOptionSpec] = []
    var usesPDFText = false
    var supportsRecognizeAfter = false
    var supportsCancel = true
    var count = 20
    var atNote = -1
    var hook: (@Sendable () -> Void)?

    func run(_ request: ImporterRequest, clock: inout HybridClock) throws -> ImporterResult {
        request.progress?(ImporterProgress(phase: .finding, done: 0, total: 0))
        var notes: [ImporterNoteOutcome] = []
        var stopped = false
        for i in 0..<count {
            if i == atNote { hook?() }
            if request.cancellation?.isCancelled == true { stopped = true }
            if stopped {
                notes.append(ImporterNoteOutcome(source: "/b/N\(i).slow", noteID: nil, status: .skipped(ImporterResult.cancelledReason)))
                continue
            }
            request.progress?(ImporterProgress(phase: .writing, done: i, total: count, current: "N\(i).slow"))
            notes.append(ImporterNoteOutcome(source: "/b/N\(i).slow", noteID: nil, status: .imported))
        }
        let outcome = notes
        return ImporterResult(notes: outcome, imported: [], leftOut: [], cancelled: stopped) { _, _ in
            ImporterPresentation(lines: outcome.map { .init("\($0.status == .imported ? "imported" : "skipped") \($0.source)") })
        }
    }
}

/// Runs `body` on the main actor from an importer's thread and waits for it (`SlowFakeImporter.hook`).
func onMainAndWait(_ body: @escaping @MainActor @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        await body()
        done.signal()
    }
    done.wait()
}

extension AppModelSuites {
    /// Imports from other apps through the model (`AppModel+Import`; moved from the app's `ImportReportTests` and
    /// `ImportProgressTests`, which keep the words, the saved file and the real importer on a synthetic backup): the
    /// importer's options, the report and the summary (GA-08), progress, Cancel, recognition afterwards, and the
    /// picker's file kinds.
    @MainActor
    struct ImportTests {
        static func file(_ ext: String) throws -> URL {
            let url = TestTemp.root.appendingPathComponent("x-\(UUID().uuidString).\(ext)")
            try FileManager.default.createDirectory(at: TestTemp.root, withIntermediateDirectories: true)
            try Data().write(to: url)
            return url
        }

        @Test func theOptionsStartAtTheCLIDefaults() {
            let o = ImportOptions()
            #expect(o.pdfText && !o.recognizeMissing)
            #expect(o.values.values.isEmpty, "the importer's own defaults apply")
        }

        @Test func theAppSetsOnlyTheOptionsItOffers() {
            var importer = FakeImporter()
            importer.options.append(.init(id: "overwrite", kind: .flag(defaultOn: false), cliName: "overwrite", help: "x"))
            importer.options.append(.init(id: "tag", kind: .list(valueName: "tag"), cliName: "tag", help: "x"))
            let options = ImportOptions(values: ImporterOptionValues([
                "overwrite": .bool(true), "tag": .list(["x"]), "attachments": .bool(false), "unknown": .bool(true),
            ]))
            let passed = options.appValues(for: importer)
            #expect(!passed.bool("overwrite", default: false), "an app import never overwrites a note in the vault")
            #expect(passed.list("tag").isEmpty)
            #expect(!passed.bool("attachments", default: true), "an offered switch is passed on")
            #expect(passed.values.keys.sorted() == ["attachments"])
        }

        @Test func theReportListsWhatWasImportedAndLeftOut() {
            let result = ImporterResult(
                notes: [ImporterNoteOutcome(source: "/Users/x/Backup/Lecture.note", noteID: UUID(), status: .imported, warnings: ["placed by a guess"])],
                imported: [ImporterCount(id: "pdfPages", english: "PDF pages", count: 4), ImporterCount(id: "mystery", english: "Mystery items", count: 2)],
                leftOut: [ImporterCount(id: "dashedStrokes", english: "dashed strokes", count: 3)]) { _, _ in ImporterPresentation() }
            let details = ImportDetails(result)
            #expect(details.imported.map(\.count) == [4, 2])
            #expect(details.imported.map(\.key) == ["pdfPages", "mystery"])
            #expect(details.imported.last?.english == "Mystery items", "the importer's words, for an id the app does not know")
            #expect(details.notImported.map(\.key) == ["dashedStrokes"])
            #expect(details.warnings == ["Lecture.note: placed by a guess"], "file names, no folder paths")
            #expect(!details.isEmpty)
            #expect(ImportDetails().isEmpty)
        }

        @Test func warningsAreBounded() {
            let many = (0..<(ImportDetails.maxWarnings + 25)).map { _ in String(repeating: "w", count: 1_000) }
            let result = ImporterResult(notes: [ImporterNoteOutcome(source: "/a/B.note", noteID: nil, status: .imported, warnings: many)],
                                        imported: [], leftOut: []) { _, _ in ImporterPresentation() }
            let details = ImportDetails(result)
            #expect(details.warnings.count == ImportDetails.maxWarnings)
            #expect(details.moreWarnings == 25)
            #expect(details.warnings.allSatisfy { $0.count <= ImportDetails.maxWarningLength })
        }

        @Test func theSummaryComesFromTheResult() {
            let result = ImporterResult(
                notes: [ImporterNoteOutcome(source: "/a/One.note", noteID: UUID(), status: .imported),
                        ImporterNoteOutcome(source: "/a/Two.note", noteID: nil, status: .skipped("already in the vault")),
                        ImporterNoteOutcome(source: "/a/Three.note", noteID: nil, status: .failed("not a note"))],
                imported: [], leftOut: []) { _, _ in ImporterPresentation(lines: [.init("one line")]) }
            let at = Date(timeIntervalSince1970: 1_800_000_000)
            let summary = ImportSummary(source: "Fake", result: result, at: at)
            #expect(summary.imported == 1 && summary.skipped == 1 && summary.failed == 1)
            #expect(summary.failures == ["Three.note: not a note"])
            #expect(!summary.nothingFound && !summary.wasCancelled)
            #expect(summary.details.date == at)
            #expect(summary.details.noteLines == ["one line"])
            #expect(ImportSummary(source: "Fake", imported: 0, skipped: 0, failed: 0, failures: [], nothingFound: true).nothingFound)
            #expect(ImportSummary(source: "Fake", imported: 2, skipped: 0, failed: 0, failures: []).details.date == nil)
        }

        @Test func thePickerKindsFollowTheImportersExtensions() {
            #expect(AppModel.importFileKinds(for: FakeImporter()) == [.zip, .folder, .fileExtension("fake")])
        }

        @Test func aFakeImporterRunsThroughTheModel() async throws {
            let model = try await ExportTests.model()
            defer { model.close() }
            let fake = FakeImporter(notes: [ImporterNoteOutcome(source: "/a/One.note", noteID: nil, status: .imported)],
                                    imported: [ImporterCount(id: "images", english: "Images", count: 1)])
            let file = try Self.file("fake")
            defer { try? FileManager.default.removeItem(at: file) }
            try await model.importFromApp(fake, urls: [file], notebook: nil)
            let summary = try #require(model.importSummary)
            #expect(summary.imported == 1 && summary.source == "Fake")
            #expect(summary.details.imported.map(\.count) == [1])
            #expect(!model.isImporting)
        }

        @Test func anImportNeedsAnUnlockedVault() async throws {
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), services: .headless())
            defer { model.close() }
            await #expect(throws: AppModelError.noVaultOpen) {
                try await model.importFromApp(FakeImporter(), urls: [URL(fileURLWithPath: "/x.fake")], notebook: nil)
            }
            #expect(model.importSummary == nil)
        }

        /// The importer reports the fixture's "Lecture" as the note it wrote: its two pages were never read, so the
        /// recognition loop reads both (review of #29: a run that writes no note never reached the loop).
        @Test func recognitionAfterTheImportIsReported() async throws {
            let model = try await ExportTests.model()
            defer { model.close() }
            let reader = FakeRecognizer()
            model.recognizer = reader
            let file = try Self.file("fake")
            defer { try? FileManager.default.removeItem(at: file) }
            var options = ImportOptions()
            options.recognizeMissing = true
            var importer = FakeImporter()
            importer.notes = [ImporterNoteOutcome(source: file.path, noteID: ModelFixture.lecture, status: .imported)]
            try await model.importFromApp(importer, urls: [file], notebook: nil, options: options)
            let details = try #require(model.importSummary?.details)
            #expect(details.recognitionAsked)
            #expect(details.recognizedPages == 2)
            #expect(details.recognitionFailed == 0)
            #expect(reader.calls.count == 2)
            #expect(model.notes.first { $0.id == ModelFixture.lecture }?.pagesNeedingRecognition == 0)
        }

        // MARK: - Progress and Cancel

        @Test func progressIsPublishedWhileTheImportRuns() async throws {
            let model = try await ExportTests.model()
            defer { model.close() }
            let url = try Self.file("slow")
            defer { try? FileManager.default.removeItem(at: url) }
            let seen = LockedBox<(ImporterProgress?, Bool)>((nil, false))
            var importer = SlowFakeImporter(atNote: 10)
            importer.hook = {
                onMainAndWait {
                    _ = await TS.waitUntil(timeout: .seconds(30)) { model.importProgress?.phase == .writing }
                    seen.value = (model.importProgress, model.importCancellation != nil)
                }
            }
            try await model.importFromApp(importer, urls: [url], notebook: nil)
            let (progress, cancellable) = seen.value
            let mid = try #require(progress, "the bar moved while the import ran")
            #expect(mid.phase == .writing && (0..<10).contains(mid.done) && mid.total == 20)
            #expect(cancellable, "Cancel is offered")
            #expect(model.importProgress == nil && model.importCancellation == nil && !model.isImporting)
            let summary = try #require(model.importSummary)
            #expect(summary.imported == 20 && !summary.wasCancelled)
            #expect(model.lastImportReport == summary, "File > Last Import Report shows it again")
            #expect(summary.details.noteLines == (0..<20).map { "imported /b/N\($0).slow" })
            model.close()
            #expect(model.lastImportReport == nil, "the report goes with the vault")
        }

        @Test func cancelStopsBetweenNotesAndSaysHowManyWereLeft() async throws {
            let model = try await ExportTests.model()
            defer { model.close() }
            let url = try Self.file("slow")
            defer { try? FileManager.default.removeItem(at: url) }
            var importer = SlowFakeImporter(atNote: 10)
            importer.hook = { onMainAndWait { model.cancelImport() } }
            try await model.importFromApp(importer, urls: [url], notebook: nil)
            let summary = try #require(model.importSummary)
            #expect(summary.wasCancelled)
            #expect(summary.imported == 10 && summary.cancelled == 10)
            #expect(summary.skipped == 0, "cancelled notes are not counted as skipped")
        }
    }
}

/// A value shared with an importer's thread.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
