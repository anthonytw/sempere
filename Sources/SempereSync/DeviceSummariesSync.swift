import Foundation
import Sempere

// MARK: - Per-device published summaries (format.md §12.5, design §5.1)
//
// `summaries/<device>.sealed` is written only by its device, which signs it
// (`SMPU` `0x04`): its clear header carries its epoch and a `version` its
// writer raises with every write, and a P-256 + ML-DSA-65 signature by the
// device covers the vault, the epoch, the device, the version and the sealed
// bytes (`AuthorMessage.summaries`). A copy is *ordered* when it opens under
// the vault's key, names the device of its file name, its signature verifies
// under the signing keys of a device with that id on this device's checked
// list (never keys from a received file), and its version is at most
// `PublishedSummaries.futureWindow` (7 days) ahead of this device's clock (a
// clock-skew guard). An unsigned or badly signed copy is never ordered: it
// never replaces an ordered one, and is replaced by one (the owner repairs it).
// A run:
//
// - another device's file: copied to the side that lacks it (only when it is
//   ordered, unlocked); when both hold one that differs, the later ordered copy
//   wins on both sides (equal versions: the greater SHA-256, so every device
//   picks the same one). An unordered copy never replaces an ordered one.
// - this device's own file (`SyncOptions.deviceID`): the local copy is the
//   truth and replaces the remote one, unless the remote one is ordered after
//   it, which only this device's own keys can sign (another install with this
//   device's keys, a copied state folder, or this device's own later write it
//   lost): that one is left, and neither side rewrites above the other at
//   once, so the runs go quiet; the next later write travels, and once that
//   copy's version is more than the window in the past the device seals and
//   signs its own entries again at the clock and puts them (at most once per
//   window per install).
// - a copy that does not open and whose clear header (`SMPU` `0x04`, bound as
//   associated data) names an epoch above this device's key's, and no later
//   than the one its local vault.json names (or the next one, when the
//   server's vault.json is a verified child of the epoch this device pinned,
//   `EpochFrontier.verifiedChild`), is never replaced, own file or not: this
//   device holds no key for it (a removed or lagging device would otherwise
//   put its stale copy back on every run). The header of a copy that does not
//   open is not authenticated, so for a current device (its vault.json names
//   its key's epoch) nothing is believed later: any copy that does not open is
//   damaged, stale or forged, and is replaced like any unordered copy.
// - locked (or with a `vault.json` that did not check, so no signing key is
//   trusted), nothing is ordered: a differing copy is left on both sides, except
//   that a locked staging run (pull-only, `LockedStaging`) stages the remote
//   copy, which the placing run then orders under the key.
//
// "The side that changed since the last run wins", the rule before, has no
// order between versions: with C syncing only R0 and A and B bridging R0 and
// R1, two of C's versions circled R0 → B → R1 → A → R0 for ever, and only R0
// was ever put right by C (NDeviceStressTests seeds 41 and 46,
// `testTwoBridgesSettleAnotherDevicesSummaries`).
//
// Files are hints (§12.3): a received one is placed only when it is ordered
// (unlocked) or at least starts like a sealed file (locked), and is never
// quarantined (a file sealed under an earlier secret is expected after a key
// change, and is only stale). Nothing is ever deleted. Push-only runs only
// upload, and never replace a later version.

extension SyncEngine {

