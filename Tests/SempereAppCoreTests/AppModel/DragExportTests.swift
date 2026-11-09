import Foundation
import Sempere
import SempereAppCore
import SempereRender
import TempDirSupport
import Testing

extension AppModelSuites {
    /// A note dragged out to the Finder (`AppModel+DragExport`, wave 5b part 3, step 6b; moved from the app's
    /// `NoteWindowTests`, `MacCatalystTests` and `AppearanceSettingsTests`): the file in the model's export folder,
    /// drawn through `services.exportRendering`, refused with unreadable revisions, nothing written once the vault
    /// closed, and the formats. The app keeps the item providers, the `UTType`s, the words and the check that its
    /// renderers draw the same pages as before (`NoteWindowTests.theDraggedPDFDrawsThroughTheServicesAsBefore`).
    @MainActor
    struct DragExportTests {
        static let lecture = ModelFixture.lecture

        /// The fixture unlocked on `services` (headless by default); closed when the setup throws. `damaged` adds an
        /// unreadable revision to the lecture first.
        static func unlockedModel(services: AppModelServices? = nil, damaged: Bool = false) async throws -> AppModel {
            let (url, key) = try await ModelFixture.vault()
            if damaged {
                let dir = url.appendingPathComponent("notes/\(lecture.uuidString.lowercased())")
                try Data("not age".utf8).write(to: dir.appendingPathComponent("17000000000000000-deadbeef-1.delta.age"))
            }
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(200), services: services)
            do {
                try await model.openVault(at: url)
                try await model.unlock(identityText: try await ModelFixture.keyText(key))
            } catch {
                model.close()
                throw error
            }
            return model
        }

        @Test func exportWritesANamedPDFOfTheNote() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            let url = try await model.exportPDF(noteID: Self.lecture)
            #expect(url.lastPathComponent == "Fixture lecture.pdf")
            #expect(url.deletingLastPathComponent().deletingLastPathComponent() == model.exportFolder)
            let data = try Data(contentsOf: url)
            #expect(data.starts(with: Data("%PDF-".utf8)))
            #expect(data.count > 500)
        }

        @Test func exportsOfOneTitleDoNotCollide() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            let a = try await model.exportPDF(noteID: Self.lecture)
            let b = try await model.exportPDF(noteID: Self.lecture)
            #expect(a != b)
            #expect(a.lastPathComponent == b.lastPathComponent)
        }

        @Test func exportIncludesInkNotYetSaved() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            let before = try await model.exportPDF(noteID: Self.lecture)
            let beforeSize = try Data(contentsOf: before).count
            model.selectedNoteID = Self.lecture
            await model.showSelectedNote()
            let editor = try #require(model.editor)
            editor.addPage()
            let after = try await model.exportPDF(noteID: Self.lecture)
            #expect(try Data(contentsOf: after).count > beforeSize, "the new page is in the PDF")
        }

        @Test func exportNeedsAnUnlockedVault() async throws {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            defer { model.close() }
            await #expect(throws: AppModel.ModelError.noVaultOpen) { _ = try await model.exportPDF(noteID: Self.lecture) }
            await #expect(throws: AppModel.ModelError.noVaultOpen) { _ = try await model.prepareExport(noteID: Self.lecture) }
        }

        /// A note with an unreadable revision is refused, in every format, rather than written with pages missing.
        @Test func aNoteWithUnreadableRevisionsIsRefused() async throws {
            let model = try await Self.unlockedModel(damaged: true)
            defer { model.close() }
            await #expect(throws: DragExportError.unreadableRevisions(1)) { _ = try await model.exportPDF(noteID: Self.lecture) }
            let prepared = try await model.prepareExport(noteID: Self.lecture)
            for format in DragExportFormat.allCases {
                #expect(throws: DragExportError.unreadableRevisions(1)) { _ = try prepared.write(format: format) }
            }
            let left = (try? FileManager.default.contentsOfDirectory(atPath: model.exportFolder.path)) ?? []
            #expect(left.isEmpty, "nothing written")
        }

        /// A drag prepared before the vault closed writes nothing (`ExportEpoch`), in any format.
        @Test func aDragFromAClosedVaultWritesNothing() async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            let prepared = try await model.prepareExport(noteID: Self.lecture)
            model.close()   // the deferred close runs again at the end: `close()` is idempotent
            for format in DragExportFormat.allCases {
                #expect(throws: CancellationError.self) { _ = try prepared.write(format: format) }
            }
            let left = (try? FileManager.default.contentsOfDirectory(atPath: model.exportFolder.path)) ?? []
            #expect(left.isEmpty, "no plaintext file after the vault closed")
        }

        /// The file is drawn with `services.exportRendering`, its blobs the note's: a note with a PDF background and a
        /// text box is the PDF `PDFWriter` draws with those options, and the services' shaper lays the text box out.
        @Test func thePDFIsDrawnThroughTheServices() async throws {
            let shaper = RecordingShaper()
            var services = AppModelServices.headless()
            services.exportRendering = RenderOptions(shaper: shaper)
            let model = try await Self.unlockedModel(services: services)
            defer { model.close() }
            let vault = try #require(model.vault)
            let source = try InsertFixture.pdf(pages: 2)
            guard case .done(let id) = await model.importPDF(copy: source, to: .newNote(notebook: nil), password: nil) else {
                Issue.record("not imported: \(String(describing: model.alert))")
                return
            }
            model.selectedNoteID = id
            await model.showSelectedNote()
            let editor = try #require(model.editor)
            let page = try #require(editor.currentPage).id
            let content = TextContent(size: 18, color: .black, runs: [TextRun("Drawn by the shaper")])
            #expect(editor.addTextBox(content, frame: Rect(x: 120, y: 120, w: 240, h: 60), on: page) != nil)

            let prepared = try await model.prepareExport(noteID: id)   // saves the text box
            #expect(prepared.rendering.shaper is RecordingShaper, "the services' rendering")
            let url = try await model.offMain { try prepared.write() }
            #expect(shaper.texts.contains("Drawn by the shaper"), "the services' shaper laid the text box out")
            let written = try Data(contentsOf: url)
            let state = try vault.reconstruct(noteId: id)
            #expect(state.pages.count == 2 && state.pages.first?.items.contains { $0.kind == .text } == true)
            var options = services.exportRendering
            options.blobs = vault.blobSource(note: id)
            #expect(written == (try PDFWriter.render(note: state, options: options)))
        }

        /// A note dragged out as Markdown or HTML is that file, named after the note's title, in the export folder.
        @Test(arguments: [DragExportFormat.markdown, .html])
        func aDraggedNoteIsWrittenInTheChosenFormat(_ format: DragExportFormat) async throws {
            let model = try await Self.unlockedModel()
            defer { model.close() }
            let prepared = try await model.prepareExport(noteID: Self.lecture)
            let url = try await model.offMain { try prepared.write(format: format) }
            #expect(url.lastPathComponent == "Fixture lecture.\(format.fileExtension)")
            #expect(url.deletingLastPathComponent().deletingLastPathComponent() == model.exportFolder)
            let text = try String(contentsOf: url, encoding: .utf8)
            if format == .html {
                #expect(text.contains("<html") || text.contains("<!DOCTYPE"), "an HTML page")
            } else {
                #expect(text.contains("Fixture lecture"), "Markdown with the note's title")
            }
        }

        @Test func oldExportsArePurgedAndNewOnesKept() throws {
            let folder = TestTemp.root.appendingPathComponent("purge-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let rendered = NotePDFExport.Rendered(title: "T", pdf: Data("%PDF-1.4".utf8))
            let url = try NotePDFExport.write(rendered, in: folder)
            #expect(url.lastPathComponent == "T.pdf")
            NotePDFExport.purge(in: folder, olderThan: 600)
            #expect(FileManager.default.fileExists(atPath: url.path))
            NotePDFExport.purge(in: folder, olderThan: 600, now: Date().addingTimeInterval(3600))
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        /// Settings ▸ General ▸ Drag to Finder's choice, from a `KeyValueStore` (the app's is `UserDefaults`).
        @Test func theFormatIsStoredByKey() {
            let store = MemoryKeyValueStore()
            #expect(DragExportFormat.load(from: store) == .pdf)
            DragExportFormat.save(.markdown, to: store)
            #expect(DragExportFormat.load(from: store) == .markdown)
            store.set("sideways", forKey: DragExportFormat.key)
            #expect(DragExportFormat.load(from: store) == .pdf, "an unknown value is the default")
            #expect(DragExportFormat.allCases.map(\.fileExtension) == ["pdf", "md", "html"])
        }
    }
}

