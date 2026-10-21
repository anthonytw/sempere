import Foundation
import Sempere

/// Downloads for a vault nobody unlocked on this device, staged until its next unlock
/// (docs/design/device-first-sync.md §4.1, "Locked runs"; P8b).
///
/// A closed or locked vault's runs only upload: nothing unverified is ever placed in its working copy. To
/// still have what other devices wrote on the device when it is unlocked (offline, say), a locked run also
/// syncs a **shadow** of the working copy with the target: `<directory>/copy.sempere`, whose files are hard
/// links of the working copy's (files are replaced by rename, never written in place, so a link never
/// changes under the working copy). The run has no key: what it receives is checked for its structure
/// only, and nothing is deleted (`SyncEngine` with no vault). Only the shadow gets those files.
///
/// At the unlock, `place` runs the engine on the working copy against the shadow as a local folder
/// remote, with the key: every staged file is checked fully and placed, or quarantined (format.md §9.1),
/// as any download would be; mutable files follow the usual rules. Its state starts empty, so it is a
/// union and deletes nothing. The staging folder is then removed.
///
/// Everything lives in the target's own state folder, so staging is per (vault, target) and isolated.
public struct LockedStaging: Sendable {
    /// `<target state dir>/incoming`.
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The staging folder of the target whose sync state is `stateURL`.
    public init(targetState stateURL: URL) {
        self.init(directory: stateURL.deletingLastPathComponent().appendingPathComponent("incoming", isDirectory: true))
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

    /// Brings the shadow level with `vaultFolder` (links every file it lacks; the root's mutable files are
    /// copied, replacing the shadow's), then runs `run` on the shadow and its state URL: the caller's
    /// transport, two-way with no vault. Returns that run's report.
    public func stage(vaultFolder: URL, run: (_ shadow: URL, _ stateURL: URL) throws -> SyncReport) throws -> SyncReport {
        try FileIO.createPrivateDirectory(directory)
        try mirror(from: vaultFolder)
        return try run(shadow, stateURL)
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
    /// able to read): one engine run against the shadow, a union that deletes nothing. Then the staging
    /// folder is removed. Returns nil when nothing was staged.
    public func place(vaultFolder: URL, vault: Vault, options base: SyncOptions = SyncOptions()) throws -> SyncReport? {
        guard exists else { return nil }
        var o = base
        o.dryRun = false
        o.pushOnly = false
        o.keepServerChanges = false
        o.deleteExtraneous = false
        o.publishForWebViewer = false
        if o.quarantineDirectory == nil {
            o.quarantineDirectory = stateURL.deletingPathExtension().appendingPathExtension("quarantine")
        }
        try? FileManager.default.removeItem(at: placeStateURL)
        SyncState.removeTransfers(placeStateURL)
        let engine = SyncEngine(directory: vaultFolder, vault: vault, remote: FolderRemote(root: shadow),
                                stateURL: placeStateURL, options: o)
        let report = try engine.run()
        // Kept for the next try when the run stopped early or failed to place some file; otherwise gone.
        if report.stoppedEarly == nil, report.errors.isEmpty { discard() }
        return report
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
                } else if rel.count == 1 {
                    // vault.json, the journal, settings.age: the working copy's, as the target last confirmed
                    // them or newer; the shadow's run judges them like any locked run.
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
