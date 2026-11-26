import Foundation
import Sempere

// MARK: - Control files first, and again during a long run (docs/design/1.4-cloudkit.md §17)
//
// A run sends and reads the control files near its start, once: the epoch records (`epochs/`), `vault.json`, the join
// requests (`joins/`) and the passphrase copies (`keys/`). A run that then goes on for minutes or hours (a first upload of a
// whole vault, a big pull) used to leave a request or an approval written meanwhile for the next run. Now the run looks at
// them again between its transfers, at most every `SyncOptions.controlCheckInterval`:
//
// - the notes loop, the batches of the concurrent upload and download passes (a pool is never running while the pass
//   does: the pass runs on the run's own thread between batches), the large uploads and the batched listing call
//   `controlPassIfDue`;
// - the pass refreshes the target's listing (a CloudKit mirror reads its change feed first, `prepareRun`), then runs the
//   same steps the start of the run did, for the files that can matter within seconds: `epochs/` (a record goes before the
//   `vault.json` that names it), this device's `vault.json` change (an approval) pushed, a joining device's approval taken,
//   `joins/` both ways and `keys/`;
// - it never changes what a device change means: in the middle of a run `vault.json` is only pushed over an unchanged
//   server copy or created, or, for a joining device, its approval taken. A server copy that moved on (another epoch,
//   another device's list) waits for the next run, which judges it before the notes, as it always did, so the rules of
//   `format.md` (§15: one writer, record first, then `vault.json`; joins and keys are write-once or deleted by home) and what
//   a 1.3 device on the same folder or WebDAV target does are as before: the pass makes only requests the start of the run
//   makes too, in the same order, with the same preconditions.
//
// What the order of the first upload still is: control files, the summaries and inbox, then the notes newest first with
// each note's blobs before its revisions (format.md §8.1.4 step 4: normative, so notes cannot all go before every
// attachment), the large blobs last (`LargeUploads.swift`).

extension SyncEngine {
    /// Runs `groups` through the pool in batches of about two passes of the pool's width, the control files looked at
    /// between them when due. One batch: the whole thing, as before, while the pass is not due.
    func runInBatches<Item: Sendable>(_ groups: [TransferGroup<Item>], _ body: @escaping @Sendable (Item) throws -> Void) throws {
        let size = max(pool.width * 2, 8)
        var batch: [TransferGroup<Item>] = []
        var items = 0
        for g in groups {
            batch.append(g)
            items += g.first.count + g.then.count
            if items >= size {
                try pool.run(batch, body)
                batch = []
                items = 0
                try controlPassIfDue()
            }
        }
        if !batch.isEmpty { try pool.run(batch, body) }
    }

    /// Looks at the control files again if the last look was `controlCheckInterval` ago. Only on the run's own thread, with
    /// no transfer running. A failure of its own is reported (as at the start of the run); a run bound is thrown.
    func controlPassIfDue() throws {
        guard !options.dryRun, !options.pushOnly, !midRunControl, !epochTaken, epochHold == nil,
              Date().timeIntervalSince(lastControlPass) >= options.controlCheckInterval else { return }
        lastControlPass = Date()
        try checkCancelled()
        midRunControl = true
        defer { midRunControl = false }
        do {
            // A mirror reads its change feed (others do nothing); then the root as it is now.
            try transport.prepareRun()
            guard let entries = try transport.list([]) else { return }
            let root = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            // The server's `vault.json`, read only when something may have moved: this device's copy differs from the
            // recorded one, or the server's version tag does.
            fetchedManifest = nil
            let local = try? localMutable(Vault.manifestName)
            let record = state.mutable[Vault.manifestName]
            let manifestMoved = local.map { FileDigest.sha256($0) != record?.hash } ?? false
                || root[Vault.manifestName].map { $0.stamp != record?.stamp || record == nil } ?? (local != nil)
            if manifestMoved, root[Vault.manifestName] != nil {
                fetchedManifest = try? transport.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes)
            }
            do { try syncEpochRecords(remoteRoot: root) } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: Vault.epochsName, message: Self.describe(error)))
            }
            if manifestMoved { syncMutableFiles(root, settleVersions: false, only: [Vault.manifestName]) }
            fetchedManifest = nil
            do { try syncJoinRequests(remoteRoot: root) } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: Vault.joinsName, message: Self.describe(error)))
            }
            do { try syncPassphraseCopies(remoteRoot: root) } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: Vault.keysName, message: Self.describe(error)))
            }
        } catch {
            try rethrowRunLimit(error)
            report.skipped.append(.init(path: Vault.manifestName, message: "control files not looked at again: \(Self.describe(error))"))
        }
    }
}
