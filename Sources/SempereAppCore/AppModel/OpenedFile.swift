import Foundation

/// Files the system hands the app (`onOpenURL`): Finder's Open With and
/// double-click on a Mac, the share sheet and Files' Open In on an iPad. The
/// app is a viewer of PDFs (`CFBundleDocumentTypes`, rank Alternate, never
/// Owner) and the owner of `.sempere` vaults.
public enum OpenedFile {
    /// What an opened URL is.
    public enum Kind: Equatable, Sendable { case pdf, vault }

    /// A PDF by its type (`isPDFType`: the app reads the URL's `UTType`) or its extension (the type cannot always be
    /// read before the security scope is taken); anything else is taken for a vault (or a folder inside one), as
    /// before.
    static func kind(of url: URL, isPDFType: Bool = false) -> Kind {
        if isPDFType || url.pathExtension.lowercased() == "pdf" { return .pdf }
        return .vault
    }

    /// Where the PDFs waiting to be imported stand, given the model's state.
    public enum Stage: Equatable, Sendable {
        /// Nothing waits.
        case none
        /// No vault is open: the welcome screen says a PDF waits for one.
        case needsVault
        /// A vault is open but locked (or finishing a key change, or still opening): the
        /// import is offered once it is unlocked.
        case needsUnlock
        /// The open vault cannot be written (format.md §7.3).
        case readOnly
        /// The import sheet is shown.
        case ready
    }

    /// Whether window `window` shows the import sheet: the library window
    /// with the canvas, or any window when no library window has it.
    public static func shows(in window: UUID, canvasWindow: UUID?) -> Bool {
        canvasWindow == nil || canvasWindow == window
    }

    static func stage(waiting: Int, phase: AppModelPhase, busy: Bool, readOnly: Bool) -> Stage {
        guard waiting > 0 else { return .none }
        switch phase {
        case .noVault: return .needsVault
        case .locked: return .needsUnlock
        case .unlocked:
            if busy { return .needsUnlock }
            return readOnly ? .readOnly : .ready
        }
    }
}
