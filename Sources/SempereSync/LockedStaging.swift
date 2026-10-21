import Foundation
import Sempere

/// Downloads for a vault nobody unlocked on this device, staged until its next unlock
/// (docs/design/device-first-sync.md §4.1, "Locked runs"; P8b).
///
/// A closed or locked vault's runs only upload: nothing unverified is ever placed in its working copy. To
/// still have what other devices wrote on the device when it is unlocked (offline, say), a locked run also
/// **pulls** into a shadow of the working copy: `<directory>/copy.sempere`, whose write-once files are hard
/// links of the working copy's (files are replaced by rename, never written in place, so a link never
/// changes under the working copy). The run is pull-only (`SyncOptions.pullOnly`: nothing is ever written
/// to the target, review of #77, S1) and has no key: what it receives is checked for its structure only, and
/// nothing is deleted. Only the shadow gets those files. The shadow's root files (`vault.json`, the journal,
/// `settings.age`) are copied once, when it is made, and never rewritten from the working copy after.
///
/// At the unlock, `place` runs the engine on the working copy against the shadow as a local folder
/// remote, with the key and pull-only: every staged write-once file is checked fully and placed, or
/// quarantined (format.md §9.1), as any download would be. The root files are not placed (S3): the shadow's
/// are set to the working copy's first, so they come only through the normal two-way run and its checks
/// (the key hierarchy's trusted-home rule among them). What the target's own sync state shows this device
/// removed on purpose (thinned or collected revisions and blobs, adopted voice notes) is dropped from the
/// shadow first, so nothing comes back (S2). Its state starts empty: a union that deletes nothing. The
/// staging is removed after every placing attempt, whatever came of it; what failed is staged again by
/// the next locked run, or simply arrives with the two-way runs.
///
/// Everything lives in the target's own state folder, so staging is per (vault, target) and isolated.
public struct LockedStaging: Sendable {
    /// `<target state dir>/incoming`.
    public let directory: URL
    /// The target's own sync state (what this device removed on purpose is read from it at placing).
    public let targetState: URL?

    public init(directory: URL, targetState: URL? = nil) {
        self.directory = directory
        self.targetState = targetState
    }

    /// The staging folder of the target whose sync state is `stateURL`.
    public init(targetState stateURL: URL) {
        self.init(directory: stateURL.deletingLastPathComponent().appendingPathComponent("incoming", isDirectory: true),
                  targetState: stateURL)
    }

    /// The shadow copy the locked runs sync.
    public var shadow: URL { directory.appendingPathComponent("copy.sempere", isDirectory: true) }
    /// The shadow's own sync state with the target.
    public var stateURL: URL { directory.appendingPathComponent("sync-state.json") }
    /// The placing run's state (fresh each time).
    var placeStateURL: URL { directory.appendingPathComponent("place-state.json") }

    /// True when something is staged (a locked run ran since the last placing).
    public var exists: Bool { FileManager.default.fileExists(atPath: shadow.path) }

    // MARK: - Locked runs

    /// Brings the shadow level with `vaultFolder` (links every write-once file it lacks; the root files only
    /// when the shadow is made), then runs `run` on the shadow and its state URL with `options` made
    /// pull-only: the caller's transport, with no vault. Returns that run's report.
    public func stage(vaultFolder: URL, options base: SyncOptions = SyncOptions(),
                      run: (_ shadow: URL, _ stateURL: URL, _ options: SyncOptions) throws -> SyncReport) throws -> SyncReport {
        try FileIO.createPrivateDirectory(directory)
        try mirror(from: vaultFolder)
        return try run(shadow, stateURL, Self.stagingOptions(base))
    }

    /// `base` for a staging run: pull-only, nothing deleted, nothing published.
    public static func stagingOptions(_ base: SyncOptions) -> SyncOptions {
        var o = base
        o.pullOnly = true
        o.pushOnly = false
        o.keepServerChanges = true
        o.deleteExtraneous = false
        o.publishForWebViewer = false
        o.publishSummaries = false
        return o
    }

    /// The write-once files staged that the working copy at `vaultFolder` lacks: what the next unlock places.
    public func pending(vaultFolder: URL) -> [String] {
        guard exists else { return [] }
        var out: [String] = []
        walk(shadow, relative: []) { rel, _ in
            guard Self.isWriteOnce(rel) else { return }
            let local = rel.reduce(vaultFolder) { $0.appendingPathComponent($1) }
            if !FileManager.default.fileExists(atPath: local.path) { out.append(rel.joined(separator: "/")) }
        }
        return out.sorted()
    }

    // MARK: - At the unlock

