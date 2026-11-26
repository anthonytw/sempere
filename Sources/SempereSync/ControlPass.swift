import Foundation
import Sempere

// MARK: - Control files first, and again during a long run (docs/design/1.4-cloudkit.md §17)
//
// A run sends and reads the control files near its start, once: the epoch records (`epochs/`), `vault.json`, the join
// requests (`joins/`) and the passphrase copies (`keys/`). A run that then goes on for minutes or hours (a first upload of a
// whole vault, a big pull) used to leave a request or an approval written meanwhile for the next run. Now the run looks at
// them again between its transfers, at most every `SyncOptions.controlCheckInterval`:
//
// - the notes loop, the concurrent upload and download passes, the large uploads and the batched listing call
//   `controlPassIfDue`; a pool stops handing out items only when a pass is due (`TransferPool.run(until:)`), lets the ones
//   running finish, and runs again after the pass, so a pass never runs beside a transfer and no batch is cut otherwise;
// - the pass refreshes the target's listing (`SyncRemote.refreshListing`: a CloudKit mirror reads its change feed, nothing of
//   `prepareRun`'s run-start work), then runs the
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
    /// Runs `groups` through the pool, which pauses only when the control files are due: the pass runs, then the rest goes on.
    func runInBatches<Item: Sendable>(_ groups: [TransferGroup<Item>], _ body: @escaping @Sendable (Item) throws -> Void) throws {
        var rest = groups
        while !rest.isEmpty {
            let eligible = controlPassEligible, last = lastControlPass, interval = options.controlCheckInterval
            rest = try pool.run(rest, until: { eligible && Date().timeIntervalSince(last) >= interval }, body)
            if !rest.isEmpty { try controlPassIfDue() }
        }
    }

    /// A pass may run in this run at all (not dry, push-only, held for an epoch, or after a later epoch was taken).
    var controlPassEligible: Bool {
        !options.dryRun && !options.pushOnly && !midRunControl && !epochTaken && epochHold == nil
    }

    /// Looks at the control files again if the last look was `controlCheckInterval` ago. Only on the run's own thread, with
    /// no transfer running. A failure of its own is reported once (as at the start of the run); a run bound, an error that is not
    /// transient (the account changed, the zone or base is gone) or a cancellation stops the run.
    func controlPassIfDue() throws {
        guard controlPassEligible, Date().timeIntervalSince(lastControlPass) >= options.controlCheckInterval else { return }
        lastControlPass = Date()
        try checkCancelled()
        midRunControl = true
        defer { midRunControl = false }
        let marks = (errors: report.errors.count, skipped: report.skipped.count, ignored: report.ignored.count)
        defer { dedupe(since: marks) }
        // The target's listing as it is now: a mirror reads its feed (only what it lacks). A failure is reported once and the run goes
        // on, unless it means the target is no longer this vault's (the account changed, the zone or base is gone): that stops the
        // run as a bound does, with its report and state kept.
        do { try transport.refreshListing() } catch { return try passFailed(error) }
        let listed: [RemoteEntry]?
        do { listed = try transport.list([]) } catch { return try passFailed(error) }
        // The base is gone (a deleted zone, a folder removed): nothing here may go on.
        guard let entries = listed else { throw SyncError.stopped("the target no longer holds this vault (its base is gone)") }
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
        func step(_ path: String, _ body: () throws -> Void) throws {
            do { try body() } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: path, message: Self.describe(error)))
            }
        }
        try step(Vault.epochsName) { try syncEpochRecords(remoteRoot: root) }
        if manifestMoved { syncMutableFiles(root, settleVersions: false, only: [Vault.manifestName]) }
        fetchedManifest = nil
        try step(Vault.joinsName) { try syncJoinRequests(remoteRoot: root) }
        try step(Vault.keysName) { try syncPassphraseCopies(remoteRoot: root) }
    }

    /// A failure of the pass's own requests: a run bound stops the run; an error that says the target is not this vault's any more
    /// ends it as `stopped`; any other is reported (once) and the run carries on.
    private func passFailed(_ error: any Error) throws {
        try rethrowRunLimit(error)
        if let e = error as? CloudRecordError {
            switch e {
            case .zoneGone, .otherAccount, .account: throw SyncError.stopped(Self.describe(error))
            default: break
            }
        }
        report.skipped.append(.init(path: Vault.manifestName, message: "control files not looked at again: \(Self.describe(error))"))
    }

    /// Entries a pass added that an earlier one (or the start of the run) already made are dropped: a failing file is said once.
    private func dedupe(since marks: (errors: Int, skipped: Int, ignored: Int)) {
        func unique<T: Equatable>(_ all: inout [T], from mark: Int) {
            guard all.count > mark else { return }
            var kept = Array(all[..<mark])
            for e in all[mark...] where !kept.contains(e) { kept.append(e) }
            all = kept
        }
        unique(&report.errors, from: marks.errors)
        unique(&report.skipped, from: marks.skipped)
        unique(&report.ignored, from: marks.ignored)
    }
}
