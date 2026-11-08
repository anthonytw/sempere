import Foundation
import Sempere
import SempereAppCore
import SempereRender
import TempDirSupport
import Testing

/// What an export reported as it went, in order.
@MainActor
final class ProgressRecorder {
    var seen: [ExportProgress] = []
}

extension AppModelSuites {
    /// Share/export through the model (`AppModel+Export`, `ExportJob`; moved from the app's `ExportTests`, which keeps
    /// the commands' and the sheet's words): what each format hands to the share sheet, the job around it (progress,
    /// cancel, clean-up) and the commands' targets, on the headless rendering (no PDFKit, ImageIO or CoreText). The
    /// renderers themselves are tested in SempereRenderTests (`ShareExportTests`). In the serialized parent suite:
    /// `purgeStaleRemovesStagedExports` deletes the shared staging folder the job tests write to.
    @MainActor
    struct ExportTests {
        static let lecture = ModelFixture.lecture
        static let deleted = ModelFixture.deleted
        static let lectureStem = "Fixture-lecture-11111111"

        /// A model on a private copy of the fixture vault, unlocked; closed by the caller (and here when setup throws).
        static func model(editorDebounce: Duration = NoteEditorDefaults.debounce) async throws -> AppModel {
            let (url, key) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: editorDebounce, services: .headless())
            do {
                try await model.openVault(at: url)
                try await model.unlock(identityText: try await ModelFixture.keyText(key))
            } catch {
                model.close()
                throw error
            }
            return model
        }

        func scratch() throws -> URL {
            TestTemp.root.appendingPathComponent("export-test-\(UUID().uuidString)")
        }

        /// Paths of every file below `dir`, relative to it.
        func files(_ dir: URL) -> [String] { TS.regularFiles(under: dir) }

        func export(_ model: AppModel, _ ids: [UUID], _ options: ShareOptions, into dir: URL) async throws -> ShareResult {
            try await model.exportNotes(ids, options: options, into: dir) { _ in }
        }

        // MARK: Formats

