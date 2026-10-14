import Foundation
import Sempere
import SempereImport
import Testing
@testable import SempereApp

/// An importer that writes nothing: a double for the app's generic import path.
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

/// The app's import from other apps: the importer's options, the full report and the summary (GA-08).
@MainActor
struct ImportReportTests {
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
        #expect(details.imported.last?.label == "Mystery items", "an id the app does not know shows the importer's words")
        #expect(details.notImported.map(\.count) == [3])
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
            imported: [], leftOut: []) { _, _ in ImporterPresentation() }
        let summary = ImportSummary(source: "Fake", result: result)
        #expect(summary.imported == 1 && summary.skipped == 1 && summary.failed == 1)
        #expect(summary.failures == ["Three.note: not a note"])
        #expect(summary.title == "Import Finished with Errors")
        let ok = ImportSummary(source: "Fake", imported: 2, skipped: 0, failed: 0, failures: [])
        #expect(ok.title == "Fake Import")
        #expect(ImportSummary(source: "Fake", imported: 0, skipped: 0, failed: 0, failures: [], nothingFound: true)
            .message.contains("No notes from Fake"))
    }

    @Test func theMessageMentionsTheReadPages() {
        var summary = ImportSummary(source: "Fake", imported: 2, skipped: 0, failed: 0, failures: [])
        summary.details.recognitionAsked = true
        summary.details.recognizedPages = 3
        #expect(summary.message.contains("3"))
        summary.details.recognitionFailed = 1
        #expect(summary.message.split(separator: "\n").count == 3)
    }

    @Test func thePickerTypesFollowTheImportersExtensions() {
        let types = AppModel.importTypes(for: FakeImporter())
        #expect(types.contains(.zip) && types.contains(.folder))
        #expect(types.count == 2 || types.contains { $0.tags[.filenameExtension]?.contains("fake") == true })
    }

    @Test func aFakeImporterRunsThroughTheModel() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let fake = FakeImporter(notes: [ImporterNoteOutcome(source: "/a/One.note", noteID: nil, status: .imported)],
                                imported: [ImporterCount(id: "images", english: "Images", count: 1)])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).fake")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await model.importFromApp(fake, urls: [file], notebook: nil)
        let summary = try #require(model.importSummary)
        #expect(summary.imported == 1 && summary.source == "Fake")
        #expect(summary.details.imported.map(\.count) == [1])
        #expect(!model.isImporting)
        model.close()
    }

    @Test func recognitionAfterTheImportIsReported() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        model.recognizer = FakeRecognizer()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).fake")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var options = ImportOptions()
        options.recognizeMissing = true
        try await model.importFromApp(FakeImporter(), urls: [file], notebook: nil, options: options)
        #expect(model.importSummary?.details.recognitionAsked == true)
        #expect(model.importSummary?.details.recognitionFailed == 0)
        model.close()
    }
}
