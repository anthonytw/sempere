import Foundation
import Sempere
import UniformTypeIdentifiers

/// A PDF opened from outside the app, copied into the app's work folder
/// (`PDFPreparation.copyPicked`): plaintext until it is imported or discarded.
struct OpenedPDF: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// The work copy.
    var file: URL
    /// The file's name as opened, for the import sheet.
    var name: String
}

/// Files the system hands the app (`onOpenURL`): Finder's Open With and
/// double-click on a Mac, the share sheet and Files' Open In on an iPad. The
/// app is a viewer of PDFs (`CFBundleDocumentTypes`, rank Alternate, never
/// Owner) and the owner of `.sempere` vaults.
enum OpenedFile {
    /// What an opened URL is.
    enum Kind: Equatable { case pdf, vault }

    /// A PDF by its type or its extension (the type cannot always be read
    /// before the security scope is taken); anything else is taken for a
    /// vault (or a folder inside one), as before.
    static func kind(of url: URL, contentType: UTType? = nil) -> Kind {
        if contentType?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" { return .pdf }
        return .vault
    }

    /// Where the PDFs waiting to be imported stand, given the model's state.
    enum Stage: Equatable {
        /// Nothing waits.
        case none
        /// No vault is open: the welcome screen says a PDF waits for one.
        case needsVault
        /// A vault is open but locked (or migrating, or still opening): the
        /// import is offered once it is unlocked.
        case needsUnlock
        /// The open vault cannot be written (format.md §7.3).
        case readOnly
        /// The import sheet is shown.
        case ready
    }

    /// Whether window `window` shows the import sheet: the library window
    /// with the canvas, or any window when no library window has it.
    static func shows(in window: UUID, canvasWindow: UUID?) -> Bool {
        canvasWindow == nil || canvasWindow == window
    }

    static func stage(waiting: Int, phase: AppModel.Phase, busy: Bool, readOnly: Bool) -> Stage {
        guard waiting > 0 else { return .none }
        switch phase {
        case .noVault: return .needsVault
        case .locked, .migrating: return .needsUnlock
        case .unlocked:
            if busy { return .needsUnlock }
            return readOnly ? .readOnly : .ready
        }
    }
}

/// PDFs opened from outside the app become new notes of the open vault
/// (docs/mac.md "Opening PDFs from the Finder"): the file is copied at once
/// (its security scope ends with the call), waits while a vault is opened and
/// unlocked, and is imported by the same path as Import PDF
/// (`importPDF(copy:to:password:)`).
extension AppModel {
    /// The notebook the sidebar shows, where imports are filed by default.
    var sidebarNotebook: String? {
        if case .notebook(let n)? = sidebarSelection { return n }
        return nil
    }

    /// Where `openedPDFs` stand (`OpenedFile.stage`).
    var openedPDFStage: OpenedFile.Stage {
        OpenedFile.stage(waiting: openedPDFs.count, phase: phase, busy: isBusy, readOnly: isVaultReadOnly)
    }

    /// A vault handed to the app from outside while another one is open: it
    /// would close that one, so the window asks first (security review
    /// 2026-10 stage 4, S16).
    struct OpenedVaultConfirmation: Identifiable, Equatable {
        let url: URL
        /// The folder's name, as the user sees it.
        let name: String
        /// The vault open now.
        let current: String
        var id: URL { url }
    }

    /// A URL the system opened the app with: a PDF is queued for import
    /// (`receiveOpenedPDF`), anything else opened as a vault. A vault that
    /// would replace the open one is not opened unless `confirmed`: the
    /// confirmation to ask for comes back instead.
    @discardableResult
    func handleOpened(_ url: URL, library: VaultLibrary, confirmed: Bool = false) async -> OpenedVaultConfirmation? {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        switch OpenedFile.kind(of: url, contentType: type) {
        case .pdf:
            await receiveOpenedPDF(url)
        case .vault:
            if !confirmed, phase != .noVault {
                let name = url.deletingPathExtension().lastPathComponent
                return OpenedVaultConfirmation(url: url, name: name.isEmpty ? url.lastPathComponent : name,
                                               current: vaultName ?? String(localized: "Vault", comment: "Name shown for a vault that has none"))
            }
            await report { try await open(picked: url, library: library, external: true) }
        }
        return nil
    }

    /// Takes a PDF the system opened the app with: copies it into the work
    /// folder and queues it. Failures go to `errorMessage`.
    func receiveOpenedPDF(_ url: URL) async {
        do {
            let copy = try await Task.detached(priority: .userInitiated) { try PDFPreparation.copyPicked(url) }.value
            openedPDFs.append(OpenedPDF(file: copy, name: url.lastPathComponent))
        } catch {
            errorMessage = String(localized: "Could not open “\(url.lastPathComponent)”. \(Self.describe(error))",
                                  comment: "A file opened with Sempere: its name, then a sentence saying why")
        }
    }

    /// Imports every waiting PDF as a new note in `notebook`, one note each.
    /// Returns the ones that need a password (their work copies stay for the
    /// password prompt); the others are imported or reported in `errorMessage`.
    func importOpenedPDFs(notebook: String?) async -> [PDFImportRequest] {
        let waiting = openedPDFs
        openedPDFs = []
        var locked: [PDFImportRequest] = []
        for pdf in waiting {
            if case .needsPassword(let request) = await importPDF(copy: pdf.file, to: .newNote(notebook: notebook), password: nil) {
                locked.append(request)
            }
        }
        return locked
    }

    /// Drops the waiting PDFs and their work copies.
    func discardOpenedPDFs() {
        for pdf in openedPDFs { PDFPreparation.discard(pdf.file) }
        openedPDFs = []
    }
}
