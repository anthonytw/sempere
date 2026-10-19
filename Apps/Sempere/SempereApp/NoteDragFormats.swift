import Foundation
import Sempere
import SempereRender

/// The formats a note dragged out of the list can become besides PDF
/// (Settings ▸ General ▸ Drag to Finder, `DragExportFormat`): Markdown and
/// HTML, written by the share exporter (`ShareExport`) as one file for the
/// one note, exactly as Share ▸ Text (Markdown) and Share ▸ HTML write it.
extension PreparedExport {
    /// Renders the note as `format` and writes `<folder>/<uuid>/<title>.<ext>`.
    /// Blocking: call it off the main actor. Throws `CancellationError` once
    /// the vault that prepared it has closed.
    func write(format: DragExportFormat) throws -> URL {
        if format == .pdf { return try write() }
        guard epoch.value == startEpoch else { throw CancellationError() }
        NotePDFExport.purge(olderThan: 3600)   // folders of earlier runs that never closed a vault
        NotePDFExport.purge(in: folder)
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url: URL
        do {
            url = try CloudVault.coordinatedRead(coordinate) {
                try NoteDragExport.write(vault: vault, noteID: noteID, format: format, into: dir)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        guard epoch.value == startEpoch else {
            try? FileManager.default.removeItem(at: dir)
            throw CancellationError()
        }
        return url
    }
}

/// Markdown and HTML for one dragged note (`PreparedExport.write(format:)`).
enum NoteDragExport {
    /// The note could not be rendered in the chosen format.
    struct Failed: Error, CustomStringConvertible {
        var reason: String
        var description: String { reason }
    }

    /// Writes `noteID` as `format` (Markdown or HTML) into the new folder `dir`, named as a
    /// dropped PDF is (`NoteFileDrag.suggestedName`), and returns the file.
    static func write(vault: Vault, noteID: UUID, format: DragExportFormat, into dir: URL) throws -> URL {
        let loaded = try vault.loadNote(noteID)
        guard loaded.failures.isEmpty else { throw AppModel.ExportError.unreadableRevisions(loaded.failures.count) }
        let state = try NoteReducer.reconstruct(loaded.revisions)
        let summary = vault.summary(of: noteID, loaded: loaded)
        let share: ShareFormat = format == .html ? .html : .markdown
        let result = try ShareExport.run([(summary, state)], options: ShareOptions(format: share), into: dir,
                                         vaultSource: "sempere:\(vault.vaultId.uuidString.lowercased())",
                                         blobs: { _ in vault.blobSource(note: noteID) },
                                         pdfRasterizer: PDFKitRasterizer(), shaper: CoreTextShaper(),
                                         imageDecoder: ImageIODecoder())
        guard result.exported == 1, let written = result.items.first else {
            throw Failed(reason: result.failures.first ?? "the note could not be exported")
        }
        let named = dir.appendingPathComponent(NoteFileDrag.suggestedName(title: state.meta.title))
            .appendingPathExtension(format.fileExtension)
        guard written != named else { return written }
        try FileManager.default.moveItem(at: written, to: named)
        return named
    }
}
