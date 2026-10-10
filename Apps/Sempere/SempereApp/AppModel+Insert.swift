import CoreGraphics
import Foundation
import Sempere
import SempereRender

/// Where an imported PDF goes.
enum PDFDestination {
    /// A new note, in `notebook` (docs/attachments.md §8 "Import a PDF").
    case newNote(notebook: String?)
    /// New pages of the open note after its first `after` pages ("Insert pages from a PDF").
    case insert(NoteEditor, after: Int)
}

/// A PDF waiting for its password: the copy in the app's work folder and where it goes.
struct PDFImportRequest: Identifiable {
    let id = UUID()
    var file: URL
    var destination: PDFDestination
    /// The last password tried did not open it.
    var wrongPassword = false
}

/// What an import ended with.
enum PDFImportOutcome {
    /// The PDF is in the vault: the note it went into.
    case done(UUID)
    /// It needs a password: ask, then `continuePDFImport` (or `cancelPDFImport`).
    case needsPassword(PDFImportRequest)
    /// It failed or was cancelled; `errorMessage` says why when it failed.
    case failed
}

/// Images and PDFs into the vault (docs/attachments.md §14 E1, E3): bytes are
/// prepared off the main actor (`ImagePreparation`, `PDFPreparation`), then
/// written as one blob and one delta through the editor (or, for a new note,
/// `commit`). Failures go to `errorMessage`.
extension AppModel {
    // MARK: Images

    /// Adds image bytes (Photos, the camera, a paste or a drop) to `page` of
    /// the editor's note, stored as the photo privacy setting says.
    @discardableResult
    func insertImage(_ data: Data, into editor: NoteEditor, page: UUID? = nil, visible: CGRect?,
                     at point: CGPoint? = nil, privacy: Bool = PhotoPrivacy.isOn()) async -> Item? {
        guard let page = page ?? editor.currentPage?.id else { return nil }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ImagePreparation.prepare(data, privacy: privacy)
            }.value
            return try await editor.insertImage(prepared, on: page, visible: visible, at: point)
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = String(localized: "Could not add the image. \(Self.describe(error))")
            return nil
        }
    }

    /// Replaces the image `item` on `page` with picture bytes (Replace
    /// Image), stored as the photo privacy setting says; one undo step on
    /// `actions`. Returns the new image.
    @discardableResult
    func replaceImage(_ item: UUID, on page: UUID, with data: Data, in editor: NoteEditor, actions: ItemActions?,
                      privacy: Bool = PhotoPrivacy.isOn()) async -> Item? {
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ImagePreparation.prepare(data, privacy: privacy)
            }.value
            let (old, new) = try await editor.replaceImage(item, with: prepared, on: page)
            actions?.replaced(old, by: new, on: page)
            return new
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = String(localized: "Could not replace the image. \(Self.describe(error))")
            return nil
        }
    }

    // MARK: PDFs

    /// Imports the PDF the user picked (security-scoped: copied first) into
    /// `destination`. A PDF with a user password returns `.needsPassword`
    /// with the request to show the password prompt for.
    func importPDF(picked url: URL, to destination: PDFDestination) async -> PDFImportOutcome {
        let copy: URL
        do {
            copy = try await Task.detached(priority: .userInitiated) { try PDFPreparation.copyPicked(url) }.value
        } catch {
            errorMessage = String(localized: "Could not import the PDF. \(Self.describe(error))")
            return .failed
        }
        return await importPDF(copy: copy, to: destination, password: nil)
    }

    /// Tries the work copy in `request` again with `password`.
    func continuePDFImport(_ pending: PDFImportRequest, password: String) async -> PDFImportOutcome {
        await importPDF(copy: pending.file, to: pending.destination, password: password)
    }

    /// Gives up on a PDF waiting for its password (its work copy is removed).
    func cancelPDFImport(_ pending: PDFImportRequest) {
        PDFPreparation.discard(pending.file)
    }

    /// `importPDF(picked:to:)` for a file already in a work folder (tests start here).
    func importPDF(copy: URL, to destination: PDFDestination, password: String?) async -> PDFImportOutcome {
        let prepared: PreparedPDF
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                try PDFPreparation.prepare(copy, password: password)
            }.value
        } catch let failure as PDFPreparation.Failure where failure == .needsPassword || failure == .wrongPassword {
            return .needsPassword(PDFImportRequest(file: copy, destination: destination, wrongPassword: failure == .wrongPassword))
        } catch {
            PDFPreparation.discard(copy)
            errorMessage = String(localized: "Could not import the PDF. \(Self.describe(error))")
            return .failed
        }
        defer {
            PDFPreparation.discard(prepared.file)
            if prepared.file != copy { PDFPreparation.discard(copy) }
        }
        do {
            switch destination {
            case .newNote(let notebook):
                return .done(try await importPDF(prepared, notebook: notebook))
            case .insert(let editor, let after):
                try await editor.insertPDFPages(prepared, after: after)
                return .done(editor.noteID)
            }
        } catch is CancellationError {
            return .failed
        } catch {
            errorMessage = String(localized: "Could not import the PDF. \(Self.describe(error))")
            return .failed
        }
    }

    /// Makes a note from `pdf` (`NoteOps.newPDFNote`, as `sempere import pdf`):
    /// the PDF is written as a blob of the new note, then one delta creates
    /// the note with one page per PDF page. The note is selected.
    @discardableResult
    func importPDF(_ pdf: PreparedPDF, title: String? = nil, notebook: String? = nil) async throws -> UUID {
        let id = UUID()
        let name = (title ?? pdf.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = NotebookPath.canonical(notebook)
        let pages = pdf.pages, file = pdf.file
        // Refuse before anything is written.
        _ = try NoteOps.newPDFNote(title: name, blob: BlobRef(sha256: String(repeating: "0", count: 64), size: 1, type: "application/pdf"),
                                   pages, notebook: notebook)
        try await commit(ids: [id], creating: [id]) { vault, clock, cloud, verifier in
            let folder = cloud ? CloudScan.noteFolder(inVault: vault.url, id: id) : nil
            let ref = try await Task.detached(priority: .userInitiated) {
                try CloudVault.coordinatedWrite(folder) { try vault.writeBlob(note: id, contentsOf: file, type: "application/pdf") }
            }.value
            let ops = try NoteOps.newPDFNote(title: name, blob: ref, pages, notebook: notebook)
            try await NoteWriter.append(ops, to: id, vault: vault, clock: clock, coordinated: cloud, verify: verifier(id))
        }
        selectNewNote(id, notebook: notebook)
        return id
    }

    /// A sentence for an import error.
    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let e as ImagePreparation.Failure: return e.description
        case let e as PDFPreparation.Failure: return e.description
        case let e as AttachmentOpsError:
            if case .pagelessNote = e { return String(localized: "This note is pageless: switch it to pages first, or import the PDF as a new note.") }
            return "\(e)"
        case let e as ImageIngestError: return e.description
        case let e as VideoPreparation.Failure: return e.description
        case let e as VideoProbeError: return e.description
        default: return "\(error)"
        }
    }
}
