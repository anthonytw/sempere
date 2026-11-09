import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp
import SempereAppCore

/// The PDF a note drags out as (Mac), and the scene storage's rule. The window editors, claims and restoring the
/// library window's selection are the core's (`Tests/SempereAppCoreTests/AppModel/NoteWindowTests.swift`).
@MainActor
struct NoteWindowTests {
    static let lecture = AppModelTests.lecture

    static func unlockedModel() async throws -> (AppModel, URL) {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(200))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        return (model, url)
    }

    /// The saved selection is cleared once no vault is open.
    @Test func theSelectionStorageIsClearedWithoutAVault() {
        #expect(SelectionStorage.shouldClear(phase: .noVault))
        #expect(!SelectionStorage.shouldClear(phase: .unlocked))
    }

    // MARK: - PDF export (drag to Finder)

    @Test func exportWritesANamedPDFOfTheNote() async throws {
        let (model, _) = try await Self.unlockedModel()
        defer { model.close() }
        let url = try await model.exportPDF(noteID: Self.lecture)
        defer { try? FileManager.default.removeItem(at: model.exportFolder) }
        #expect(url.lastPathComponent == "Fixture lecture.pdf")
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("%PDF-".utf8)))
        #expect(data.count > 500)
    }

    @Test func exportsOfOneTitleDoNotCollide() async throws {
        let (model, _) = try await Self.unlockedModel()
        defer { model.close() }
        let a = try await model.exportPDF(noteID: Self.lecture)
        let b = try await model.exportPDF(noteID: Self.lecture)
        defer { try? FileManager.default.removeItem(at: model.exportFolder) }
        #expect(a != b)
        #expect(a.lastPathComponent == b.lastPathComponent)
    }

    @Test func exportIncludesInkNotYetSaved() async throws {
        let (model, _) = try await Self.unlockedModel()
        defer { model.close() }
        let before = try await model.exportPDF(noteID: Self.lecture)
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        editor.addPage()
        let after = try await model.exportPDF(noteID: Self.lecture)
        defer { try? FileManager.default.removeItem(at: model.exportFolder) }
        #expect(try Data(contentsOf: after).count > (try Data(contentsOf: before)).count, "the new page is in the PDF")
    }

    @Test func exportNeedsAnUnlockedVault() async throws {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        await #expect(throws: AppModel.ModelError.noVaultOpen) { _ = try await model.exportPDF(noteID: Self.lecture) }
    }

    @Test func oldExportsArePurgedAndNewOnesKept() throws {
        let folder = TestTemp.root.appendingPathComponent("purge-\(UUID().uuidString)")
        let rendered = NotePDFExport.Rendered(title: "T", pdf: Data("%PDF-1.4".utf8))
        let url = try NotePDFExport.write(rendered, in: folder)
        NotePDFExport.purge(in: folder, olderThan: 600)
        #expect(FileManager.default.fileExists(atPath: url.path))
        NotePDFExport.purge(in: folder, olderThan: 600, now: Date().addingTimeInterval(3600))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: folder)
    }
}
