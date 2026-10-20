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
// - every other device's file: copied to the side that lacks it, and when both
//   hold one that differs, the side that changed since the last run wins (a
//   device with two targets carries a newer copy from one to the other); if
//   both changed, the remote's (the one its writer's other devices see).
//
// Files are hints (§12.3): a received one must start like a sealed file and,
// with the vault unlocked, open under the vault's secret, or it is not placed
// (and is not quarantined: a file sealed under an earlier secret is expected
// after a key change, and is only stale). Nothing is ever deleted. Push-only
// runs only upload.

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
        if remoteHash == localHash { return .init(hash: localHash, stamp: got.etag ?? remote.stamp) }
        let localChanged = record?.hash != localHash, remoteChanged = record?.hash != remoteHash
        if own || options.pushOnly || (localChanged && !remoteChanged) {
            let stamp = got.etag ?? remote.stamp
            let condition = stamp.flatMap { Self.isStrong($0) ? PutCondition.replace(etag: $0) : nil } ?? .unconditional
            return try putDeviceSummary(name, localData, hash: localHash, condition: condition)
        }
        return try placeDeviceSummary(name, got.data, stamp: got.etag ?? remote.stamp, replacing: true)
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
        if let v = checker(), v.canRead {
            do { _ = try v.openPublishedSummaries(data) } catch {
                report.skipped.append(.init(path: path, message: "does not open under the vault's secret; not placed"))
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
