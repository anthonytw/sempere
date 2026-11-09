import Foundation
import Sempere

/// A PDF opened from outside the app, copied into a work folder (`ImportWorkFolder.copyPicked`): plaintext until it
/// is imported or discarded.
public struct OpenedPDF: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The work copy.
    public var file: URL
    /// The file's name as opened, for the import sheet.
    public var name: String

    public init(file: URL, name: String) {
        self.file = file
        self.name = name
    }
}

/// PDFs opened from outside the app become new notes of the open vault (docs/mac.md "Opening PDFs from the Finder"):
/// the file is copied at once (its security scope ends with the call), waits while a vault is opened and unlocked,
/// and is imported by the same path as Import PDF (`importPDF(copy:to:password:)`).
extension AppModelCore {
    /// The notebook the sidebar shows, where imports are filed by default.
    public var sidebarNotebook: String? {
        if case .notebook(let n)? = sidebarSelection { return n }
        return nil
    }

    /// Where `openedPDFs` stand (`OpenedFile.stage`).
    public var openedPDFStage: OpenedFile.Stage {
        OpenedFile.stage(waiting: openedPDFs.count, phase: phase, busy: isBusy, readOnly: isVaultReadOnly)
    }

    /// A vault handed to the app from outside while another one is open: it would close that one, so the window asks
    /// first (security review 2026-10 stage 4, S16).
    public struct OpenedVaultConfirmation: Identifiable, Equatable, Sendable {
        public let url: URL
        /// The folder's name, as the user sees it.
        public let name: String
        /// The name of the vault open now (nil when it has none: the app words that).
        public let current: String?
        public var id: URL { url }

        public init(url: URL, name: String, current: String?) {
            self.url = url
            self.name = name
            self.current = current
        }
    }

    /// A URL the system opened the app with: a PDF (by its type, `AttachmentPreparing.isPDFType`, or its extension)
    /// is queued for import (`receiveOpenedPDF`), anything else copied into the store as a vault and opened
    /// (`copyIn`). A vault that would replace the open one is not opened unless `confirmed`: the confirmation to ask
    /// for comes back instead.
    @discardableResult
    public func handleOpened(_ url: URL, library: VaultLibrary, confirmed: Bool = false) async -> OpenedVaultConfirmation? {
        switch OpenedFile.kind(of: url, isPDFType: services.attachmentPreparation.isPDFType(url)) {
        case .pdf:
            await receiveOpenedPDF(url)
        case .vault:
            if !confirmed, phase != .noVault {
                let name = url.deletingPathExtension().lastPathComponent
                return OpenedVaultConfirmation(url: url, name: name.isEmpty ? url.lastPathComponent : name, current: vaultName)
            }
            // Copied onto this device like "Open Vault…" (the folder handed over is only read).
            await report { try await copyIn(picked: url, library: library, external: true) }
        }
        return nil
    }

    /// Takes a PDF the system opened the app with: copies it into a work folder (its scope through
    /// `services.bookmarks`) and queues it. Failures go to `alert` (`InsertNotice.fileNotOpened`).
    public func receiveOpenedPDF(_ url: URL) async {
        let bookmarks = services.bookmarks
        do {
            let copy = try await Task.detached(priority: .userInitiated) {
                try ImportWorkFolder.copyPicked(url, bookmarks: bookmarks)
            }.value
            openedPDFs.append(OpenedPDF(file: copy, name: url.lastPathComponent))
        } catch {
            alert = .insert(.fileNotOpened(name: url.lastPathComponent, error))
        }
    }

    /// Imports every waiting PDF as a new note in `notebook`, one note each. Returns the ones that need a password
    /// (their work copies stay for the password prompt); the others are imported or reported in `alert`.
    public func importOpenedPDFs(notebook: String?) async -> [PDFImportRequest] {
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
    public func discardOpenedPDFs() {
        for pdf in openedPDFs { ImportWorkFolder.discard(pdf.file) }
        openedPDFs = []
    }
}
