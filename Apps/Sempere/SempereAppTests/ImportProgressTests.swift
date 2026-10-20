import Foundation
import Sempere
import SempereImport
import SempereRender
import Testing
@testable import SempereApp

/// An importer that takes its time over `count` notes, reporting progress and stopping when cancelled, as the
/// Notability importer does (device check c23: the owner saw no progress during a long import).
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
    var count = 40
    var pause: TimeInterval = 0.02

    func run(_ request: ImporterRequest, clock: inout HybridClock) throws -> ImporterResult {
        request.progress?(ImporterProgress(phase: .finding, done: 0, total: 0))
        var notes: [ImporterNoteOutcome] = []
        var stopped = false
        for i in 0..<count {
            if request.cancellation?.isCancelled == true { stopped = true }
            if stopped {
                notes.append(ImporterNoteOutcome(source: "/b/N\(i).slow", noteID: nil, status: .skipped(ImporterResult.cancelledReason)))
                continue
            }
            request.progress?(ImporterProgress(phase: .writing, done: i, total: count, current: "N\(i).slow"))
            Thread.sleep(forTimeInterval: pause)
            notes.append(ImporterNoteOutcome(source: "/b/N\(i).slow", noteID: nil, status: .imported))
        }
        let outcome = notes
        return ImporterResult(notes: outcome, imported: [], leftOut: [], cancelled: stopped) { _, _ in
            ImporterPresentation(lines: outcome.map { .init("\($0.status == .imported ? "imported" : "skipped") \($0.source)") })
        }
    }
}

/// The app's import progress, Cancel and saved report (c23), on a fake and on the real importer with a synthetic
/// backup (never the owner's notes).
@MainActor
@Suite(.serialized)
struct ImportProgressTests {
    static func file() throws -> URL {
        let url = TestTemp.root.appendingPathComponent("x-\(UUID().uuidString).slow")
        try Data().write(to: url)
        return url
    }

