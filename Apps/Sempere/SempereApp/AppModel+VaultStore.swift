import Foundation
import Sempere
import SempereAppCore
import SempereSync

// The words of the in-app vault store's values (`AppModel+VaultStore.swift` in SempereAppCore): the copy-in overlay's
// progress and the store's refusals.

extension VaultCopyProgress {
    var text: String {
        switch stage {
        case .downloading(let done, let total):
            return String(localized: "Downloading “\(name)”: \(done) of \(total) files…",
                          comment: "Copy-in progress: %1$@ is the vault's name, then files downloaded of all files")
        case .copying(let done, let total):
            return String(localized: "Copying “\(name)” onto this device: \(done) of \(total) files…",
                          comment: "Copy-in progress: %1$@ is the vault's name, then files copied of all files")
        }
    }
}

extension VaultStoreProblem: @retroactive CustomStringConvertible {
    public var description: String {
        switch error {
        case .alreadyInStore(_, let name):
            return String(localized: "This vault is already on this device as “\(name)”. Open it from the list.",
                          comment: "%@ is the vault's name")
        case .notDownloaded(_, let count):
            return String(localized: "\(count) files of this vault are not on this device yet. Download the vault (in Files, choose Download Now) and try again.",
                          comment: "%lld is a number of files")
        case .partialCopy:
            return String(localized: "That vault is an incomplete copy. Finish downloading or syncing it, then open it again.")
        case .unfinishedRestore:
            return String(localized: "That vault is a restore that did not finish. Finish the restore, then open it again.")
        case .unsupportedEntry(let path):
            return String(localized: "That vault holds “\(path)”, a link or special file. A vault holds only folders and regular files.",
                          comment: "%@ is a path inside the vault")
        case .notAVault(let path, _):
            return String(localized: "“\(URL(fileURLWithPath: path).lastPathComponent)” is not a Sempere vault (it has no readable vault.json).",
                          comment: "%@ is a folder's name")
        case .sourceChanged:
            return String(localized: "The vault changed while it was being copied, so nothing was added. Try again.")
        case .copyMismatch:
            return String(localized: "The copy did not match the original, so nothing was added. Try again; if it happens again, check the storage the vault is on.")
        case .restoreIncomplete(let count):
            return String(localized: "\(count) files of the backup could not be restored, so nothing was added. Check the backup, or restore from another copy of it.",
                          comment: "%lld is a number of files")
        case .inUse:
            return String(localized: "That vault is open. Close it first.")
        case .busy:
            return String(localized: "That vault is busy. Try again in a moment.")
        case .sourceInsideStore, .invalidName, .notFound, .ambiguous, .io:
            return String(localized: "Sempere could not copy the vault: \(error.description)",
                          comment: "%@ is the reason, in English")
        }
    }
}

/// The Open Vault sheet's questions on the app's services (`AppHost.makeServices`: iCloud's hooks, security-scoped
/// bookmarks, `NSFileCoordinator`); the rules are the library's.
extension CopyInFollowUp {
    static func suggested(for url: URL) -> CopyInFollowUp {
        suggested(for: url, hooks: .live, bookmarks: SecurityScopedBookmarks())
    }

    static func isWritable(_ url: URL) -> Bool { isWritable(url, bookmarks: SecurityScopedBookmarks()) }

    static func isBackup(_ url: URL) -> Bool { isBackup(url, bookmarks: SecurityScopedBookmarks()) }

    nonisolated static func isOnDevice(_ url: URL, store: VaultStore) -> Bool {
        isOnDevice(url, store: store, hooks: .live, bookmarks: SecurityScopedBookmarks(), files: SystemFileCoordinator())
    }
}