        @Test func pdfOfOneNote() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let dir = try scratch()
            let r = try await export(model, [Self.lecture], ShareOptions(format: .pdf), into: dir)
            #expect(r.items.map(\.lastPathComponent) == [Self.lectureStem + ".pdf"])
            #expect(r.exported == 1 && r.failures.isEmpty)
            let data = try Data(contentsOf: r.items[0])
            #expect(data.prefix(5) == Data("%PDF-".utf8))
            #expect(data.count > 500)
        }

        @Test func pngPagesOfOneNote() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let r = try await export(model, [Self.lecture], ShareOptions(format: .png, dpi: 36), into: try scratch())
            // The fixture lecture has two pages.
            #expect(r.items.map(\.lastPathComponent) == [Self.lectureStem + "-p001.png", Self.lectureStem + "-p002.png"])
            for url in r.items {
                #expect(try Data(contentsOf: url).prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
            }
        }

        @Test func markdownOfOneNoteIsOneFileByDefault() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let r = try await export(model, [Self.lecture], ShareOptions(format: .markdown), into: try scratch())
            #expect(r.items.map(\.lastPathComponent) == [Self.lectureStem + ".md"])
            let md = try String(contentsOf: r.items[0], encoding: .utf8)
            #expect(md.contains("title: \"Fixture lecture\""))
            #expect(!md.contains(".pdf"))
        }

        @Test func markdownOfOneNoteWithThePDFIsAFolder() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let r = try await export(model, [Self.lecture], ShareOptions(format: .markdown, markdownPDF: true),
                                     into: try scratch())
            #expect(r.items.map(\.lastPathComponent) == [Self.lectureStem])
            let names = files(r.items[0])
            #expect(names.contains(Self.lectureStem + ".md"))
            #expect(names.contains(Self.lectureStem + ".pdf"))
            #expect(!names.contains { $0.hasPrefix(".") }, "no export manifest in a shared copy")
            let md = try String(contentsOf: r.items[0].appendingPathComponent(Self.lectureStem + ".md"), encoding: .utf8)
            #expect(md.hasPrefix("---\n"))
            #expect(md.contains("title: \"Fixture lecture\""))
            #expect(md.contains("sempere:\(model.vault?.vaultId.uuidString.lowercased() ?? "?")"))
        }

        @Test func htmlOfOneNoteIsOneSelfContainedFile() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let dir = try scratch()
            let r = try await export(model, [Self.lecture], ShareOptions(format: .html), into: dir)
            #expect(r.items.map(\.lastPathComponent) == [Self.lectureStem + ".html"])
            #expect(files(dir) == [Self.lectureStem + ".html"])
            let html = try String(contentsOf: r.items[0], encoding: .utf8)
            #expect(html.hasPrefix("<!DOCTYPE html>"))
            #expect(html.contains("<svg"))
            #expect(html.contains("Fixture lecture"))
            #expect(!html.contains("<script") && !html.contains("https://"))
        }

        @Test func severalNotesGiveTreesAndFolders() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let both = [Self.lecture, Self.deleted]
            let html = try await export(model, both, ShareOptions(format: .html), into: try scratch())
            #expect(html.items.map(\.lastPathComponent) == [ShareExport.treeFolderName])
            #expect(html.exported == 2)
            let htmlFiles = files(html.items[0])
            #expect(htmlFiles.contains("index.html"))
            #expect(htmlFiles.filter { $0.hasSuffix(".html") }.count == 3, "two notes and the index: \(htmlFiles)")

            let md = try await export(model, both, ShareOptions(format: .markdown, markdownPDF: true), into: try scratch())
            #expect(md.items.map(\.lastPathComponent) == [ShareExport.treeFolderName])
            #expect(files(md.items[0]).filter { $0.hasSuffix(".pdf") }.count == 2)
            let text = try await export(model, both, ShareOptions(format: .markdown), into: try scratch())
            #expect(files(text.items[0]).filter { $0.hasSuffix(".pdf") }.isEmpty)
            #expect(files(text.items[0]).filter { $0.hasSuffix(".md") }.count == 3, "two notes and the README")

            let merged = try await export(model, both, ShareOptions(format: .pdf, mergePDF: true), into: try scratch())
            #expect(merged.items.map(\.lastPathComponent) == [ShareExport.mergedPDFName])

            let separate = try await export(model, both, ShareOptions(format: .pdf), into: try scratch())
            #expect(separate.items.count == 2)

            let png = try await export(model, both, ShareOptions(format: .png, dpi: 36), into: try scratch())
            #expect(png.items.count == 2)
            #expect(png.items.allSatisfy { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        }

        /// Audit B10: ink still waiting for its autosave is in the export (the
        /// open note is saved first, as a drag-out does).
        @Test func unsavedInkOfTheOpenNoteIsExported() async throws {
            let model = try await Self.model(editorDebounce: .seconds(60))
            defer { model.close() }
            func paths() async throws -> Int {
                let r = try await export(model, [Self.lecture], ShareOptions(format: .html), into: try scratch())
                return try String(contentsOf: try #require(r.items.first), encoding: .utf8).components(separatedBy: "<path").count
            }
            let before = try await paths()
            model.selectedNoteID = Self.lecture
            try await model.openEditor(for: Self.lecture)
            let editor = try #require(model.editor)
            let page = try #require(editor.currentPage)
            var canvas = editor.drawing(for: page.id)
            canvas.strokes.append(TS.canvasStroke(TS.stroke(x: 200, y: 700)))
            editor.drawingDidChange(pageID: page.id, drawing: canvas, tool: nil)
            #expect(editor.deltasWritten == 0, "waiting for the autosave")
            #expect(try await paths() > before, "the new stroke is exported")
            #expect(editor.deltasWritten == 1)
        }

        @Test func aMissingNoteIsReportedAndTheRestExported() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let ghost = UUID()
            let r = try await export(model, [ghost, Self.lecture], ShareOptions(format: .pdf), into: try scratch())
            #expect(r.exported == 1)
            #expect(r.items.count == 1)
            #expect(r.failures.count == 1 && r.failures[0].hasPrefix(ghost.uuidString.lowercased()))
        }

        @Test func exportingNeedsAnUnlockedVault() async throws {
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), services: .headless())
            defer { model.close() }
            await #expect(throws: AppModel.ModelError.noVaultOpen) {
                _ = try await model.exportNotes([Self.lecture], options: ShareOptions(format: .pdf), into: try self.scratch()) { _ in }
            }
        }

        @Test func exportDoesNotChangeTheVault() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let url = try #require(model.vaultURL)
            func snapshot() -> [String: Int] {
                Dictionary(uniqueKeysWithValues: files(url).map { ($0, (try? Data(contentsOf: url.appendingPathComponent($0)).count) ?? -1) })
            }
            let before = snapshot()
            for format in ShareFormat.allCases {
                _ = try await export(model, [Self.lecture], ShareOptions(format: format, dpi: 36), into: try scratch())
            }
            #expect(snapshot() == before)
        }

        // MARK: Cancel and progress

        @Test func cancellingBeforeTheFirstNoteWritesNothing() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let dir = try scratch()
            let task = Task { try await self.export(model, [Self.lecture, Self.deleted], ShareOptions(format: .pdf), into: dir) }
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }

        @Test func closingTheVaultStopsTheExport() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let dir = try scratch()
            // Closed while the export is under way (reading the second note), not
            // before it starts: the generation token must stop it.
            await #expect(throws: CancellationError.self) {
                _ = try await model.exportNotes([Self.lecture, Self.deleted], options: ShareOptions(format: .pdf), into: dir) { p in
                    if p.phase == .reading && p.done == 1 { model.close() }
                }
            }
            #expect(files(dir).isEmpty)
        }

        @Test func progressGrowsFromReadingToRendering() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let recorder = ProgressRecorder()
            let r = try await model.exportNotes([Self.lecture, Self.deleted], options: ShareOptions(format: .pdf), into: try scratch()) {
                recorder.seen.append($0)
            }
            let seen = recorder.seen
            #expect(r.exported == 2)
            #expect(seen.first?.phase == .reading && seen.first?.total == 2)
            #expect(seen.contains { $0.phase == .rendering })
            #expect(seen.allSatisfy { (0...1).contains($0.fraction) })
            #expect(ExportProgress(phase: .reading, done: 0, total: 4).fraction == 0)
            #expect(ExportProgress(phase: .rendering, done: 4, total: 4).fraction == 1)
            #expect(ExportProgress(phase: .rendering, done: 0, total: 0).fraction == 0)
        }

        // MARK: The job

        @Test func jobFinishesWithFilesAndDiscardDeletesThem() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let job = ExportJob()
            job.start(model: model, ids: [Self.lecture], options: ShareOptions(format: .pdf))
            let finished = await TS.waitUntil(timeout: .seconds(30)) { if case .finished = job.state { return true } else { return false } }
            #expect(finished)
            guard case .finished(let outcome) = job.state else { return }
            #expect(outcome.exported == 1)
            let file = try #require(outcome.items.first)
            #expect(file.path.hasPrefix(ExportJob.scratchRoot.standardizedFileURL.path) || file.path.contains("SempereExports"))
            #expect(FileManager.default.fileExists(atPath: file.path))
            job.discard()
            #expect(job.state == .idle)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }

        /// The staging folders under `ExportJob.scratchRoot`.
        func staged() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: ExportJob.scratchRoot.path)) ?? [])
        }

        @Test func jobCancelLeavesNothingBehind() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let job = ExportJob()
            let before = staged()
            job.start(model: model, ids: [Self.lecture, Self.deleted], options: ShareOptions(format: .png, dpi: 36))
            job.cancel()
            let settled = await TS.waitUntil(timeout: .seconds(30)) { !job.isRunning }
            #expect(settled)
            // Stopped: idle again, even if the run got to its end before it saw the cancel.
            #expect(job.state == .idle)
            #expect(staged().subtracting(before).isEmpty)
        }

        /// The sheet going away mid-run (`discard`, e.g. the vault was closed):
        /// the note being rendered still finishes, and its files must not stay.
        @Test func discardingARunningJobLeavesNoFilesOnceTheRunEnds() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let job = ExportJob()
            let before = staged()
            job.start(model: model, ids: [Self.lecture, Self.deleted], options: ShareOptions(format: .png, dpi: 72))
            // Usually mid-render; a fast run may already be over, which discard must clean up too.
            let started = await TS.waitUntil(timeout: .seconds(30)) {
                if case .running(let p) = job.state { return p.phase == .rendering }
                return !job.isRunning
            }
            #expect(started)
            job.discard()
            #expect(job.state == .idle)
            let cleaned = await TS.waitUntil(timeout: .seconds(30)) { self.staged().subtracting(before).isEmpty }
            #expect(cleaned)
            // And a late result never reaches the job. A negative check: nothing to wait on, so a short pause.
            try await Task.sleep(for: .milliseconds(200))
            #expect(job.state == .idle)
        }

        @Test func jobFailsWhenNothingCouldBeExported() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let job = ExportJob()
            job.start(model: model, ids: [UUID()], options: ShareOptions(format: .pdf))
            let done = await TS.waitUntil(timeout: .seconds(30)) { if case .failed = job.state { return true } else { return false } }
            #expect(done)
            if case .failed(let failure) = job.state {
                guard case .noteFailed = failure else { Issue.record("not the note's failure: \(failure)"); return }
            }
            job.discard()
        }

        @Test func purgeStaleRemovesStagedExports() throws {
            let stale = ExportJob.scratchRoot.appendingPathComponent("stale-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: stale.appendingPathComponent("n.pdf"))
            ExportJob.purgeStale()
            #expect(!FileManager.default.fileExists(atPath: stale.path))
        }

        /// The text export needs recognized handwriting in some selected note.
        @Test func textExportNeedsRecognisedText() async throws {
            let model = try await Self.model()
            defer { model.close() }
            // The fixture has no recognized text; pretend the lecture has some.
            let i = try #require(model.notes.firstIndex { $0.id == Self.lecture })
            #expect(!model.canExport(.markdown, ids: [Self.lecture, Self.deleted]))
            model.requestExport(.markdown, ids: [Self.lecture])
            #expect(model.exportRequest == nil)
            #expect(model.canExport(.pdf, ids: [Self.deleted]))
            model.notes[i].recognizedPages = 1
            #expect(model.canExport(.markdown, ids: [Self.lecture, Self.deleted]))
            #expect(!model.canExport(.markdown, ids: [Self.deleted]))
            #expect(!model.canExport(.pdf, ids: []))
        }

        /// The media export needs a note with a recording, video, image or PDF.
        @Test func mediaExportNeedsMedia() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let i = try #require(model.notes.firstIndex { $0.id == Self.lecture })
            model.notes[i].recordings = 0
            model.notes[i].blobs = []
            #expect(!model.canExport(.media, ids: [Self.lecture]))
            model.notes[i].blobs = [BlobRef(content: Data("x".utf8), type: "image/png")]
            #expect(model.canExport(.media, ids: [Self.lecture]))
            model.notes[i].blobs = [BlobRef(content: Data("x".utf8), type: BlobRef.transcriptType)]
            #expect(!model.canExport(.media, ids: [Self.lecture]), "a transcript alone is not media")
            model.notes[i].recordings = 1
            #expect(model.canExport(.media, ids: [Self.lecture]))
        }

        @Test func requestsAndTargets() async throws {
            let model = try await Self.model()
            defer { model.close() }
            #expect(model.exportTargetIDs.isEmpty)
            model.requestExport(.pdf, ids: [])
            #expect(model.exportRequest == nil, "nothing to export")

            model.selectedNoteID = Self.lecture
            #expect(model.exportTargetIDs == [Self.lecture])
            model.requestExport(.png, ids: model.exportTargetIDs)
            #expect(model.exportRequest?.noteIDs == [Self.lecture])
            #expect(model.exportRequest?.format == .png)
            // A second command while the sheet is up does not replace (and so dismiss) it.
            let first = model.exportRequest?.id
            model.requestExport(.pdf, ids: [Self.deleted])
            #expect(model.exportRequest?.id == first)
            #expect(model.exportRequest?.format == .png)

            model.isSelectingNotes = true
            model.multiSelection = [Self.lecture, Self.deleted, UUID()]
            // Only notes still in the vault, in list order (title sort).
            #expect(model.exportTargetIDs == [Self.deleted, Self.lecture])

            model.close()
            #expect(model.exportRequest == nil && model.multiSelection.isEmpty && !model.isSelectingNotes)
        }
    }
}