/// A text shaper that records what it was asked to lay out (and lays out nothing).
final class RecordingShaper: TextShaper, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []

    var texts: [String] { lock.withLock { asked } }

    func shape(_ text: TextContent, frame: Rect) throws -> ShapedText {
        lock.withLock { asked.append(text.runs.map(\.t).joined()) }
        return ShapedText()
    }
}

/// File names for exported notes (moved from the app's `MacSupportTests`).
struct ExportFileNameTests {
    @Test func plainTitlesKeepTheirName() {
        #expect(ExportFileName.pdf(title: "Fixture lecture") == "Fixture lecture.pdf")
        #expect(ExportFileName.pdf(title: "Física – tema 3") == "Física – tema 3.pdf")
        #expect(ExportFileName.base(title: "Lab: week 3/4") == "Lab week 3 4")
    }

    @Test func pathCharactersAndControlsAreReplaced() {
        #expect(ExportFileName.pdf(title: "a/b:c\\d") == "a b c d.pdf")
        #expect(ExportFileName.pdf(title: "line\none\u{0}two\u{7}") == "line one two.pdf")
        #expect(ExportFileName.pdf(title: "../../etc/passwd") == "etc passwd.pdf")
        #expect(ExportFileName.pdf(title: ".hidden") == "hidden.pdf")
    }

    @Test func emptyTitlesAreUntitled() {
        #expect(ExportFileName.pdf(title: "") == "Untitled.pdf")
        #expect(ExportFileName.pdf(title: "  \n ") == "Untitled.pdf")
        #expect(ExportFileName.pdf(title: "///") == "Untitled.pdf")
        #expect(ExportFileName.base(title: "") == "Untitled")
    }

    @Test func longTitlesAreCutOnACharacterBoundary() {
        let name = ExportFileName.pdf(title: String(repeating: "é", count: 500))
        let base = String(name.dropLast(4))
        #expect(base.utf8.count <= ExportFileName.maxBytes)
        #expect(base.allSatisfy { $0 == "é" })
        #expect(name.utf8.count <= 255)
    }
}