    /// Places what was staged into the working copy at `vaultFolder`, checked under `vault` (which must be
    /// able to read): one pull-only engine run against the shadow, a union that deletes nothing, root files
    /// left out. The staging is removed afterwards, whatever came of it. Returns nil when nothing was staged.
    public func place(vaultFolder: URL, vault: Vault, options base: SyncOptions = SyncOptions()) throws -> SyncReport? {
        guard exists else { return nil }
        defer { discard() }
        try matchRootFiles(of: vaultFolder)
        dropRemovedOnPurpose(vaultFolder: vaultFolder)
        var o = base
        o.dryRun = false
        o.pullOnly = true
        o.pushOnly = false
        o.keepServerChanges = false
        o.deleteExtraneous = false
        o.publishForWebViewer = false
        o.publishSummaries = false
        if o.quarantineDirectory == nil, let targetState {
            // The target's own quarantine: what fails here is listed where the target's runs list theirs.
            o.quarantineDirectory = targetState.deletingPathExtension().appendingPathExtension("quarantine")
        }
        try? FileManager.default.removeItem(at: placeStateURL)
        SyncState.removeTransfers(placeStateURL)
        let engine = SyncEngine(directory: vaultFolder, vault: vault, remote: FolderRemote(root: shadow),
                                stateURL: placeStateURL, options: o)
        return try engine.run()
    }

    /// The shadow's root files become the working copy's (a placing never takes them, S3).
    private func matchRootFiles(of vaultFolder: URL) throws {
        let fm = FileManager.default
        for name in [Vault.manifestName, Vault.journalName, SharedSettings.fileName] {
            let local = vaultFolder.appendingPathComponent(name), staged = shadow.appendingPathComponent(name)
            if fm.fileExists(atPath: local.path) {
                _ = try LocalFS.write(try BoundedRead.contents(of: local, maxBytes: 64 << 20), to: staged, replacing: true)
            } else {
                try? fm.removeItem(at: staged)
            }
        }
    }

    /// Drops from the shadow what the target's sync state shows this device held and removed on purpose
    /// (S2): revisions and blobs it synced or thinned that the working copy no longer has, and inbox files
    /// it synced that are gone here (adopted). The engine with the target's state would not bring them back;
    /// a placing with a fresh state would.
    private func dropRemovedOnPurpose(vaultFolder: URL) {
        guard let targetState, let state = try? SyncState.load(targetState) else { return }
        let fm = FileManager.default
        var paths: [[String]] = []
        for key in Array(state.files.keys) + Array((state.thinned ?? [:]).keys) {
            paths.append([Vault.notesName] + key.split(separator: "/").map(String.init))
        }
        for name in (state.inbox ?? [:]).keys { paths.append([CaptureFile.folderName, name]) }
        for rel in paths {
            let local = rel.reduce(vaultFolder) { $0.appendingPathComponent($1) }
            guard !fm.fileExists(atPath: local.path) else { continue }
            try? fm.removeItem(at: rel.reduce(shadow) { $0.appendingPathComponent($1) })
        }
    }

    /// Removes everything staged (placed, or the target removed).
    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Files

    /// Write-once vault files: revisions and blobs (`notes/`), `keys/`, `inbox/`, notebook records and
    /// devices' published summaries. Everything else at the root is mutable.
    static func isWriteOnce(_ rel: [String]) -> Bool {
        guard rel.count >= 2, let first = rel.first, !(rel.last ?? "").hasPrefix(".") else { return false }
        return [Vault.notesName, Vault.keysName, CaptureFile.folderName, NotebookRecords.folderName,
                PublishedSummaries.deviceFolderName].contains(first)
    }

    private func mirror(from vaultFolder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: shadow, withIntermediateDirectories: true)
        var failure: (any Error)?
        walk(vaultFolder, relative: []) { rel, url in
            guard failure == nil, !(rel.last ?? "").hasPrefix(".") else { return }
            let to = rel.reduce(shadow) { $0.appendingPathComponent($1) }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if Self.isWriteOnce(rel) {
                    guard !fm.fileExists(atPath: to.path) else { return }
                    do { try fm.linkItem(at: url, to: to) } catch { try fm.copyItem(at: url, to: to) }
                } else if rel.count == 1, !fm.fileExists(atPath: to.path) {
                    // vault.json, the journal, settings.age: copied once, when the shadow is made. Never
                    // rewritten after (S1): the pull-only runs keep what the target has.
                    let data = try BoundedRead.contents(of: url, maxBytes: 64 << 20)
                    _ = try LocalFS.write(data, to: to, replacing: true)
                }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// Calls `body` with every regular file below `root` (hidden folders skipped).
    private func walk(_ root: URL, relative: [String], _ body: ([String], URL) -> Void) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names.sorted() {
            let url = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if name.hasPrefix(".") { continue }
                walk(url, relative: relative + [name], body)
            } else {
                body(relative + [name], url)
            }
        }
    }
}
