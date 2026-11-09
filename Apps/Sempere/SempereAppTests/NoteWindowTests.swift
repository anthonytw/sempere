import Age
import Foundation
import PDFKit
import Sempere
import SempereRender
import Testing
@testable import SempereApp
import SempereAppCore

/// The PDF a note drags out as (Mac) on the app's renderers, and the scene storage's rule. The window editors, claims,
/// restoring the library window's selection and the drag-out export's model (`exportPDF`, `prepareExport`, the folder
/// and its purge) are the core's (`Tests/SempereAppCoreTests/AppModel/NoteWindowTests.swift`, `DragExportTests.swift`).
@MainActor
struct NoteWindowTests {
    static let lecture = AppModelTests.lecture

    static func unlockedModel() async throws -> (AppModel, URL) {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(200))
        do {
            try await model.openVault(at: url)
            try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        } catch {
            model.close()
            throw error
        }
        return (model, url)
    }

    /// The saved selection is cleared once no vault is open.
    @Test func theSelectionStorageIsClearedWithoutAVault() {
        #expect(SelectionStorage.shouldClear(phase: .noVault))
        #expect(!SelectionStorage.shouldClear(phase: .unlocked))
    }

    // MARK: - PDF export (drag to Finder)

    /// Step 6b: the drag-out PDF is drawn through `services.exportRendering`. A note with a PDF background and a text
    /// box renders the same pages as the app drew them before, naming PDFKit, ImageIO and CoreText itself, and the
    /// text box is drawn (without the shaper the PDF differs).
    @Test func theDraggedPDFDrawsThroughTheServicesAsBefore() async throws {
        let (model, _) = try await Self.unlockedModel()
        defer { model.close() }
        model.blobCacheFolder = TestTemp.root.appendingPathComponent(UUID().uuidString)
        let vault = try #require(model.vault)
        let source = try PDFImportTests.makePDF(pages: 2)
        guard case .done(let id) = await model.importPDF(copy: source, to: .newNote(notebook: nil), password: nil) else {
            Issue.record("not imported: \(model.errorMessage ?? "")")
            return
        }
        model.selectedNoteID = id
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        let page = try #require(editor.currentPage).id
        let content = TextContent(size: 18, color: .black, runs: [TextRun("Drawn by CoreText")])
        #expect(editor.addTextBox(content, frame: Rect(x: 120, y: 120, w: 240, h: 60), on: page) != nil)

        let url = try await model.exportPDF(noteID: id)   // saves the text box first
        let throughServices = try Data(contentsOf: url)
        let state = try vault.reconstruct(noteId: id)
        #expect(state.pages.first?.items.contains { $0.kind == .text } == true, "the text box was saved before the export")
        let before = RenderOptions(blobs: vault.blobSource(note: id), pdfRasterizer: PDFKitRasterizer(),
                                   imageDecoder: ImageIODecoder(), shaper: CoreTextShaper())
        #expect(throughServices == (try PDFWriter.render(note: state, options: before)), "the same PDF as before 6b")
        let document = try #require(PDFDocument(data: throughServices))
        #expect(document.pageCount == 2, "one page per PDF page")
        var unshaped = before
        unshaped.shaper = nil
        #expect(throughServices != (try PDFWriter.render(note: state, options: unshaped)), "the text box is drawn")
    }
}