    @Test func progressIsPublishedWhileTheImportRuns() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        var seen: [ImporterProgress] = []
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let p = model.importProgress, seen.last != p { seen.append(p) }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        try await model.importFromApp(SlowFakeImporter(), urls: [url], notebook: nil)
        watcher.cancel()
        let writing = seen.filter { $0.phase == .writing }
        #expect(writing.count >= 5, "the bar moved: \(seen.count) updates")
        #expect(writing.map(\.done) == writing.map(\.done).sorted(), "never backwards")
        #expect(model.importProgress == nil && model.importCancellation == nil && !model.isImporting)
        let summary = try #require(model.importSummary)
        #expect(summary.imported == 40 && !summary.wasCancelled)
        #expect(model.lastImportReport == summary.details, "File > Last Import Report shows it again")
        #expect(MenuCommand.lastImportReport.isEnabled(in: Self.context(model)))
        model.close()
        #expect(model.lastImportReport == nil, "the report goes with the vault")
    }

    @Test func cancelStopsBetweenNotesAndSaysHowManyWereLeft() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        let canceller = Task { @MainActor in
            while (model.importProgress?.done ?? 0) < 10 { try? await Task.sleep(for: .milliseconds(5)) }
            #expect(model.importCancellation != nil, "Cancel is offered")
            model.cancelImport()
        }
        try await model.importFromApp(SlowFakeImporter(), urls: [url], notebook: nil)
        await canceller.value
        let summary = try #require(model.importSummary)
        #expect(summary.wasCancelled)
        #expect(summary.title == "Import Canceled")
        #expect(summary.cancelled > 0 && summary.imported + summary.cancelled == 40)
        #expect(summary.skipped == 0, "cancelled notes are not counted as skipped")
        #expect(summary.message.contains("not imported because you canceled"))
        model.close()
    }

    @Test func theReportIsSavedAsTextWithEveryNote() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        try await model.importFromApp(SlowFakeImporter(count: 3, pause: 0), urls: [url], notebook: nil)
        let details = try #require(model.importSummary?.details)
        #expect(details.text.contains("3 notes imported."))
        for i in 0..<3 { #expect(details.text.contains("imported /b/N\(i).slow")) }
        let file = try ImportReportText.write(details.text)
        #expect(try String(contentsOf: file, encoding: .utf8) == details.text)
        #expect(file.pathExtension == "txt")
        ImportReportText.discard(file)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        model.close()
    }

    @Test func theProgressLineNamesThePhase() {
        #expect(ImportProgressOverlay.phaseLine(ImporterProgress(phase: .reading, done: 3, total: 9)) == "Reading note 3 of 9")
        #expect(ImportProgressOverlay.phaseLine(ImporterProgress(phase: .writing, done: 9, total: 9)) == "Importing note 9 of 9")
        let fractions = [ImporterProgress(phase: .finding, done: 0, total: 0), .init(phase: .reading, done: 5, total: 10),
                         .init(phase: .reading, done: 10, total: 10), .init(phase: .writing, done: 0, total: 10),
                         .init(phase: .writing, done: 10, total: 10)].map(\.fraction)
        #expect(fractions == fractions.sorted() && fractions.last == 1)
    }

    static func context(_ model: AppModel) -> MenuCommand.Context {
        var c = MenuCommand.Context()
        c.vault = .unlocked
        c.window = .library
        WindowCommands.fill(&c, model: model, exportIDs: [])
        return c
    }

    // MARK: The real importer on a synthetic split backup

    /// `count` distinct notes made from the importer tests' synthetic `.note` (a new Notability uuid each), split
    /// over three zips, every fifth also as an identical copy in the next zip.
    static func syntheticBackup(count: Int) throws -> (parts: [URL], notes: Int, copies: Int) {
        let bundle = Bundle(for: ImportProgressToken.self)
        let fixture = try #require(bundle.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("notability/synthetic.note")
        let source = try ZipArchive(url: fixture)
        let uuid = Data("5A1E0000-0000-4000-8000-000000000001".utf8)
        let dir = TestTemp.root.appendingPathComponent("nb-backup-\(UUID().uuidString)")
        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var notes: [[(name: String, file: URL)]] = [[], [], []]
        var copies = 0
        for i in 0..<count {
            let note = staging.appendingPathComponent("\(i).note")
            let writer = try ZipWriter(url: note)
            for e in source.entries where !e.isDirectory {
                var data = try source.read(e)
                if e.path.hasSuffix("metadata.plist"), let r = data.range(of: uuid) {
                    data.replaceSubrange(r, with: Data(String(format: "5A1E%04X-0000-4000-8000-%012X", i & 0xFFFF, i).utf8))
                }
                let part = staging.appendingPathComponent("entry-\(UUID().uuidString)")
                try data.write(to: part)
                try writer.add(name: e.path, contentsOf: part)
                try FileManager.default.removeItem(at: part)
            }
            try writer.finish()
            notes[i % 3].append((name: "Notability/Folder \(i % 7)/Note \(i).note", file: note))
            if i % 5 == 0 {
                notes[(i + 1) % 3].append((name: "Notability/Copies/Note \(i) copy.note", file: note))
                copies += 1
            }
        }
        var parts: [URL] = []
        for (k, list) in notes.enumerated() {
            let url = dir.appendingPathComponent("Notability backup part \(k + 1).zip")
            let writer = try ZipWriter(url: url)
            for n in list { try writer.add(name: n.name, contentsOf: n.file) }
            try writer.finish()
            parts.append(url)
        }
        try FileManager.default.removeItem(at: staging)
        return (parts, count, copies)
    }

    @Test(.enabled(if: AppImporters.primary != nil)) func aLargeSyntheticBackupImportsWithProgressAndAReport() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let backup = try Self.syntheticBackup(count: 120)
        defer { try? FileManager.default.removeItem(at: backup.parts[0].deletingLastPathComponent()) }
        var phases = Set<String>()
        var maxDone = 0
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let p = model.importProgress { phases.insert(p.phase.rawValue); maxDone = max(maxDone, p.done) }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let before = model.notes.count
        try await model.importFromApp(try #require(AppImporters.primary), urls: backup.parts, notebook: nil)
        watcher.cancel()
        let summary = try #require(model.importSummary)
        #expect(summary.imported == backup.notes, "\(summary.failures)")
        #expect(summary.skipped == backup.copies)
        #expect(summary.failed == 0, "none fails on a read budget: \(summary.failures)")
        #expect(model.notes.count == before + backup.notes)
        #expect(phases.contains("writing"), "progress reached the model: \(phases)")
        #expect(maxDone > 0)
        #expect(summary.details.text.split(separator: "\n").count > backup.notes, "a line per file in the saved report")

        // Again: all already in the vault.
        try await model.importFromApp(try #require(AppImporters.primary), urls: backup.parts, notebook: nil)
        #expect(model.importSummary?.imported == 0)
        #expect(model.importSummary?.skipped == backup.notes + backup.copies)
        model.close()
    }

    @Test(.enabled(if: AppImporters.primary != nil)) func cancellingTheRealImporterKeepsWholeNotesAndAReRunFinishes() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let backup = try Self.syntheticBackup(count: 150)
        defer { try? FileManager.default.removeItem(at: backup.parts[0].deletingLastPathComponent()) }
        let before = model.notes.count
        let canceller = Task { @MainActor in
            while model.importProgress?.phase != .writing || (model.importProgress?.done ?? 0) < 5 {
                if !model.isImporting && model.importSummary != nil { return }
                try? await Task.sleep(for: .milliseconds(1))
            }
            model.cancelImport()
        }
        try await model.importFromApp(try #require(AppImporters.primary), urls: backup.parts, notebook: nil)
        await canceller.value
        let first = try #require(model.importSummary)
        #expect(first.wasCancelled, "the import was stopped (if this fails, the machine imported 150 notes before the cancel landed)")
        #expect(first.imported + first.cancelled + first.skipped == backup.notes + backup.copies)
        #expect(model.notes.count == before + first.imported)
        // Every note on disk reads whole.
        let vault = try #require(model.vault)
        for id in try vault.noteIDs() { _ = try vault.reconstruct(noteId: id) }

        try await model.importFromApp(try #require(AppImporters.primary), urls: backup.parts, notebook: nil)
        let second = try #require(model.importSummary)
        #expect(!second.wasCancelled)
        #expect(first.imported + second.imported == backup.notes)
        #expect(model.notes.count == before + backup.notes)
        model.close()
    }
}

private final class ImportProgressToken {}
