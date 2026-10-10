import Foundation
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// "Export to Folder or Zip…" (`AppModel+BulkExport`, `BulkExportRun`): selection →
/// jobs, folder export and resume, failures, cancel, zip archives, and the
/// command-line equivalent. The core (`BulkExportPlan`, `BulkExportSession`,
/// `ZipWriter`) is tested on Linux in SempereRenderTests and SempereImportTests.
@Suite(.serialized)
@MainActor
struct BulkExportAppTests {
    static let lecture = AppModelTests.lecture
    static let deleted = AppModelTests.deleted

    func folder() throws -> URL {
        try BrowserTests.tempDir().appendingPathComponent("bulk-out", isDirectory: true)
    }

    /// Files below `dir` (not the hidden manifest), relative to it.
    func files(_ dir: URL) -> [String] { TS.regularFiles(under: dir, skipHidden: true) }

    func run(_ model: AppModel, _ scope: BulkExportScope, _ options: BulkExportOptions, into dir: URL,
             progress: @escaping @MainActor (BulkExportProgress) -> Void = { _ in }) async throws -> BulkExportResult {
        let jobs = model.bulkExportJobs(scope, options: options)
        let session = try BulkExportSession(destination: .folder(dir), options: options, jobs: jobs)
        return try await model.runBulkExport(jobs, session: session, progress: progress)
    }

    // MARK: Selection → jobs

