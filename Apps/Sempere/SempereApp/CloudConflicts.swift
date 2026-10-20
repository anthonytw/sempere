import Foundation
import Sempere

/// A version iCloud Drive kept of a vault file or folder after two devices
/// changed it at once (`NSFileVersion`): readable at `url`.
struct CloudConflictVersion: Hashable, Sendable {
    var url: URL
    var modified: Date?
}

/// Resolving iCloud Drive conflicts on the vault's own files without ever
/// showing the system's version picker (docs/io.md "Conflicting versions",
/// format.md §1.3). Every rule is deterministic and loses nothing a reader
/// needs:
///
/// - the vault folder itself (a vault that was a package when it conflicted,
///   before vaults became plain folders): the other version is merged in with
///   `Vault.mergeCopy`, a union of the write-once files, so a note written on
///   either side survives whichever version iCloud kept;
/// - `settings.age`: merged per key (format.md §13.3); needs the key, so it
///   waits while the vault is locked;
/// - `vault.json` and `rewrap-journal.json`: the current version stays when
///   the other is the same file or differs only in the display `label`; any
///   other difference (a key change on one side) is left unresolved and
///   reported, never guessed;
/// - `sempere-summaries.sealed` and the summaries of `summaries/` (hints,
///   rewritten by their writers) and `keys/*.key.age` (named by the key they
///   hold): the current version stays.
///
/// Files under `notes/` and `inbox/` are write-once with unique names, so
/// they never conflict.
enum CloudConflicts {
    /// What one pass did.
    struct Outcome: Equatable, Sendable {
        /// Items whose conflict versions were merged (or dropped) and resolved, relative to the vault.
        var resolved: [String] = []
        /// Note folders that gained files from another version.
        var notes: Set<UUID> = []
        /// `settings.age` changed (merged from another version).
        var settingsChanged = false
        /// Items left unresolved until the vault is unlocked.
        var waitingForKey: [String] = []
        /// Items left unresolved because no rule can merge them, with why.
        var unresolved: [String: String] = [:]

        var isEmpty: Bool { resolved.isEmpty && waitingForKey.isEmpty && unresolved.isEmpty }
    }

    /// Root files whose conflicts are resolved by keeping the current version.
    static let keepCurrent: Set<String> = [PublishedSummaries.fileName]

    /// One pass over the vault folder and its mutable files. Writes go through
    /// `coordinate` (a coordinated write of the vault folder in iCloud).
    static func resolve(vault: Vault, hooks: CloudVault.Hooks,
                        coordinate: (() throws -> Void) throws -> Void = { try $0() }) throws -> Outcome {
        var out = Outcome()
        let root = vault.url

        // 1. The vault folder (a package's conflict carries the whole vault).
        let folderVersions = hooks.conflicts(root)
        if !folderVersions.isEmpty {
            var merged: [CloudConflictVersion] = []
            for v in folderVersions {
                let report: CopyMergeReport
                do {
                    var r = CopyMergeReport()
                    try coordinate { r = try vault.mergeCopy(from: v.url) }
                    report = r
                } catch let e as CopyMergeError {
                    // Not a copy of this vault: nothing in it belongs here.
                    out.unresolved["."] = "\(e)"
                    merged.append(v)
                    continue
                }
                for path in report.added {
                    let parts = path.split(separator: "/")
                    if parts.count >= 2, parts[0] == "notes", let id = UUID(uuidString: String(parts[1])) { out.notes.insert(id) }
                }
                if report.settingsMerged { out.settingsChanged = true }
                if report.settingsPending != nil, !vault.canRead {
                    out.waitingForKey.append(".")
                } else {
                    merged.append(v)
                }
            }
            if !merged.isEmpty {
                try hooks.resolve(root, merged)
                out.resolved.append(".")
            }
        }

        // 2. Root files rewritten in place.
        for name in ["vault.json", "rewrap-journal.json"] {
            let url = root.appendingPathComponent(name)
            let versions = hooks.conflicts(url)
            guard !versions.isEmpty else { continue }
            let current = try? BoundedRead.contents(of: url, maxBytes: BoundedRead.maxManifestBytes)
            var differing: [String] = []
            for v in versions {
                let other = try? BoundedRead.contents(of: v.url, maxBytes: BoundedRead.maxManifestBytes)
                if !sameExceptLabel(current, other, manifest: name == "vault.json") { differing.append(v.url.lastPathComponent) }
            }
            if differing.isEmpty {
                try hooks.resolve(url, versions)
                out.resolved.append(name)
            } else {
                out.unresolved[name] = "another device changed the keys at the same time"
            }
        }

        let settingsURL = root.appendingPathComponent(SharedSettings.fileName)
        let settingsVersions = hooks.conflicts(settingsURL)
        if !settingsVersions.isEmpty {
            if !vault.canRead {
                out.waitingForKey.append(SharedSettings.fileName)
            } else {
                var merged: SharedSettings?
                do { merged = try vault.readSharedSettings() } catch {}
                let before = merged
                for v in settingsVersions {
                    // A version that does not verify (another vault's, or damaged) is dropped.
                    guard let data = try? BoundedRead.contents(of: v.url, maxBytes: SharedSettings.maxFileBytes),
                          let other = try? vault.openSharedSettings(data).settings else { continue }
                    let theirs = SharedSettingsMigrations.migrated(other)
                    merged = merged.map { $0.merging(theirs) } ?? theirs
                }
                if let merged, merged != before {
                    try coordinate { try vault.writeSharedSettings(merged) }
                    out.settingsChanged = true
                }
                try hooks.resolve(settingsURL, settingsVersions)
                out.resolved.append(SharedSettings.fileName)
            }
        }

        // 3. Hints and identity files: the current version stays.
        var keep = keepCurrent.map { root.appendingPathComponent($0) }
        for dir in ["keys", PublishedSummaries.deviceFolderName] {
            let folder = root.appendingPathComponent(dir, isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
                keep.append(folder.appendingPathComponent(name))
            }
        }
        for url in keep {
            let versions = hooks.conflicts(url)
            guard !versions.isEmpty else { continue }
            try hooks.resolve(url, versions)
            out.resolved.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
        }
        return out
    }

    /// Whether two copies of `vault.json` (or of the journal) are the same, or
    /// differ only in the display label (format.md §2: covered by no tag).
    static func sameExceptLabel(_ a: Data?, _ b: Data?, manifest: Bool) -> Bool {
        if a == b { return true }
        guard manifest, let a, let b else { return false }
        return EpochManifest.sameExceptLabel(a, b)
    }

    // MARK: - iCloud

    static func liveConflicts(of url: URL) -> [CloudConflictVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map {
            CloudConflictVersion(url: $0.url, modified: $0.modificationDate)
        }
    }

    /// Marks the given conflict versions of `url` resolved and removes them, in
    /// a coordinated write. A version that appeared since (not in `versions`)
    /// is left for the next pass.
    static func liveResolve(_ url: URL, _ versions: [CloudConflictVersion]) throws {
        let wanted = Set(versions.map { $0.url.standardizedFileURL })
        try CloudVault.coordinatedWrite(url) {
            for v in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
            where wanted.contains(v.url.standardizedFileURL) {
                v.isResolved = true
                try v.remove()
            }
        }
    }
}
