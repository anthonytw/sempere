import Foundation

/// Clears the Finder's `kHasBundle` flag on the vault and backup folders the app makes or uses (`FinderBundleBit`,
/// docs/io.md "Vaults are folders"): the store's vaults, folder sync targets and backups, at setup and at each run.
/// Owner's build 12: iCloud vault folders carried the flag, so every device showed them as packages and iCloud Drive
/// synced them as one item. The caller holds the folder's security scope. (The app's `clear(_:_:)` logs to its
/// `AppPerfSink`.)
public enum BundleBitRepair {
    /// What the folder is to the app, for the log.
    public enum Role: String, Sendable {
        case storeVault = "store vault"
        /// A vault the app opens (a store vault, or one handed over from Files or the Finder).
        case openedVault = "opened vault"
        case syncTarget = "sync target"
        case backup
    }

    /// Clears the flag on `url` when it is a vault or backup folder that has it (`FinderBundleBit.appliesTo`: `….sempere`,
    /// `….sempere-vault`, `….sempere-backup`, or any folder holding a `vault.json` or `backup.json`); logs to `log` when
    /// it did (a notice: the same folder logged at every run means something sets the flag again, such as iCloud Drive
    /// holding the folder as a package, docs/io.md "A vault folder held as a package"), and when it is set and could
    /// not be cleared (an error, with `errno`).
    @discardableResult
    public static func clear(_ url: URL, _ role: Role, log: any PerfSink) -> Bool {
        guard FinderBundleBit.appliesTo(url) else { return false }
        switch FinderBundleBit.clearReporting(at: url) {
        case .notSet:
            return false
        case .cleared:
            log.log(.notice, "bundleBit", "cleared kHasBundle on a \(role.rawValue) folder")
            return true
        case .failed(let code):
            log.log(.error, "bundleBit", "kHasBundle on a \(role.rawValue) folder could not be cleared (errno \(code))")
            return false
        }
    }
}
