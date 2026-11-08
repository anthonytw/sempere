import Foundation
import Sempere
import SempereRender
import Testing
@testable import SempereApp
import SempereAppCore

/// The export commands' and the sheet's words, and the app's rendering (PDFKit, ImageIO, CoreText). What each format
/// writes, the job and the targets are `ExportTests` in `SempereAppCoreTests`.
@MainActor
struct ExportTests {
    static let lecture = AppModelTests.lecture

    func scratch() throws -> URL {
        TestTemp.root.appendingPathComponent("export-test-\(UUID().uuidString)")
    }

    func export(_ model: AppModel, _ ids: [UUID], _ options: ShareOptions, into dir: URL) async throws -> ShareResult {
        try await model.exportNotes(ids, options: options, into: dir) { _ in }
    }

    /// PDF, PNG, text and media; HTML stays in the CLI only.
    @Test func commandsCoverTheAppFormatsOnce() {
        #expect(ExportCommand.allCases.map(\.format) == [.pdf, .png, .markdown, .media])
        #expect(!ExportCommand.formats.contains(.html))
        #expect(ExportCommand.markdown.title == "Text (Markdown)…")
        #expect(ShareFormat.markdown.title == "Text (Markdown)")
        #expect(Set(ExportCommand.allCases.map(\.title)).count == 4)
        #expect(Set(ExportCommand.allCases.map(\.systemImage)).count == 4)
        #expect(ShareFormat.media.localizedTitle == "Media")
        #expect(ShareOptions(format: .markdown).markdownPDF == false, "the PDF is opt-in")
    }

    @Test func exportSheetDescribesTheShape() {
        for format in ShareFormat.allCases {
            for count in [1, 3] {
                #expect(!ExportSheet.shape(of: ShareOptions(format: format), count: count).isEmpty)
            }
        }
    }

    @Test func progressAndFailureLines() {
        #expect(ExportProgress(phase: .reading, done: 0, total: 3).description == "Reading note 1 of 3…")
        #expect(ExportProgress(phase: .rendering, done: 1, total: 3).description == "Exporting note 2 of 3…")
        #expect(ExportProgress(phase: .rendering, done: 3, total: 3).description == "Finishing…")
        #expect(BulkExportProgress(done: 0, total: 2).description == "Exporting note 1 of 2…")
        #expect(ExportRunFailure.noMedia.text == "The notes have no recordings, videos, images or PDFs.")
        #expect(ExportRunFailure.nothingExported.text == "There was nothing to export.")
        #expect(ExportRunFailure.noNotes.text == "There are no notes to export.")
        #expect(ExportRunFailure.folderInsideVault.text.hasPrefix("Choose a folder outside the vault"))
        #expect(ExportRunFailure.noteFailed("x: y").text == "x: y")
        #expect("\(UnsavedChangesError())" == "Its latest changes could not be saved, so it was not exported.")
    }

    /// The app's exports draw PDF pages, images and text boxes as the canvas does (`AppHost.makeServices`), so a PDF of
    /// the fixture lecture is a real PDF from the app's renderers.
    @Test func theAppRendersWithPDFKitImageIOAndCoreText() async throws {
        let rendering = AppHost.makeServices().exportRendering
        #expect(rendering.pdfRasterizer is PDFKitRasterizer)
        #expect(rendering.imageDecoder is ImageIODecoder)
        #expect(rendering.shaper is CoreTextShaper)
        #expect(AppHost.makeServices().pdfTextExtractor is PDFKitTextExtractor)
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        let dir = TestTemp.root.appendingPathComponent("export-test-\(UUID().uuidString)")
        let r = try await model.exportNotes([AppModelTests.lecture], options: ShareOptions(format: .pdf), into: dir) { _ in }
        #expect(r.exported == 1 && r.failures.isEmpty)
        #expect(try Data(contentsOf: try #require(r.items.first)).prefix(5) == Data("%PDF-".utf8))
    }
}
