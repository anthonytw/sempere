import Foundation
import Sempere

// MARK: - Per-device published summaries (format.md §12.5, design §5.1)
//
// `summaries/<device>.sealed` is written only by its device, so the remote
// never holds two versions of one to reconcile. A run:
//
// - this device's own file (`SyncOptions.deviceID`): the local copy is the
//   truth; it replaces the remote one whenever they differ, and is never taken
//   from the remote (another device or a restore cannot overwrite it here);
// - every other device's file: copied to the side that lacks it, and when
//   both hold one that differs, the later version wins: the `version` its
//   writer put inside the sealed content, read only after the file opened and
//   named that device (an older copy never replaces a newer one, and a device
//   with two targets carries the newer one from one to the other). Equal
//   versions with different bytes (two copies no honest writer makes) go to
//   the greater SHA-256, so every device picks the same one. A copy that has
//   no version or does not open never replaces one that does. Locked, nothing
//   can be ordered: a differing copy is left on both sides for an unlocked run.
//
// "The side that changed since the last run wins", the rule before, has no
// order between versions: with C syncing only R0 and A and B bridging R0 and
// R1, two of C's versions circled R0 → B → R1 → A → R0 for ever, and only R0
// was ever put right by C (NDeviceStressTests seeds 41 and 46,
// `testTwoBridgesSettleAnotherDevicesSummaries`).
//
// Its own file is the device's truth, but when the remote holds a copy of it
// with the same or a later version (a forged one, or one written before this
// device lost its file and its clock went back), a two-way run first writes its
// own again one version above it, so its latest is ordered above every copy
// and no other device can pin an older one there.
//
// Files are hints (§12.3): a received one must start like a sealed file and,
// with the vault unlocked, open under the vault's secret and name its device,
// or it is not placed (and is not quarantined: a file sealed under an earlier
// secret is expected after a key change, and is only stale). Nothing is ever
// deleted. Push-only runs only upload, and never replace a later version.

extension SyncEngine {
    static let sealedMagic = Data("SMPU".utf8) + Data([1])

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
        if let record, record.stamp != nil, record.stamp == remote.stamp, record.hash == localHash { return record }
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
            // Locked: no version can be read. The own file is still this device's truth.
            if own { return try putDeviceSummary(name, localData, hash: localHash, condition: condition) }
            report.skipped.append(.init(path: path, message: "differs on the two sides; ordered when the vault is unlocked"))
            return record
        }
        let localVersion = (try? v.openDevicePublishedSummaries(localData, device: device))?.version
        let remoteVersion = (try? v.openDevicePublishedSummaries(got.data, device: device))?.version
        if own {
            if let r = remoteVersion, let l = localVersion, r >= l, !options.pushOnly,
               let bumped = try rewriteOwnDeviceSummary(name, localData, device: device, above: r) {
                return try putDeviceSummary(name, bumped.data, hash: bumped.hash, condition: condition)
            }
            return try putDeviceSummary(name, localData, hash: localHash, condition: condition)
        }
        switch Self.laterSummary(local: (localVersion, localHash), remote: (remoteVersion, remoteHash)) {
        case .local?:
            return try putDeviceSummary(name, localData, hash: localHash, condition: condition)
        case .remote? where !options.pushOnly:
            return try placeDeviceSummary(name, got.data, stamp: stamp, replacing: true)
        case .remote?:
            // A later copy a push-only run leaves there; the next two-way run takes it.
            return record
        case nil:
            // Neither copy opens as this device's file: recorded, so neither is fetched again until one side changes.
            report.skipped.append(.init(path: path, message: "neither copy opens as this device's file; neither is replaced"))
            return .init(hash: localHash, stamp: stamp)
        }
    }

    enum SummarySide { case local, remote }

    /// The side holding the later copy of another device's file (format.md §12.5): the greater version; for
    /// equal versions the greater SHA-256 (hex), so every device decides alike; a copy without a version
    /// (it does not open as that device's file) never wins over one with. Nil when neither has one.
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

    /// Writes this device's own file again, the same entries one version above `above` (the remote's copy
    /// has that version or a later one than ours). Nil when it cannot (locked, read-only, or no version is left).
    private func rewriteOwnDeviceSummary(_ name: String, _ local: Data, device: DeviceID,
                                         above: Int64) throws -> (data: Data, hash: String)? {
        guard !options.dryRun, let v = checker(), v.canRead, above < PublishedSummaries.maxVersion,
              var contents = try? v.openDevicePublishedSummaries(local, device: device) else { return nil }
        contents.version = above + 1
        let data = try v.sealPublishedSummaries(contents)
        let path = "\(PublishedSummaries.deviceFolderName)/\(name)"
        try requireLocalWrite("write \(path)")
        let url = root.appendingPathComponent(PublishedSummaries.deviceFolderName, isDirectory: true).appendingPathComponent(name)
        guard try LocalFS.write(data, to: url, replacing: true) else { return nil }
        return (data, FileDigest.sha256(data))
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
        guard data.starts(with: Self.sealedMagic) else {
            report.skipped.append(.init(path: path, message: "not a sealed summaries file; not placed"))
            return nil
        }
        if let v = checker(), v.canRead, let device = PublishedSummaries.device(ofFileName: name) {
            do { _ = try v.openDevicePublishedSummaries(data, device: device) } catch {
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
