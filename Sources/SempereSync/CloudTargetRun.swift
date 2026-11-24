import Foundation
import Sempere

/// One run of a store vault with a CloudKit target (docs/design/1.4-cloudkit.md §3.1): the app's sessions and
/// `sempere store sync` both use it, so the rules are the same, as for `FolderTargetRun`. The remote is the
/// vault's zone in the signed-in account's private database (`CloudRecordRemote` over the Apple adapter).
public enum CloudTargetRun {
    /// The zone of a vault.
    public static func zone(vaultId: UUID) -> String { CloudRecordNaming.zoneName(vaultId: vaultId.uuidString) }

    /// The remote of the target `stateURL` belongs to: its mirror lives beside the sync state (`cloudkit/`).
    public static func remote(store: any CloudRecordStore, vaultId: UUID, stateURL: URL, expectedUser: String?) -> CloudRecordRemote {
        CloudRecordRemote(store: store, zone: zone(vaultId: vaultId),
                          stateDirectory: stateURL.deletingLastPathComponent().appendingPathComponent("cloudkit", isDirectory: true),
                          expectedUser: expectedUser)
    }

    /// Runs the vault folder `vaultFolder` against `remote`: two-way (`twoWay`, the vault unlocked here) or upload-only
    /// (never writes the vault folder; `keepServerChanges`). Every received file is checked before it is placed and quarantined
    /// otherwise; the quarantine is the target's own (`stateURL`'s folder).
    public static func run(vaultFolder: URL, remote: CloudRecordRemote, vault: Vault?, stateURL: URL, twoWay: Bool,
                           options base: SyncOptions = SyncOptions()) throws -> SyncReport {
        var o = base
        o.dryRun = false
        o.deleteExtraneous = false
        o.publishForWebViewer = false
        o.pushOnly = !twoWay
        o.keepServerChanges = !twoWay
        // The mirror knows which notes changed (folder tags): a note whose tags did not change is skipped.
        o.skipUnchangedNotes = true
        if o.quarantineDirectory == nil {
            o.quarantineDirectory = stateURL.deletingPathExtension().appendingPathExtension("quarantine")
        }
        try FileIO.createPrivateDirectory(stateURL.deletingLastPathComponent())
        return try SyncEngine(directory: vaultFolder, vault: twoWay ? vault : nil, remote: remote, stateURL: stateURL, options: o).run()
    }
}
