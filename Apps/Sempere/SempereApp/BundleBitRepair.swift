import Foundation
import os
import Sempere

private let bundleBitLog = Logger(subsystem: "io.github.anthonytw.sempere", category: "bundleBit")

/// Clears the Finder's `kHasBundle` flag on the vault and backup folders the app makes or uses (`FinderBundleBit`,
/// docs/io.md "Vaults are folders"): the store's vaults, folder sync targets and backups, at setup and at each run.
/// Owner's build 12: iCloud vault folders carried the flag, so every device showed them as packages and iCloud Drive
/// synced them as one item. The caller holds the folder's security scope.
enum BundleBitRepair {
    /// What the folder is to the app, for the log.
    enum Role: String, Sendable {
        case storeVault = "store vault"
        /// A vault the app opens (a store vault, or one handed over from Files or the Finder).
        case openedVault = "opened vault"
        case syncTarget = "sync target"
        case backup
    }

    /// Clears the flag on `url` when it is a `….sempere` or `….sempere-backup` folder that has it; logs when it did.
    @discardableResult
    nonisolated static func clear(_ url: URL, _ role: Role) -> Bool {
        guard FinderBundleBit.appliesTo(url), FinderBundleBit.clear(at: url) else { return false }
        bundleBitLog.notice("cleared kHasBundle on a \(role.rawValue, privacy: .public) folder")
        return true
    }
}
