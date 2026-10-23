import Foundation
import Sempere

// MARK: - Per-device published summaries (format.md §12.5, design §5.1)
//
// `summaries/<device>.sealed` is written only by its device. Each copy carries,
// inside its sealed (authenticated) content, the device it belongs to and a
// `version` its writer raises with every write. A copy is *ordered* when it
// opens under the vault's key, names the device of its file name, and has a
// version at most `PublishedSummaries.futureWindow` (7 days) ahead of this
// device's clock. A run:
//
// - another device's file: copied to the side that lacks it; when both hold
//   one that differs, the later ordered copy wins on both sides (equal
//   versions: the greater SHA-256, so every device picks the same one). An
//   unordered copy never replaces an ordered one.
// - this device's own file (`SyncOptions.deviceID`): the local copy is the
//   truth and replaces the remote one, unless the remote one is ordered after
//   it (another install with this device id, or a copy another key holder
//   forged within the window): that one is left, and neither side rewrites
//   above the other at once, so the runs go quiet; the next later write
//   travels, and once that copy's version is more than the window in the past
//   the device seals its own entries again at the clock and puts them (at most
//   once per window per install). A forged copy can hold another device's file
//   for at most twice the window, and one beyond it (the cap included) never
//   wins. Device signatures over the
//   version would end forgery: TODO(KH4/KH5), once summaries use the vault's
//   device ids and their signing keys.
// - a copy that does not open and whose clear header (`SMPU` `0x02`, bound as
//   associated data) names an epoch above this device's key's, and no later
//   than the one its local vault.json names, is never replaced, own file or
//   not: this device holds no key for it (a removed or lagging device would
//   otherwise put its stale copy back on every run). The header of a copy
//   that does not open is not authenticated, so for a current device (its
//   vault.json names its key's epoch) nothing is believed later: any copy that
//   does not open is damaged, stale or forged, and is replaced like any
//   unordered copy.
// - locked, nothing is ordered: a differing copy is left on both sides, except
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

    func syncDeviceSummaries(remoteRoot: [String: RemoteEntry]) throws {
        let folder = PublishedSummaries.deviceFolderName
        let localDir = root.appendingPathComponent(folder, isDirectory: true)
        let local = Set(try LocalFS.entries(localDir).filter { PublishedSummaries.device(ofFileName: $0) != nil })
        if let dir = remoteRoot[folder], dir.isCollection, folderArriving([folder], entry: dir) { return }
        var listed: [String: RemoteEntry] = [:]
        if remoteRoot[folder]?.isCollection == true, let entries = try transport.list([folder]) {
            try budget.list(entries.count)
            for e in entries where !e.isCollection {
                if PublishedSummaries.device(ofFileName: e.name) != nil {
                    listed[e.name] = e
                } else if !e.name.hasPrefix(".") {
                    report.ignored.append("\(folder)/\(SyncReport.printable(e.name))")
                }
            }
        }
        let records = state.deviceSummaries ?? [:]
        var kept: [String: SyncState.MutableRecord] = [:]
        for name in local.union(listed.keys).sorted() {
            do {
                try checkCancelled()
                if let r = try syncDeviceSummary(name, localDir: localDir, hasLocal: local.contains(name), remote: listed[name],
                                                 record: records[name]) {
                    kept[name] = r
                }
            } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: "\(folder)/\(name)", message: Self.describe(error)))
                if let r = records[name] { kept[name] = r }
            }
        }
        if !options.dryRun { state.deviceSummaries = kept.isEmpty ? nil : kept }
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
        // Unchanged on the remote since the last run (its token) and here (its hash): nothing to do.
        if let record, record.stamp != nil, record.stamp == remote.stamp, record.hash == localHash,
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
        guard let device = PublishedSummaries.device(ofFileName: name), let v = checker(), v.canRead else {
            // Locked: no version can be read. The own file is still this device's truth; a locked staging run
            // (pull-only, `LockedStaging`) stages the remote copy, which the placing run orders under the key.
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
        let later = Self.laterSummary(local: (local.version, localHash), remote: (remoteCopy.version, remoteHash))
        if own {
            // The device's own file replaces any other copy, except one ordered after it: another install with
            // this device id (a copied state folder), or a copy another key holder forged within the window.
            // That one is left, and no side rewrites above it at once, so the runs go quiet; the device's next
            // write travels. Once that copy's version is more than the window in the past, the device seals its
            // own entries again at the clock and puts them (at most once per window per install): a forged copy
            // holds a quiet device's file back for at most twice the window (format.md §12.5).
            if later == .remote, let r = remoteCopy.version {
                let expires = Date(timeIntervalSince1970: Double(r) / 1000 + PublishedSummaries.futureWindow)
                if options.now >= expires, !options.pushOnly,
                   let resealed = try resealOwnDeviceSummary(name, localData, device: device, vault: v, above: r) {
                    return try putDeviceSummary(name, resealed.data, hash: resealed.hash, condition: condition)
                }
                report.skipped.append(.init(path: path, message: "the remote holds a later copy of this device's own "
                                            + "file (another install with this device id, or a forged copy); left until this device writes a later one"))
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
            // this name), has no version or one beyond the window, or does not open and is of this epoch or an
            // earlier one (damaged, cut, stale), or is not a sealed file at all. Recorded, so neither is fetched
            // again until one side changes.
            report.skipped.append(.init(path: path, message: "neither copy opens as this device's file; neither is replaced"))
            return .init(hash: localHash, stamp: stamp)
        }
    }

    /// What one copy of a device's file is to this run.
    enum SummaryCopy {
        /// Opens as the device's file and has a version within the window (`PublishedSummaries.accepted`).
        case ordered(Int64)
        /// Not ordered, and replaceable: it opens but names another device, has no version or one too far
        /// ahead; or it does not open and its clear header names this device's epoch or an earlier one (or
        /// none: damaged, cut, or not a sealed file at all).
        case unordered
        /// Does not open, and its clear header names a later epoch than this device's key, no later than the
        /// local vault.json's: never replaced.
        case laterEpoch

        var version: Int64? { if case .ordered(let v) = self { return v } else { return nil } }
    }

    func classifySummary(_ data: Data, device: DeviceID, vault v: Vault) -> SummaryCopy {
        guard let contents = try? v.openDevicePublishedSummaries(data, device: device, now: options.now) else {
            // The clear epoch is believed only up to the one the local vault.json names (synced earlier in the
            // run, and taken only as home's later version): anyone who can write to the storage can put any
            // header on bytes that do not open. For a current device that is its key's epoch, so such a copy is
            // repaired; a removed or lagging device leaves copies of the epochs it knows of but has no key for.
            if let epoch = PublishedSummaries.sealedEpoch(data), epoch > v.manifest.epoch,
               let known = localManifestEpoch(), epoch <= known {
                return .laterEpoch
            }
            return .unordered
        }
        return contents.version.map { .ordered($0) } ?? .unordered
    }

    /// The epoch the local `vault.json` names (its `epoch` field alone; the file was checked when it was
    /// taken), nil when it is missing or has none.
    func localManifestEpoch() -> Int? {
        struct EpochField: Decodable { var epoch: Int }
        guard let data = try? localMutable(Vault.manifestName) else { return nil }
        return (try? JSONDecoder().decode(EpochField.self, from: data))?.epoch
    }

    /// This device's own file sealed again with the same entries at the next version after `above` (at least
    /// the clock), written locally; nil when its local copy is not ordered or this run may not write.
    private func resealOwnDeviceSummary(_ name: String, _ local: Data, device: DeviceID, vault v: Vault,
                                        above: Int64) throws -> (data: Data, hash: String)? {
        guard !options.dryRun, var contents = try? v.openDevicePublishedSummaries(local, device: device, now: options.now),
              let version = PublishedSummaries.nextVersion(after: max(above, contents.version ?? 0), now: options.now)
        else { return nil }
        contents.version = version
        let data = try v.sealPublishedSummaries(contents)
        let path = "\(PublishedSummaries.deviceFolderName)/\(name)"
        try requireLocalWrite("write \(path)")
        let url = root.appendingPathComponent(PublishedSummaries.deviceFolderName, isDirectory: true).appendingPathComponent(name)
        guard try LocalFS.write(data, to: url, replacing: true) else { return nil }
        return (data, FileDigest.sha256(data))
    }

    enum SummarySide { case local, remote }

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
                report.skipped.append(.init(path: path, message: "does not open as this device's file under the vault's secret; not placed"))
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
