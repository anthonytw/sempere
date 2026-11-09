import Foundation
import Sempere
import SempereRender

extension AppModelCore {
    /// Where an imported PDF goes.
    public enum PDFDestination {
        /// A new note, in `notebook` (docs/attachments.md §8 "Import a PDF").
        case newNote(notebook: String?)
        /// New pages of the open note after its first `after` pages ("Insert pages from a PDF").
        case insert(Editor, after: Int)
    }

    /// A PDF waiting for its password: the copy in the work folder and where it goes.
    public struct PDFImportRequest: Identifiable {
        public let id = UUID()
        public var file: URL
        public var destination: PDFDestination
        /// The last password tried did not open it.
        public var wrongPassword = false

        public init(file: URL, destination: PDFDestination, wrongPassword: Bool = false) {
            self.file = file
            self.destination = destination
            self.wrongPassword = wrongPassword
        }
    }

    /// What an import ended with.
    public enum PDFImportOutcome {
        /// The PDF is in the vault: the note it went into.
        case done(UUID)
        /// It needs a password: ask, then `continuePDFImport` (or `cancelPDFImport`).
        case needsPassword(PDFImportRequest)
        /// It failed or was canceled; `alert` says why when it failed.
        case failed
    }
}

/// Images and PDFs into the vault (docs/attachments.md §14 E1, E3): bytes are prepared off the main actor
/// (`services.attachmentPreparation`), then written as one blob and one delta through the editor (or, for a new
/// note, `commit`). Failures go to `alert` (`InsertNotice`).
extension AppModelCore {
    // MARK: Images

    /// Adds image bytes (Photos, the camera, a paste or a drop) to `page` of the editor's note, stored as the photo
    /// privacy setting says (`privacy`; nil: `PhotoPrivacy` in `services.settings`).
    @discardableResult
    public func insertImage(_ data: Data, into editor: Editor, page: UUID? = nil, visible: CGRect?,
                            at point: CGPoint? = nil, privacy: Bool? = nil) async -> Item? {
        guard let page = page ?? editor.currentPage?.id else { return nil }
        let privacy = privacy ?? PhotoPrivacy.isOn(services.settings)
        let preparation = services.attachmentPreparation
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try preparation.prepareImage(data, privacy: privacy)
            }.value
            return try await editor.insertImage(prepared, on: page, visible: visible, at: point)
        } catch is CancellationError {
            return nil
        } catch {
            alert = .insert(.imageNotAdded(error))
            return nil
        }
    }

    /// Replaces the image `item` on `page` with picture bytes (Replace Image), stored as the photo privacy setting
    /// says, in one delta. Returns the image replaced and the new one (the app registers the undo step).
    @discardableResult
    public func replaceImage(_ item: UUID, on page: UUID, with data: Data, in editor: Editor,
                             privacy: Bool? = nil) async -> (old: Item, new: Item)? {
        let privacy = privacy ?? PhotoPrivacy.isOn(services.settings)
        let preparation = services.attachmentPreparation
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try preparation.prepareImage(data, privacy: privacy)
            }.value
            return try await editor.replaceImage(item, with: prepared, on: page)
        } catch is CancellationError {
            return nil
        } catch {
            alert = .insert(.imageNotReplaced(error))
            return nil
        }
    }

    // MARK: PDFs

    /// Imports the PDF the user picked (security-scoped: copied first) into `destination`. A PDF with a user
    /// password returns `.needsPassword` with the request to show the password prompt for.
    public func importPDF(picked url: URL, to destination: PDFDestination) async -> PDFImportOutcome {
        let copy: URL
        let bookmarks = services.bookmarks
        do {
            copy = try await Task.detached(priority: .userInitiated) {
                try ImportWorkFolder.copyPicked(url, bookmarks: bookmarks)
            }.value
        } catch {
            alert = .insert(.pdfNotImported(error))
            return .failed
        }
        return await importPDF(copy: copy, to: destination, password: nil)
    }

    /// Tries the work copy in `request` again with `password`.
    public func continuePDFImport(_ pending: PDFImportRequest, password: String) async -> PDFImportOutcome {
        await importPDF(copy: pending.file, to: pending.destination, password: password)
    }

    /// Gives up on a PDF waiting for its password (its work copy is removed).
    public func cancelPDFImport(_ pending: PDFImportRequest) {
        ImportWorkFolder.discard(pending.file)
    }

    /// `importPDF(picked:to:)` for a file already in a work folder (tests start here). The work copy (and a
    /// redrawn one) is removed once the import ends, unless it waits for its password.
    public func importPDF(copy: URL, to destination: PDFDestination, password: String?) async -> PDFImportOutcome {
        let prepared: PreparedPDF
        let preparation = services.attachmentPreparation
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                try preparation.preparePDF(copy, password: password)
            }.value
        } catch let locked as PDFLocked {
            return .needsPassword(PDFImportRequest(file: copy, destination: destination, wrongPassword: locked == .wrongPassword))
        } catch {
            ImportWorkFolder.discard(copy)
            alert = .insert(.pdfNotImported(error))
            return .failed
        }
        defer {
            ImportWorkFolder.discard(prepared.file)
            if prepared.file != copy { ImportWorkFolder.discard(copy) }
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
            alert = .insert(.pdfNotImported(error))
            return .failed
        }
    }

    /// Makes a note from `pdf` (`NoteOps.newPDFNote`, as `sempere import pdf`): the PDF is written as a blob of the
    /// new note, then one delta creates the note with one page per PDF page. The note is selected.
    @discardableResult
    public func importPDF(_ pdf: PreparedPDF, title: String? = nil, notebook: String? = nil) async throws -> UUID {
        let id = UUID()
        let name = (title ?? pdf.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = NotebookPath.canonical(notebook)
        let pages = pdf.pages, file = pdf.file
        // Refuse before anything is written.
        _ = try NoteOps.newPDFNote(title: name, blob: BlobRef(sha256: String(repeating: "0", count: 64), size: 1, type: "application/pdf"),
                                   pages, notebook: notebook)
        try await commit(ids: [id], creating: [id]) { vault, clock, verifier in
            let ref = try await Task.detached(priority: .userInitiated) {
                try vault.writeBlob(note: id, contentsOf: file, type: "application/pdf")
            }.value
            let ops = try NoteOps.newPDFNote(title: name, blob: ref, pages, notebook: notebook)
            try await NoteWriter.append(ops, to: id, vault: vault, clock: clock, verify: verifier(id))
        }
        selectNewNote(id, notebook: notebook)
        return id
    }
}