    @Test func scopesGiveJobs() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let options = BulkExportOptions(format: .pdf, layout: .flat)
        // The vault: deleted notes stay out.
        #expect(model.bulkExportJobs(.vault, options: options).map(\.noteId) == [Self.lecture])
        // A list selection keeps its order and may hold a deleted note.
        #expect(model.bulkExportJobs(.notes([Self.deleted, Self.lecture, UUID()]), options: options).map(\.noteId)
                == [Self.deleted, Self.lecture])
        // A notebook: the notes in it and below.
        let lecture = try #require(model.notes.first { $0.id == Self.lecture })
        if let nb = lecture.notebook {
            #expect(model.bulkExportJobs(.notebook(nb), options: options).map(\.noteId) == [Self.lecture])
        }
        #expect(model.bulkExportJobs(.notebook("No such notebook"), options: options).isEmpty)
    }

    @Test func menuScopeFollowsSelectionThenSidebar() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        #expect(model.bulkExportScope == .vault)
        model.sidebarSelection = .notebook("School")
        #expect(model.bulkExportScope == .notebook("School"))
        model.isSelectingNotes = true
        model.multiSelection = [Self.lecture]
        #expect(model.bulkExportScope == .notes([Self.lecture]))
    }

    @Test func requestsAreOneAtATime() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        model.requestBulkExport(.notes([]))
        #expect(model.bulkExportRequest == nil, "nothing to export")
        model.requestBulkExport(.vault)
        let first = try #require(model.bulkExportRequest)
        model.requestBulkExport(.notebook("x"))
        #expect(model.bulkExportRequest?.id == first.id)
        model.requestExport(.pdf, ids: [Self.lecture])
        #expect(model.exportRequest == nil, "no share export over a bulk export")
        model.close()
        #expect(model.bulkExportRequest == nil)
    }

    // MARK: Folder export

    @Test func folderExportWritesAndResumes() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let dir = try folder()
        let options = BulkExportOptions(format: .pdf, layout: .flat)
        let scope = BulkExportScope.notes([Self.lecture, Self.deleted])
        let first = try await run(model, scope, options, into: dir)
        #expect(first.exported.count == 2 && first.failures.isEmpty && !first.cancelled)
        #expect(files(dir).count == 2)
        #expect(files(dir).allSatisfy { $0.hasSuffix(".pdf") })
        // Again into the same folder: nothing changed, nothing rendered.
        let again = try await run(model, scope, options, into: dir)
        #expect(again.skipped.count == 2 && again.exported.isEmpty)
        // PNG pages are other files.
        let png = try await run(model, .notes([Self.lecture]), BulkExportOptions(format: .png, layout: .flat, dpi: 36), into: dir)
        #expect(png.exported.count == 1)
        #expect(files(dir).contains { $0.hasSuffix("/p001.png") })
    }

    @Test func exportDoesNotChangeTheVault() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let vault = try #require(model.vault?.url)
        let before = files(vault)
        _ = try await run(model, .notes([Self.lecture, Self.deleted]), BulkExportOptions(format: .pdfAttachments), into: try folder())
        #expect(files(vault) == before)
    }

    @Test func aNoteThatCannotBeReadIsReportedAndTheRestExported() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let dir = try folder()
        let options = BulkExportOptions(format: .pdf, layout: .flat)
        var jobs = model.bulkExportJobs(.notes([Self.lecture]), options: options)
        let ghost = BulkExportJob(noteId: UUID(), title: "Ghost", folder: [], stem: "Ghost-00000000")
        jobs.insert(ghost, at: 0)
        let session = try BulkExportSession(destination: .folder(dir), options: options, jobs: jobs)
        let result = try await model.runBulkExport(jobs, session: session) { _ in }
        #expect(result.exported.map(\.job.noteId) == [Self.lecture])
        #expect(result.failures.map(\.job.noteId) == [ghost.noteId])
        #expect(result.failureLines.first?.hasPrefix("Ghost (") == true)
        #expect(files(dir).count == 1)
    }

    // MARK: Cancel

    @Test func cancelStopsBetweenNotesAndKeepsWhatWasWritten() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let dir = try folder()
        let options = BulkExportOptions(format: .pdf, layout: .flat)
        let task = Task { () -> BulkExportResult in
            try await self.run(model, .notes([Self.lecture, Self.deleted]), options, into: dir) { p in
                if p.done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = try await task.value
        #expect(result.cancelled)
        #expect(result.exported.count == 1 && result.notReached == 1)
        #expect(files(dir).count == 1)
    }

    @Test func closingTheVaultStopsTheExport() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        await #expect(throws: CancellationError.self) {
            _ = try await self.run(model, .notes([Self.lecture, Self.deleted]), BulkExportOptions(format: .pdf),
                                   into: try self.folder()) { p in
                if p.done == 1 { model.close() }
            }
        }
    }

    // MARK: The run

    @Test func zipRunFinishesAndDiscardDeletesTheArchive() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let run = BulkExportRun()
        let request = BulkExportRequest(scope: .notes([Self.lecture, Self.deleted]))
        run.start(model: model, request: request, options: BulkExportOptions(format: .png, dpi: 36), target: .zip)
        let finished = await TS.waitUntil(timeout: .seconds(60)) { if case .finished = run.state { return true } else { return false } }
        #expect(finished)
        guard case .finished(let result) = run.state else { return }
        #expect(result.exported.count == 2)
        #expect(result.output.lastPathComponent == "Sempere Notes.zip")
        let data = try Data(contentsOf: result.output)
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        run.discard()
        #expect(run.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: result.output.path))
    }

    @Test func aFolderInsideTheVaultIsRefused() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let vault = try #require(model.vault?.url)
        let run = BulkExportRun()
        run.start(model: model, request: BulkExportRequest(scope: .vault), options: BulkExportOptions(format: .pdf),
                  target: .folder(vault.appendingPathComponent("exports"), scoped: false))
        guard case .failed(let why) = run.state else { Issue.record("\(run.state)"); return }
        #expect(why.contains("outside the vault"))
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("exports").path))
    }

    // MARK: Command line, menu, wording

    @Test func commandLineEquivalent() {
        let vault = BulkExportRequest(scope: .vault)
        #expect(vault.cliEquivalent(BulkExportOptions(format: .pdf), zip: false)
                == "sempere export --all --format pdf --layout notebooks --out FOLDER")
        #expect(vault.cliEquivalent(BulkExportOptions(format: .pdfAttachments, layout: .flat), zip: true)
                == "sempere export --all --format pdf --attachments --zip --out 'Sempere Notes.zip'")
        let nb = BulkExportRequest(scope: .notebook(" School // Bob's notes "))
        #expect(nb.cliEquivalent(BulkExportOptions(format: .png, paper: false, dpi: 300), zip: false)
                == "sempere export --all --notebook 'School/Bob'\\''s notes' --format png --dpi 300 --no-paper --layout notebooks --out FOLDER")
        #expect(nb.archiveName == "Bob's-notes.zip")
        #expect(vault.cliEquivalent(BulkExportOptions(format: .media, paper: false), zip: false)
                == "sempere export --all --format media --layout notebooks --out FOLDER", "media has no paper")
        #expect(BulkExportRequest(scope: .notes([Self.lecture])).cliEquivalent(BulkExportOptions(format: .pdf), zip: false) == nil)
    }

    @Test func fileMenuCommand() {
        #expect(MenuCommand.bulkExport.title == "Export to Folder or Zip…")
        #expect(MenuLayout.all.contains(.bulkExport))
        #expect(!MenuCommand.bulkExport.isEnabled(in: MenuCommand.Context(window: .library, vault: .locked)))
        #expect(MenuCommand.bulkExport.isEnabled(in: MenuCommand.Context(window: .library, vault: .unlocked)))
        #expect(!MenuCommand.bulkExport.isEnabled(in: MenuCommand.Context(window: .note, vault: .unlocked)))
    }

    @Test func sheetDescribesTheShape() {
        for format in BulkExportFormat.allCases {
            #expect(BulkExportSheet.shape(BulkExportOptions(format: format), zip: false).contains("skips"))
            #expect(BulkExportSheet.shape(BulkExportOptions(format: format), zip: true).contains("zip"))
        }
    }

    /// The finished zip's Share… and Save… go through `ExportHandOff` like a
    /// single note's export (#103): on a Mac UIKit presents them from the
    /// button, never a SwiftUI sheet hosted in this sheet (the build 7 Mac
    /// export crash); elsewhere, or before the anchor exists, the sheets.
    @Test func theZipHandOffAvoidsSwiftUISheetsOnAMac() {
        let zip = [URL(fileURLWithPath: "/tmp/notes.zip")]
        var sheets: [Bool] = []
        let anchor = PresentationAnchor.Box()
        for save in [false, true] {
            #expect(!ExportHandOff.deliver(zip, save: save, anchor: anchor, isMac: true) { sheets.append($0) })
        }
        #expect(sheets == [false, true], "no anchor yet: the sheets")
        let view = UIView()
        anchor.view = view
        sheets = []
        for save in [false, true] {
            #expect(ExportHandOff.deliver(zip, save: save, anchor: anchor, isMac: true) { sheets.append($0) })
            #expect(!ExportHandOff.deliver(zip, save: save, anchor: anchor, isMac: false) { sheets.append($0) })
        }
        #expect(sheets == [false, true], "a Mac never uses the SwiftUI sheets once the anchor exists")
    }
}
