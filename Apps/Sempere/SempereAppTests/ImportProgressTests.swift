import Foundation
import Sempere
import SempereAppCore
import SempereImport
import SempereImporters
import SempereRender
import Testing
@testable import SempereApp

/// The import's progress line, and the real importer on a synthetic backup (never the owner's notes) with progress,
/// Cancel and the saved report (c23). Progress and Cancel on a fake importer are `ImportTests` in `SempereAppCoreTests`.
@MainActor
@Suite(.serialized)
struct ImportProgressTests {

    @Test func theProgressLineNamesThePhase() {
        #expect(ImportProgressOverlay.phaseLine(ImporterProgress(phase: .reading, done: 3, total: 9)) == "Reading note 3 of 9")
        #expect(ImportProgressOverlay.phaseLine(ImporterProgress(phase: .writing, done: 9, total: 9)) == "Importing note 9 of 9")
        let fractions = [ImporterProgress(phase: .finding, done: 0, total: 0), .init(phase: .reading, done: 5, total: 10),
                         .init(phase: .reading, done: 10, total: 10), .init(phase: .writing, done: 0, total: 10),
                         .init(phase: .writing, done: 10, total: 10)].map(\.fraction)
        #expect(fractions == fractions.sorted() && fractions.last == 1)
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

    @Test(.enabled(if: BuiltInImporters.primary != nil)) func aLargeSyntheticBackupImportsWithProgressAndAReport() async throws {
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
        try await model.importFromApp(try #require(BuiltInImporters.primary), urls: backup.parts, notebook: nil)
        watcher.cancel()
        let summary = try #require(model.importSummary)
        #expect(summary.imported == backup.notes, "\(summary.failures)")
        #expect(summary.skipped == backup.copies)
        #expect(summary.failed == 0, "none fails on a read budget: \(summary.failures)")
        #expect(model.notes.count == before + backup.notes)
        #expect(phases.contains("writing"), "progress reached the model: \(phases)")
        #expect(maxDone > 0)
        #expect(summary.reportText.split(separator: "\n").count > backup.notes, "a line per file in the saved report")

        // Again: all already in the vault.
        try await model.importFromApp(try #require(BuiltInImporters.primary), urls: backup.parts, notebook: nil)
        #expect(model.importSummary?.imported == 0)
        #expect(model.importSummary?.skipped == backup.notes + backup.copies)
        model.close()
    }

    @Test(.enabled(if: BuiltInImporters.primary != nil)) func cancellingTheRealImporterKeepsWholeNotesAndAReRunFinishes() async throws {
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
        try await model.importFromApp(try #require(BuiltInImporters.primary), urls: backup.parts, notebook: nil)
        await canceller.value
        let first = try #require(model.importSummary)
        #expect(first.wasCancelled, "the import was stopped (if this fails, the machine imported 150 notes before the cancel landed)")
        #expect(first.imported + first.cancelled + first.skipped == backup.notes + backup.copies)
        #expect(model.notes.count == before + first.imported)
        // Every note on disk reads whole.
        let vault = try #require(model.vault)
        for id in try vault.noteIDs() { _ = try vault.reconstruct(noteId: id) }

        try await model.importFromApp(try #require(BuiltInImporters.primary), urls: backup.parts, notebook: nil)
        let second = try #require(model.importSummary)
        #expect(!second.wasCancelled)
        #expect(first.imported + second.imported == backup.notes)
        #expect(model.notes.count == before + backup.notes)
        model.close()
    }
}

private final class ImportProgressToken {}
