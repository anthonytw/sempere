import Foundation
import Sempere
import SempereImport
import Testing
@testable import SempereApp
import SempereAppCore

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

/// The words of an import from other apps (`Import+Text.swift`): the report's rows, the alert's title and lines, the
/// saved report and the picker's types. The model's import, its options, report and progress are `ImportTests` in
/// `SempereAppCoreTests`.
@MainActor
struct ImportReportTests {
    @Test func theRowsAreNamedInTheAppsWords() {
        let result = ImporterResult(
            notes: [],
            imported: [ImporterCount(id: "pdfPages", english: "pdf pages", count: 4), ImporterCount(id: "mystery", english: "Mystery items", count: 2)],
            leftOut: [ImporterCount(id: "dashedStrokes", english: "dashed strokes", count: 3)]) { _, _ in ImporterPresentation() }
        let details = ImportDetails(result)
        #expect(details.imported.map(\.label) == ["PDF pages", "Mystery items"], "an id the app does not know shows the importer's words")
        #expect(details.notImported.map(\.label) == ["Dashed strokes (imported solid)"])
    }

    @Test func theAlertSaysWhatHappened() {
        let result = ImporterResult(
            notes: [ImporterNoteOutcome(source: "/a/One.note", noteID: UUID(), status: .imported),
                    ImporterNoteOutcome(source: "/a/Three.note", noteID: nil, status: .failed("not a note"))],
            imported: [], leftOut: []) { _, _ in ImporterPresentation() }
        #expect(ImportSummary(source: "Fake", result: result).title == "Import Finished with Errors")
        let ok = ImportSummary(source: "Fake", imported: 2, skipped: 0, failed: 0, failures: [])
        #expect(ok.title == "Fake Import")
        #expect(ok.reportText.isEmpty, "no importer's result, nothing to save")
        #expect(ImportSummary(source: "Fake", imported: 0, skipped: 0, failed: 0, failures: [], nothingFound: true)
            .message.contains("No notes from Fake"))
        var cancelled = ok
        cancelled.wasCancelled = true
        cancelled.cancelled = 3
        #expect(cancelled.title == "Import Canceled")
        #expect(cancelled.message.contains("not imported because you canceled"))
    }

    @Test func theMessageMentionsTheReadPages() {
        var summary = ImportSummary(source: "Fake", imported: 2, skipped: 0, failed: 0, failures: [])
        summary.details.recognitionAsked = true
        summary.details.recognizedPages = 3
        #expect(summary.message.contains("3"))
        summary.details.recognitionFailed = 1
        #expect(summary.message.split(separator: "\n").count == 3)
    }

    /// Save Report…: the alert's lines, the totals and every note's line, as a `.txt` file in the temporary folder.
    @Test func theReportIsSavedAsTextWithEveryNote() throws {
        let notes = (0..<3).map { ImporterNoteOutcome(source: "/b/N\($0).slow", noteID: nil, status: .imported) }
        let result = ImporterResult(notes: notes, imported: [ImporterCount(id: "images", english: "Images", count: 2)],
                                    leftOut: []) { _, _ in
            ImporterPresentation(lines: notes.map { .init("imported \($0.source)") })
        }
        let summary = ImportSummary(source: "Slow", result: result)
        let text = summary.reportText
        #expect(text.contains("3 notes imported."))
        #expect(text.contains("  Images: 2"))
        for i in 0..<3 { #expect(text.contains("imported /b/N\(i).slow")) }
        let file = try ImportReportText.write(text)
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        #expect(file.pathExtension == "txt")
        ImportReportText.discard(file)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test func thePickerTypesFollowTheImportersExtensions() {
        let types = AppModel.importTypes(for: FakeImporter())
        #expect(types.contains(.zip) && types.contains(.folder))
        #expect(types.count == 2 || types.contains { $0.tags[.filenameExtension]?.contains("fake") == true })
    }

    /// File > Last Import Report is offered once the vault has a report (`WindowCommands.fill`).
    @Test func theLastReportIsOfferedOnceThereIsOne() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        func context() -> MenuCommand.Context {
            var c = MenuCommand.Context()
            c.vault = .unlocked
            c.window = .library
            WindowCommands.fill(&c, model: model, exportIDs: [])
            return c
        }
        #expect(!MenuCommand.lastImportReport.isEnabled(in: context()))
        model.lastImportReport = ImportSummary(source: "Fake", imported: 1, skipped: 0, failed: 0, failures: [])
        #expect(MenuCommand.lastImportReport.isEnabled(in: context()))
    }
}
