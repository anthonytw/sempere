import Foundation
import Sempere

// MARK: - A provider's conflict versions (docs/design/device-first-sync.md §3.3, §5.1)
//
// iCloud Drive (and other providers) keep the losing copy of a file two
// devices changed at once as a conflict version (`NSFileVersion`), beside the
// one they made current; left alone, the system's version picker shows it to
// the user. A transport hands them over (`SyncRemote.conflictVersions`), and
// each run settles those of the root's mutable files before syncing them, by
// the rules of format.md §1.3 and §13.3 (the app's `CloudConflicts`, ported):
//
// - `vault.json` and `rewrap-journal.json`: a version that is the current
//   file, or (`vault.json`) differs from it only in the display label, is
//   dropped; any other is kept beside the local file as a conflict copy and
//   reported (`conflicts`, exit 3), as a change on both sides is. Never picked.
// - `settings.age`: each version that verifies is merged per key into the
//   local copy (the vault unlocked); the run's settings sync then merges that
//   with the current remote copy. Locked, the versions wait for an unlocked run.
// - the web viewer's `sempere-summaries.sealed` and `sempere-index.json`
//   (rewritten by every writer): the current version stays.
//
// Then the versions settled are removed (`resolveConflicts`), so no version
// picker ever reaches the user. Revisions and blobs are write-once with names
// that never repeat, so they do not fork. Mirrors (`pushOnly`) and dry runs
// leave versions alone.

extension SyncEngine {
    /// Root files whose conflict versions a run settles.
    static let versionedRootFiles = [Vault.manifestName, Vault.journalName, SharedSettings.fileName,
                                     PublishedSummaries.fileName, WebIndex.fileName]

    func settleConflictVersions(_ remoteRoot: [String: RemoteEntry]) {
        guard !options.pushOnly, !options.dryRun else { return }
        for name in Self.versionedRootFiles {
            guard let entry = remoteRoot[name], !entry.isCollection else { continue }
            let versions = transport.conflictVersions([name])
            guard !versions.isEmpty else { continue }
            do {
                switch name {
                case Vault.manifestName, Vault.journalName: try settleRootFileVersions(name, entry: entry, versions)
                case SharedSettings.fileName: try settleSettingsVersions(versions)
                default:
                    try transport.resolveConflicts([name], versions)
                    report.skipped.append(.init(path: name, message: "\(versions.count) conflict versions on the remote "
                        + "dropped; the current one kept (it is rewritten by every writer)"))
                }
            } catch {
                report.errors.append(.init(path: name, message: "conflict versions: " + Self.describe(error)))
            }
        }
    }

    /// `vault.json` or the rewrap journal: the same file (or label only) is
    /// dropped, anything else kept as a local conflict copy and reported.
    private func settleRootFileVersions(_ name: String, entry: RemoteEntry, _ versions: [RemoteVersion]) throws {
        // The current copy is compared against; one not downloaded yet waits for a later run.
        guard try available([name], entry: entry) else { return }
        let current = try transport.read([name], maxBytes: BoundedRead.maxManifestBytes).data
        var settled: [RemoteVersion] = []
        for v in versions {
            let data = try transport.readVersion([name], v, maxBytes: BoundedRead.maxManifestBytes)
            if data == current || (name == Vault.manifestName && VaultManifest.sameExceptLabel(data, current)) {
                settled.append(v)
                continue
            }
            // Kept here (an identical copy is reused), so removing it from the remote loses nothing.
            try conflict(name, remote: data, detail: "the remote kept another version of it (a provider conflict); "
                         + "both are kept, nothing was picked")
            settled.append(v)
        }
        try transport.resolveConflicts([name], settled)
    }

    /// `settings.age`: every version that verifies merged per key into the local copy.
    private func settleSettingsVersions(_ versions: [RemoteVersion]) throws {
        let name = SharedSettings.fileName
        guard let vault, vault.canRead else {
            report.skipped.append(.init(path: name, message: "\(versions.count) conflict versions on the remote; "
                + "merged once the vault is unlocked"))
            return
        }
        if manifestHash() != checkerBaseManifest {
            report.skipped.append(.init(path: name, message: "vault.json changed in this run; conflict versions merged on the next run"))
            return
        }
        try requireLocalWrite("merge conflict versions of \(name)")
        var merged = try? vault.readSharedSettings()
        let before = merged
        var settled: [RemoteVersion] = []
        for v in versions {
            let data: Data
            do { data = try transport.readVersion([name], v, maxBytes: SharedSettings.maxFileBytes) } catch {
                report.skipped.append(.init(path: name, message: "a conflict version cannot be read (\(Self.describe(error))); left"))
                continue
            }
            do {
                let theirs = SharedSettingsMigrations.migrated(try vault.openSharedSettings(data).settings)
                merged = merged.map { $0.merging(theirs) } ?? theirs
            } catch SharedSettingsError.needsNewerReader {
                // A newer app's settings: never dropped by a reader that cannot merge them.
                report.skipped.append(.init(path: name, message: "a conflict version needs a newer reader; left on the remote"))
                continue
            } catch {
                // Another vault's, or damaged: not settings of this vault, nothing to keep.
            }
            settled.append(v)
        }
        if let merged, merged != before {
            try vault.writeSharedSettings(merged)
            report.merged.append(name)
        }
        try transport.resolveConflicts([name], settled)
    }
}