    /// - Parameter only: the names to sync (the pass before the notes syncs this device's own file, offline audit
    ///   P6); nil: every file.
    func syncDeviceSummaries(remoteRoot: [String: RemoteEntry], only: Set<String>? = nil) throws {
        let folder = PublishedSummaries.deviceFolderName
        let localDir = root.appendingPathComponent(folder, isDirectory: true)
        var local = Set(try LocalFS.entries(localDir).filter { PublishedSummaries.device(ofFileName: $0) != nil && only?.contains($0) != false })
        if let dir = remoteRoot[folder], dir.isCollection, folderArriving([folder], entry: dir) { return }
        var listed: [String: RemoteEntry] = [:]
        // Made by the pass before the notes, after the root was listed: listed now too.
        if remoteRoot[folder]?.isCollection == true || collectionKnown([folder]), let entries = try transport.list([folder]) {
            try budget.list(entries.count)
            for e in entries where !e.isCollection {
                if PublishedSummaries.device(ofFileName: e.name) != nil {
                    guard only?.contains(e.name) != false else { continue }
                    listed[e.name] = e
                } else if !e.name.hasPrefix(".") {
                    report.ignored.append("\(folder)/\(SyncReport.printable(e.name))")
                }
            }
        }
        // Not in the pass before the notes (only this device's own file): the full pass after them does it (KH6, §7.3).
        if only == nil { local = try dropSummariesBelowReencryption(local: local, listed: &listed, localDir: localDir) }
        let records = state.deviceSummaries ?? [:]
        var kept: [String: SyncState.MutableRecord] = [:]
        for name in local.union(listed.keys).sorted() {
            do {
                try checkCancelled()
                if let r = try syncDeviceSummary(name, localDir: localDir, hasLocal: local.contains(name), remote: listed[name],
                                                 record: records[name]) {
                    kept[name] = Self.timedSummary(r, previous: records[name])
                }
            } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: "\(folder)/\(name)", message: Self.describe(error)))
                if let r = records[name] { kept[name] = r }
            }
        }
        if let only {
            // Only these names were looked at: the others keep their records.
            let merged = records.filter { !only.contains($0.key) }.merging(kept) { _, b in b }
            if !options.dryRun { state.deviceSummaries = merged.isEmpty ? nil : merged }
            return
        }
        if !options.dryRun { state.deviceSummaries = kept.isEmpty ? nil : kept }
    }

    /// Below a finished re-encryption (design §7.3; review of #89, S1): per-device files sealed under a key from before
    /// it are deleted here and on the target (under a strong version tag, once per bytes), where this device's list
    /// stands and the run is not held. They are hints; their devices seal them again under the current key. Returns
    /// the local names left.
    func dropSummariesBelowReencryption(local: Set<String>, listed: inout [String: RemoteEntry], localDir: URL) throws -> Set<String> {
        guard !options.dryRun, !options.pushOnly, epochHold == nil, epochStatus.conflict == nil, let v = epochJudge,
              let m = v.recordsObsoleteBelow else { return local }
        let folder = PublishedSummaries.deviceFolderName
        var left = local
        for name in local.sorted() {
            let file = localDir.appendingPathComponent(name)
            guard let data = try? BoundedRead.contents(of: file, maxBytes: PublishedSummaries.maxFileBytes),
                  v.summariesUnderEpoch(below: m, data) else { continue }
            try requireLocalWrite("delete \(folder)/\(name)")
            try LocalFS.remove(file)
            left.remove(name)
            report.deleted.append(.init(side: "local", path: "\(folder)/\(name)"))
        }
        guard listStandsHere(v) else { return left }
        for (name, e) in listed.sorted(by: { $0.key < $1.key }) {
            let path = "\(folder)/\(name)"
            guard let got = try? transport.read([folder, name], maxBytes: PublishedSummaries.maxFileBytes),
                  v.summariesUnderEpoch(below: m, got.data) else { continue }
            let sha = FileDigest.sha256(got.data)
            guard state.deletedObsolete?[path] != sha else { continue }
            guard let etag = (got.etag ?? e.etag).flatMap({ Self.isStrong($0) ? $0 : nil }) else {
                report.skipped.append(.init(path: path, message: "sealed under a key from before the re-encryption; the target "
                    + "gives no strong version tag to delete it under"))
                continue
            }
            if try transport.delete([folder, name], ifETag: etag) {
                report.deleted.append(.init(side: "remote", path: path))
                state.deletedObsolete = state.deletedObsolete ?? [:]
                state.deletedObsolete?[path] = sha
                listed[name] = nil
            }
        }
        return left
    }

    /// `r` with the timing of its stamp, as `timedInbox`.
    static func timedSummary(_ r: SyncState.MutableRecord, previous: SyncState.MutableRecord?) -> SyncState.MutableRecord {
        if r == previous, r.timing != nil { return r }
        var out = r
        out.timing = settle(previous?.stamp == r.stamp ? previous?.timing : nil, trusted: stampCanSettle(r.stamp))
        return out
    }

    private func syncDeviceSummary(_ name: String, localDir: URL, hasLocal: Bool, remote: RemoteEntry?,
                                   record: SyncState.MutableRecord?) throws -> SyncState.MutableRecord? {
        let folder = PublishedSummaries.deviceFolderName
        let path = "\(folder)/\(name)"
        let file = localDir.appendingPathComponent(name)
        let own = options.deviceID.map { PublishedSummaries.deviceFileName($0) == name } ?? false
        let localData = hasLocal ? try BoundedRead.contents(of: file, maxBytes: PublishedSummaries.maxFileBytes) : nil
        let localHash = localData.map { FileDigest.sha256($0) }
        guard let remote else {
            guard let localData, let localHash else { return nil }
            return try putDeviceSummary(name, localData, hash: localHash, condition: .create)
        }
        if try !available([folder, name], entry: remote) { return record }
        // Unchanged on the remote since the last run (its token, once settled: a whole-second tag hides a same-size
        // rewrite within the second) and here (its hash): nothing to do.
        if let record, record.settled == true, record.stamp != nil, record.stamp == remote.stamp, record.hash == localHash,
           record.recheckAfter.map({ options.now < $0 }) ?? true { return record }
        guard let localData, let localHash else {
            if own || options.pushOnly { return nil }
            return try takeDeviceSummary(name, remote: remote, replacing: false)
        }
        let got = try fetchDeviceSummary(name, remote: remote)
        let remoteHash = FileDigest.sha256(got.data)
        let stamp = got.etag ?? remote.stamp
        if remoteHash == localHash { return .init(hash: localHash, stamp: stamp) }
        let condition = stamp.flatMap { Self.isStrong($0) ? PutCondition.replace(etag: $0) : nil } ?? .unconditional
        guard let device = PublishedSummaries.device(ofFileName: name), let v = checker(), v.canRead,
              v.listStatus.problem == nil else {
            // Locked, or a list that did not check (no signing key to verify against): no version can be read.
            // The own file is still this device's truth; a locked staging run (pull-only, `LockedStaging`)
            // stages the remote copy, which the placing run orders under the key.
            if own { return try putDeviceSummary(name, localData, hash: localHash, condition: condition) }
            if options.pullOnly, !options.pushOnly {
                return try placeDeviceSummary(name, got.data, stamp: stamp, replacing: true)
            }
            report.skipped.append(.init(path: path, message: "differs on the two sides; ordered when the vault is unlocked"))
            return record
        }
        let local = classifySummary(localData, device: device, vault: v)
        let remoteCopy = classifySummary(got.data, device: device, vault: v)
        // Never replace a copy sealed under a later epoch than this device's key, up to the epoch its vault.json
        // names: it holds no key for it (a removed or lagging device would otherwise put its stale copy back on
        // every run). Recorded, so it is not fetched again until one side changes.
        if case .laterEpoch = remoteCopy {
            report.skipped.append(.init(path: path, message: "the remote copy is sealed under a later epoch's key; left as it is"))
            return .init(hash: localHash, stamp: stamp)
        }
        // Signed by its device at a time more than the window ahead of this device's clock (offline audit P1): that
        // device's clock runs ahead, or this one's behind. Never replaced by an older copy (which would put it back
        // on every run, on both sides); read once this clock reaches it.
        if case .ahead(let r) = remoteCopy {
            noteClockAhead(device, version: r)
            if own, !options.pushOnly, case .ordered = local,
               let resealed = try resealOwnDeviceSummary(name, localData, device: device, vault: v, above: r) {
                // This device's own entries, sealed again above its own later copy: they travel, and no side goes back.
                return try putDeviceSummary(name, resealed.data, hash: resealed.hash, condition: condition)
            }
            report.skipped.append(.init(path: path, message: "the remote copy is signed at a time more than 7 days ahead "
                + "of this device's clock (its clock or this one's is wrong); left as it is"))
            return .init(hash: localHash, stamp: stamp, recheckAfter: Self.entersWindow(r))
        }
        if case .ahead(let l) = local {
            noteClockAhead(device, version: l)
            // This device's own copy, written while its clock ran ahead: still its latest, so it goes up.
            if own { return try putDeviceSummary(name, localData, hash: localHash, condition: condition) }
            // Another device's copy ahead of this clock: neither side is replaced until this clock reaches it.
            report.skipped.append(.init(path: path, message: "this device's copy is signed at a time more than 7 days "
                + "ahead of its clock; neither copy is replaced until the clock reaches it"))
            return .init(hash: localHash, stamp: stamp, recheckAfter: Self.entersWindow(l))
        }
        let later = Self.laterSummary(local: (local.version, localHash), remote: (remoteCopy.version, remoteHash))
        if own {
            // The device's own file replaces any other copy, except one ordered after it, which only this
            // device's signing keys can have made: another install with its keys (a copied state folder). That
            // one is left, and no side rewrites above it at once, so the runs go quiet; the device's next
            // write travels. Once that copy's version is more than the window in the past, the device seals its
            // own entries again at the clock and puts them (at most once per window per install, format.md §12.5).
            if later == .remote, let r = remoteCopy.version {
                let expires = Date(timeIntervalSince1970: Double(r) / 1000 + PublishedSummaries.futureWindow)
                if options.now >= expires, !options.pushOnly,
                   let resealed = try resealOwnDeviceSummary(name, localData, device: device, vault: v, above: r) {
                    return try putDeviceSummary(name, resealed.data, hash: resealed.hash, condition: condition)
                }
                report.skipped.append(.init(path: path, message: "the remote holds a later copy of this device's own "
                                            + "file (another install with this device's keys); left until this device writes a later one"))
                return .init(hash: localHash, stamp: stamp, recheckAfter: expires)
            }
            return try putDeviceSummary(name, localData, hash: localHash, condition: condition)
        }
        switch later {
        case .local?:
            return try putDeviceSummary(name, localData, hash: localHash, condition: condition)
        case .remote? where !options.pushOnly:
            return try placeDeviceSummary(name, got.data, stamp: stamp, replacing: true)
        case .remote?:
            // A later copy a push-only run leaves there; the next two-way run takes it.
            return record
        case nil:
            // Neither copy is ordered: each opens but names another device (another device's file put under
            // this name), has no version or one beyond the window, is unsigned or not signed by that device, or
            // does not open and is of this epoch or an earlier one (damaged, cut, stale), or is not a sealed file
            // at all. Recorded, so neither is fetched again until one side changes.
            report.skipped.append(.init(path: path, message: "neither copy opens as this device's file; neither is replaced"))
            return .init(hash: localHash, stamp: stamp)
        }
    }

    /// What one copy of a device's file is to this run.
    enum SummaryCopy {
        /// Opens as the device's file, signed by it, with a version within the window (`openDevicePublishedSummaries`).
        case ordered(Int64)
        /// Not ordered, and replaceable: it opens but names another device, has no version or one too far
        /// ahead, or its signature is missing or does not verify as that device's; or it does not open and its
        /// clear header names this device's epoch or an earlier one (or none: damaged, cut, or not a sealed
        /// file at all).
        case unordered
        /// Does not open, and its clear header names a later epoch than this device's key, no later than the
        /// local vault.json's: never replaced.
        case laterEpoch
        /// Signed by the device under this epoch, at a version more than the window ahead of this device's clock
        /// (offline audit P1): not ordered, and never replaced by an older copy.
        case ahead(Int64)

        var version: Int64? { if case .ordered(let v) = self { return v } else { return nil } }
    }

    func classifySummary(_ data: Data, device: DeviceID, vault v: Vault) -> SummaryCopy {
        guard let contents = try? v.openDevicePublishedSummaries(data, device: device, now: options.now) else {
            // The clear epoch is believed only up to the one the local vault.json names (synced earlier in the
            // run, and taken only as home's later version): anyone who can write to the storage can put any
            // header on bytes that do not open. For a current device that is its key's epoch, so such a copy is
            // repaired; a removed or lagging device leaves copies of the epochs it knows of but has no key for.
            // Or a verified next epoch on the server (`serverChildEpoch`), for a device that learns of a key
            // change only through sync.
            if let ahead = v.devicePublishedSummariesAhead(data, device: device, now: options.now) { return .ahead(ahead) }
            if let epoch = PublishedSummaries.sealedEpoch(data), epoch > v.manifest.epoch,
               epoch <= (localManifestEpoch() ?? 0) || epoch <= (serverChildEpoch(of: v) ?? 0) {
                return .laterEpoch
            }
            return .unordered
        }
        return contents.version.map { .ordered($0) } ?? .unordered
    }

    /// The epoch the server's `vault.json` names when it is a verified child of the epoch this device pinned
    /// (`Vault.epochFrontier`, `EpochFrontier.verifiedChild`: the check KH3's removal notice makes too): what a
    /// device learns of a key change it cannot take until epoch records travel (KH4), e.g. a removed one.
    /// Anything else (an unsigned claim, an epoch further on) is not believed. Read at most once per run; a run
    /// whose download budget cannot take it says so in `skipped`.
    func serverChildEpoch(of v: Vault) -> Int? {
        if let known = remoteChildEpoch { return known }
        var found: Int?
        if let frontier = v.epochFrontier,
           let got = try? transport.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes) {
            let counted: Bool = locked {
                do { try budget.downloaded(got.data.count); return true } catch { return false }
            }
            if !counted {
                report.skipped.append(.init(path: Vault.manifestName, message: "not read to recognize a later epoch of "
                    + "summaries files: the run's download budget is spent; a copy this device cannot open may be replaced"))
            } else if let m = try? EpochManifest.parse(got.data), let child = frontier.verifiedChild(m) {
                found = child.epoch
            }
        }
        remoteChildEpoch = .some(found)
        return found
    }

    /// The epoch the local `vault.json` names (its `epoch` field alone; the file was checked when it was
    /// taken), nil when it is missing or has none.
    func localManifestEpoch() -> Int? {
        struct EpochField: Decodable { var epoch: Int }
        guard let data = try? localMutable(Vault.manifestName) else { return nil }
        return (try? JSONDecoder().decode(EpochField.self, from: data))?.epoch
    }

    /// This device's own file sealed and signed again with the same entries at the next version after `above`
    /// (at least the clock), written locally; nil when its local copy is not ordered, this run may not write,
    /// or the vault was not opened with this device's signing keys.
    private func resealOwnDeviceSummary(_ name: String, _ local: Data, device: DeviceID, vault v: Vault,
                                        above: Int64) throws -> (data: Data, hash: String)? {
        guard !options.dryRun, device == v.writerDevice,
              let contents = try? v.openDevicePublishedSummaries(local, device: device, now: options.now),
              let version = PublishedSummaries.nextVersion(after: max(above, contents.version ?? 0), now: options.now),
              let data = try? v.sealDevicePublishedSummaries(contents.entries, version: version)
        else { return nil }
        let path = "\(PublishedSummaries.deviceFolderName)/\(name)"
        try requireLocalWrite("write \(path)")
        let url = root.appendingPathComponent(PublishedSummaries.deviceFolderName, isDirectory: true).appendingPathComponent(name)
        // Written under the vault's write lock, as the device's own writers do; the upload comes after it
        // is released (no request under the lock).
        var written = false
        try withLocalWriteLock { written = try LocalFS.write(data, to: url, replacing: true) }
        guard written else { return nil }
        return (data, FileDigest.sha256(data))
    }

    enum SummarySide { case local, remote }

    /// When a version more than the window ahead of now comes within it (format.md §12.5).
    static func entersWindow(_ version: Int64) -> Date {
        Date(timeIntervalSince1970: Double(version) / 1000 - PublishedSummaries.futureWindow)
    }

    /// Remembers that `device`'s file is signed at `version`, ahead of this device's clock (`SyncReport.clock`).
    func noteClockAhead(_ device: DeviceID, version: Int64) {
        locked { clockAhead[device.rawValue] = max(clockAhead[device.rawValue] ?? 0, version) }
    }

    /// The side holding the later copy of a device's file (format.md §12.5): the greater version; for
    /// equal versions the greater SHA-256 (hex), so every device decides alike; a copy without a version
    /// (it is not ordered) never wins over one with. Nil when neither has one.
    static func laterSummary(local: (version: Int64?, hash: String), remote: (version: Int64?, hash: String)) -> SummarySide? {
        switch (local.version, remote.version) {
        case (nil, nil): return nil
        case (_?, nil): return .local
        case (nil, _?): return .remote
        case let (l?, r?):
            if l != r { return l > r ? .local : .remote }
            return local.hash > remote.hash ? .local : .remote
        }
    }

    private func fetchDeviceSummary(_ name: String, remote: RemoteEntry) throws -> (data: Data, etag: String?) {
        let folder = PublishedSummaries.deviceFolderName
        if let size = remote.size, size > PublishedSummaries.maxFileBytes {
            throw SyncError.responseTooLarge(path: "\(folder)/\(name)", limit: PublishedSummaries.maxFileBytes)
        }
        let reserved = try locked { try budget.willDownload(remote.size) }
        do {
            let got = try transport.read([folder, name], maxBytes: PublishedSummaries.maxFileBytes)
            try locked { try budget.downloaded(got.data.count, reserved: reserved) }
            return got
        } catch {
            locked { budget.release(reserved) }
            throw error
        }
    }

    private func takeDeviceSummary(_ name: String, remote: RemoteEntry, replacing: Bool) throws -> SyncState.MutableRecord? {
        let got: (data: Data, etag: String?)
        do { got = try fetchDeviceSummary(name, remote: remote) } catch where Self.isUnavailable(error) {
            noteArriving([PublishedSummaries.deviceFolderName, name])
            return nil
        }
        return try placeDeviceSummary(name, got.data, stamp: got.etag ?? remote.stamp, replacing: replacing)
    }

    /// Writes a received file locally once it looks like one (and, unlocked, opens).
    private func placeDeviceSummary(_ name: String, _ data: Data, stamp: String?, replacing: Bool) throws -> SyncState.MutableRecord? {
        let folder = PublishedSummaries.deviceFolderName
        let path = "\(folder)/\(name)"
        guard PublishedSummaries.looksSealed(data) else {
            report.skipped.append(.init(path: path, message: "not a sealed summaries file; not placed"))
            return nil
        }
        if let v = checker(), v.canRead, let device = PublishedSummaries.device(ofFileName: name) {
            do { _ = try v.openDevicePublishedSummaries(data, device: device, now: options.now) } catch {
                report.skipped.append(.init(path: path, message: "does not open as that device's signed file under the vault's key; not placed"))
                return nil
            }
        }
        try requireLocalWrite("write \(path)")
        report.downloaded.append(path)
        guard !options.dryRun else { return nil }
        let url = root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name)
        guard try LocalFS.write(data, to: url, replacing: replacing) else { return nil }
        return .init(hash: FileDigest.sha256(data), stamp: stamp)
    }

    private func putDeviceSummary(_ name: String, _ data: Data, hash: String, condition: PutCondition) throws -> SyncState.MutableRecord? {
        let folder = PublishedSummaries.deviceFolderName
        let path = "\(folder)/\(name)"
        report.uploaded.append(path)
        guard !options.dryRun else { return nil }
        try ensureCollection([folder])
        guard try transport.write([folder, name], .data(data), condition: condition) else {
            // Changed or created there meanwhile: compared again next run.
            report.uploaded.removeAll { $0 == path }
            return nil
        }
        let stamp = (try? transport.stat([folder, name]))??.stamp
        return .init(hash: hash, stamp: stamp)
    }
}
