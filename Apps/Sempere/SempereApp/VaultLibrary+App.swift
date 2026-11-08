import Age
import Foundation
import Sempere
import SempereAppCore
import SempereSync
import UniformTypeIdentifiers

// The app's side of `VaultLibrary` (SempereAppCore): the vault folder types, the app's own folders, and the wording
// of the library's errors and of a generated recovery key.

extension UTType {
    /// A `.sempere` folder. Declared as an exported type in `SempereInfo.plist`, as a
    /// plain folder and never a package: iCloud Drive syncs a package as one item, so
    /// concurrent writes from two devices would conflict over the whole vault (docs/io.md
    /// "Vaults are folders").
    static let sempere = UTType(exportedAs: "io.github.anthonytw.sempere.vault", conformingTo: .folder)

    /// A `.sempere-backup` folder (a backup, `BackupDestination`): a plain folder too, never a package, for the
    /// same reason. Opening one is a one-time copy (`CopyInFollowUp`).
    static let sempereBackup = UTType(exportedAs: "io.github.anthonytw.sempere.backup", conformingTo: .folder)

    /// What the "open vault" pickers accept: vault folders, backups, and plain folders
    /// (a vault in a folder not named `.sempere`, or the folder holding one). `.package` too: iCloud Drive may hold
    /// a `.sempere` or `.sempere-backup` as a package (an early build declared one), which the document picker greys
    /// out unless packages are allowed (owner's test of build 11); any other package is refused after the pick
    /// (`PickedFolderRules.acceptsFromDocumentPicker`).
    static var vaultPickerTypes: [UTType] { [.sempere, .sempereBackup, .folder, .package] }

    /// What the iPhone's and iPad's folder pickers accept (`FolderPicker`): folders, and vaults and backups held as
    /// packages, as for `vaultPickerTypes`.
    static var folderPickerTypes: [UTType] { [.folder, .sempere, .sempereBackup, .package] }
}

extension VaultLibrary {
    /// The app's library: `recents.json` in Application Support and the in-app vault store at
    /// `defaultVaultStoreRoot`.
    convenience init() {
        self.init(storeURL: Self.defaultStoreURL, vaultStore: VaultStore(root: Self.defaultVaultStoreRoot))
    }

    /// Lists the store again (`refreshStoredVaults(log:)`), logging to the app's `AppPerfSink`.
    func refreshStoredVaults() async { await refreshStoredVaults(log: AppPerfSink()) }

    /// `Application Support/Sempere/recents.json`.
    static var defaultStoreURL: URL { AppSupport.sempere.appendingPathComponent("recents.json") }

    /// The in-app vault store's folder (docs/design/device-first-sync.md §2): on an iPhone or iPad
    /// `<App Group container>/Library/Application Support/Sempere/Vaults`, so quick capture and widgets
    /// reach the inbox; on a Mac (no App Group entitlement) `Application Support/Sempere/Vaults` in the
    /// app's container (`VaultStoreRoot.prepare`).
    static let defaultVaultStoreRoot: URL = VaultStoreRoot.prepare(
        appGroup: Platform.isMac ? nil : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VaultStoreRoot.appGroup),
        fallback: AppSupport.folder("Vaults"))
}

extension CreatedVault {
    /// The recovery key as a key file (`KeyFile`) when it was generated, for Save to Files, Share and the kit.
    var recoveryKey: KeyFile? {
        let name = VaultLibrary.displayName(of: url)
        return generatedRecovery.map {
            KeyFile(identity: $0, label: String(localized: "Recovery key of \(name)",
                                                comment: "Label of a vault's recovery key; the value is the vault's name"),
                    created: created)
        }
    }
}

// MARK: - Wording

extension VaultLocator.LocatorError: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .severalVaults(let names):
            let list = names.joined(separator: ", ")
            return String(localized: "That folder holds several vaults (\(list)). Choose one of them.",
                          comment: "%@ is a list of vault folder names")
        case .insideVault(let name):
            return String(localized: "That is a folder inside the vault “\(name)”. Choose “\(name)” itself.")
        }
    }
}

extension FolderAccess.Problem: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .noAccess(let name, let scoped):
            return scoped
                ? String(localized: "Sempere has no access to “\(name)” any more. The system only keeps access to folders you choose yourself.")
                : String(localized: "Sempere has no access to “\(name)” any more (the saved permission did not come back). The system only keeps access to folders you choose yourself.")
        }
    }
}

extension VaultLibrary.LibraryError: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .cannotResolve(let name):
            return String(localized: "“\(name)” can't be found any more. It may have been moved or deleted, or access to it expired. Choose its folder again.")
        }
    }
}

extension VaultCreation.CreationError: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .classicRecoveryKey:
            return String(localized: "That is a classic AGE-SECRET-KEY-1… key, which is not quantum-safe. Use a post-quantum recovery key (AGE-SECRET-KEY-PQ-1…) or generate one.")
        }
    }
}

/// The words of a vault name `VaultStore.folderName` refuses (`InvalidVaultName`, SempereAppCore): New Vault and
/// Restore from Backup.
extension InvalidVaultName: @retroactive CustomStringConvertible {
    public var description: String {
        String(localized: "Give the vault a name without slashes, leading dots or control characters.")
    }

    /// `error` worded for the app: the name rule's own sentence for `VaultStoreError.invalidName`.
    static func describe(_ error: Error) -> String {
        if case .invalidName? = error as? VaultStoreError { return InvalidVaultName().description }
        return "\(error)"
    }
}
