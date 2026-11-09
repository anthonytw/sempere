import Foundation
import Sempere
import SempereRender
import SempereAppCore

/// A note dragged out of the app to the Finder (Mac): rendered to a PDF file outside the vault. The note windows
/// and the library window's state restoration are the core's (`AppModel+Windows.swift` in SempereAppCore).
extension AppModel {
    // MARK: - PDF export

    enum ExportError: Error, Equatable, CustomStringConvertible {
        case unreadableRevisions(Int)

        var description: String {
            switch self {
            case .unreadableRevisions(let n):
                return String(localized: "\(n) revisions of this note could not be read, so it cannot be exported completely.")
            }
        }
    }

    /// Renders a note to a PDF in a fresh folder under the temporary
    /// directory and returns its URL (named after the title, `ExportFileName`).
    /// Pending ink of the note, wherever it is open, is saved first so the PDF
    /// shows what is on screen. The file is plaintext: it is for the Finder
    /// drop that asked for it, and `NotePDFExport.purge` removes it later.
    func exportPDF(noteID: UUID) async throws -> URL {
        let prepared = try await prepareExport(noteID: noteID)
        let url = try await offMain { try prepared.write() }
        try ensureCurrent(prepared.generation)
        return url
    }

    /// The main-actor part of `exportPDF`: saves the note's pending ink and
    /// makes it local (iCloud Drive). What it returns renders and writes the
    /// PDF on any thread, without the main actor, so a drop that asks for the
    /// file while the main thread waits (a Mac file promise) still gets it.
    func prepareExport(noteID: UUID) async throws -> PreparedExport {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        if editor?.noteID == noteID { await editor?.flush() }
        await windowEditors[noteID]?.flush()
        try ensureCurrent(gen)
        try await downloadNote(noteID)
        try ensureCurrent(gen)
        return PreparedExport(vault: vault, noteID: noteID, folder: exportFolder,
                              epoch: exportEpoch, generation: gen, startEpoch: exportEpoch.value)
    }
}

/// A note ready to be rendered to a PDF (`AppModel.prepareExport`).
struct PreparedExport: Sendable {
    let vault: Vault
    let noteID: UUID
    let folder: URL
    let epoch: ExportEpoch
    /// The model's generation when prepared (`ensureCurrent`).
    let generation: Int
    let startEpoch: Int

    /// Renders the note and writes `<folder>/<uuid>/<title>.pdf`. Blocking:
    /// call it off the main actor. Throws `CancellationError` once the vault
    /// that prepared it has closed.
    func write() throws -> URL {
        guard epoch.value == startEpoch else { throw CancellationError() }
        let rendered = try NotePDFExport.render(vault: vault, noteID: noteID)
        guard epoch.value == startEpoch else { throw CancellationError() }
        NotePDFExport.purge(olderThan: 3600)   // folders of earlier runs that never closed a vault
        let url = try NotePDFExport.write(rendered, in: folder)
        guard epoch.value == startEpoch else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw CancellationError()
        }
        return url
    }
}

/// Rendering a note to a PDF file outside the vault (Mac drag and drop); its folder and purge are the core's.
extension NotePDFExport {
    struct Rendered: Sendable {
        var title: String
        var pdf: Data
    }

    /// The note's PDF. A note with unreadable revisions is refused rather
    /// than exported with pages missing.
    static func render(vault: Vault, noteID: UUID) throws -> Rendered {
        let loaded = try vault.loadNote(noteID)
        guard loaded.failures.isEmpty else { throw AppModel.ExportError.unreadableRevisions(loaded.failures.count) }
        let state = try NoteReducer.reconstruct(loaded.revisions)
        // PDF page backgrounds are copied from the note's attachments (docs/attachments.md §10);
        // text boxes are laid out as the canvas shows them.
        let options = RenderOptions(blobs: vault.blobSource(note: noteID), pdfRasterizer: PDFKitRasterizer(),
                                    imageDecoder: ImageIODecoder(), shaper: CoreTextShaper())
        return Rendered(title: state.meta.title, pdf: try PDFWriter.render(note: state, options: options))
    }

    /// Writes `rendered` to `<folder>/<uuid>/<title>.pdf`, old exports removed first.
    static func write(_ rendered: Rendered, in folder: URL = NotePDFExport.folder) throws -> URL {
        purge(in: folder)
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ExportFileName.pdf(title: rendered.title))
        try rendered.pdf.write(to: url, options: .atomic)
        return url
    }
}
