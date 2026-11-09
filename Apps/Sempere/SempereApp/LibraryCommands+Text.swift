import Foundation
import SempereAppCore

extension LibraryCommands {
    /// Reopens a recent vault; on failure explains and says whether the folder
    /// picker should follow the alert (`pickOnFailure`). Nil when it opened,
    /// or the user stopped an iCloud download. The rule is `reopen(_:model:library:)` (`SempereAppCore`).
    static func reopen(_ entry: RecentVault, pickOnFailure: Bool, model: AppModel, library: VaultLibrary) async -> Bool? {
        guard let error = await reopen(entry, model: model, library: library) else { return nil }
        let detail = AppModel.describe(error)
        model.alert = .worded(pickOnFailure
            ? String(localized: "Could not reopen “\(entry.name)”: \(detail)\n\nChoose the vault folder again.",
                     comment: "First %@ is the vault's name, second the error (English)")
            : String(localized: "Could not reopen “\(entry.name)”: \(detail)", comment: "First %@ is the vault's name, second the error (English)"))
        return pickOnFailure
    }
}
