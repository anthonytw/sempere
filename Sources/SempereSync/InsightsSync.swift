import Foundation
import Sempere

// MARK: - Note insights over sync (format.md §16.6; docs/design/1.2-note-insights.md §3.3, §3.5, D17)
//
// Modelled on `DeviceSummariesSync`, simpler because insights are hints read under the current key only:
//
// - one listing of `insights/` per run, counted against the run's bounds (`SyncLimits`), and every file fetched
//   through the bounded path (a file over its kind's bound is never fetched whole);
// - unlocked runs only, with a `vault.json` that checked and no hold: a locked run, a staging run or a joiner's run
//   skips `insights/` entirely;
// - a copy is taken (placed locally, or put on the target) only when it opens under the CURRENT key; where both sides
//   hold different copies the later `written` wins (then the greater SHA-256), on both sides; a copy that does not open
//   never replaces one that does, and is replaced by it; when neither opens both stay;
// - nothing is pushed unless this device's own `vault.json` stands on the target (`listStandsHere`), so a lagging or
//   removed device never puts old-key files back;
// - deletions: files that open under a key from before a finished re-encryption, files named for a device the vault
//   removed (both locally, and on the target where this device's list stands), and everything when `insights.enabled`
//   is explicitly off. Unset leaves `insights/` alone on both sides;
// - a provider's conflict versions of a file settle to the later `written` (`ConflictVersions`).

extension SyncEngine {
    /// The pass over `insights/` (after the notes, with the other hints).
    func syncInsights(remoteRoot: [String: RemoteEntry]) throws {
        guard !options.dryRun, epochHold == nil, let v = epochJudge, v.canRead, v.listStatus.problem == nil,
              !v.isReadOnly else { return }
        let folder = Vault.insightsName
        let localDir = root.appendingPathComponent(folder, isDirectory: true)
        let mode = v.insightsMode()
        guard mode != .unset else { return }
        if let dir = remoteRoot[folder], dir.isCollection, folderArriving([folder], entry: dir) { return }
        var listed: [String: RemoteEntry] = [:]
        if remoteRoot[folder]?.isCollection == true || collectionKnown([folder]), let entries = try transport.list([folder]) {
            try budget.list(entries.count)
            for e in entries where !e.isCollection && InsightsFileName(e.name) != nil { listed[e.name] = e }
        }
        let stands = listStandsHere(v)
        var local = Set(InsightsStore.names(in: localDir).map(\.fileName))
        // Off: every insights file goes, here and on the target (format.md §16.6), and nothing is synced.
        if mode == .off {
            if !options.pushOnly {
                for name in local.sorted() {
                    try LocalFS.remove(localDir.appendingPathComponent(name))
                    report.deleted.append(.init(side: "local", path: "\(folder)/\(name)"))
                }
            }
            if stands {
                for (name, e) in listed.sorted(by: { $0.key < $1.key }) { try deleteRemoteInsights(name, entry: e) }
            }
            state.insights = nil
            return
        }
        // Files of removed devices (format.md §16.6): never shown, deleted where this device's list stands.
        let removed = v.removedInsightsDevices()
        for name in local.sorted() {
            guard let n = InsightsFileName(name), removed.contains(n.device), !options.pushOnly else { continue }
            try LocalFS.remove(localDir.appendingPathComponent(name))
            local.remove(name)
            report.deleted.append(.init(side: "local", path: "\(folder)/\(name)"))
        }
        if stands {
            for (name, e) in listed.sorted(by: { $0.key < $1.key }) {
                guard let n = InsightsFileName(name), removed.contains(n.device) else { continue }
                if try deleteRemoteInsights(name, entry: e) { listed[name] = nil }
            }
        }
        // Below a finished re-encryption (format.md §16.6): files under a key from before it go.
        if let m = v.recordsObsoleteBelow {
            for name in local.sorted() {
                guard !options.pushOnly, let n = InsightsFileName(name),
                      let data = try? BoundedRead.contents(of: localDir.appendingPathComponent(name), maxBytes: n.kind.maxBytes + 4096),
                      v.insightsUnderEpoch(below: m, data, name: n) else { continue }
                try LocalFS.remove(localDir.appendingPathComponent(name))
                local.remove(name)
                report.deleted.append(.init(side: "local", path: "\(folder)/\(name)"))
            }
        }
        let records = state.insights ?? [:]
        var kept: [String: SyncState.MutableRecord] = [:]
        for name in local.union(listed.keys).sorted() {
            guard let n = InsightsFileName(name), !removed.contains(n.device) else { continue }
            do {
                try checkCancelled()
                try budget.checkTime()
                if let r = try syncInsightsFile(n, localDir: localDir, hasLocal: local.contains(name), remote: listed[name],
                                                record: records[name], vault: v, stands: stands) {
                    kept[name] = r
                }
            } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: "\(folder)/\(name)", message: Self.describe(error)))
                if let r = records[name] { kept[name] = r }
            }
        }
        state.insights = kept.isEmpty ? nil : kept
    }

    /// One file; returns the record of the two sides once they hold the same bytes (or nothing changed).
    private func syncInsightsFile(_ n: InsightsFileName, localDir: URL, hasLocal: Bool, remote: RemoteEntry?,
                                  record: SyncState.MutableRecord?, vault v: Vault, stands: Bool) throws -> SyncState.MutableRecord? {
        let folder = Vault.insightsName
        let name = n.fileName
        let file = localDir.appendingPathComponent(name)
        let max = n.kind.maxBytes + 4096
        let localData = hasLocal ? try? BoundedRead.contents(of: file, maxBytes: max) : nil
        let localHash = localData.map { FileDigest.sha256($0) }
        let localOpens = localData.flatMap { try? v.openInsights($0, name: n) }
        guard let remote else {
            // Only here: up, when it opens under the current key and this device's list stands there.
            guard let localData, let localHash, localOpens != nil, stands else { return nil }
            return try putInsights(n, localData, hash: localHash, condition: .create)
        }
        if try !available([folder, name], entry: remote) { return record }
        if let record, record.stamp != nil, record.stamp == remote.stamp, record.hash == localHash { return record }
        if let size = remote.size, size > max {
            report.skipped.append(.init(path: "\(folder)/\(name)", message: "larger than an insights file may be; not fetched"))
            return record
        }
        var got: (data: Data, etag: String?)
        do { got = try fetchInsights(n, remote: remote) } catch where Self.isUnavailable(error) {
            noteArriving([folder, name])
            return record
        }
        // A provider's conflict versions of this file: the later `written` among them becomes the remote copy.
        if !options.pushOnly, let better = try settleInsightsVersions(n, current: got.data, vault: v, stands: stands) {
            got = (better, nil)
        }
        let remoteHash = FileDigest.sha256(got.data)
        let stamp = got.etag ?? remote.stamp
        if remoteHash == localHash { return .init(hash: remoteHash, stamp: stamp) }
        let remoteOpens = try? v.openInsights(got.data, name: n)
        // Under a key from before a finished re-encryption (an old app's home left it): deleted on the target too.
        if remoteOpens == nil, stands, let m = v.recordsObsoleteBelow, v.insightsUnderEpoch(below: m, got.data, name: n) {
            guard try deleteRemoteInsights(name, entry: remote) else { return record }
            guard let localData, let localHash, localOpens != nil else { return nil }
            return try putInsights(n, localData, hash: localHash, condition: .create)
        }
        let condition = stamp.flatMap { Self.isStrong($0) ? PutCondition.replace(etag: $0) : nil } ?? .unconditional
        switch (localOpens, remoteOpens) {
        case (nil, nil):
            if localData == nil { return nil }
            report.skipped.append(.init(path: "\(folder)/\(name)", message: "neither copy opens under the current key; neither is replaced"))
            return .init(hash: localHash ?? remoteHash, stamp: stamp)
        case (nil, _?):
            return try placeInsights(n, got.data, stamp: stamp, replacing: localData != nil)
        case (_?, nil):
            guard stands, let localData, let localHash else { return record }
            return try putInsights(n, localData, hash: localHash, condition: condition)
        case let (l?, r?):
            guard let localData, let localHash else { return nil }
            let localLater = InsightsCodec.isLater((l.written, localHash), than: (r.written, remoteHash), now: options.now)
            if localLater {
                guard stands else { return record }
                return try putInsights(n, localData, hash: localHash, condition: condition)
            }
            let remoteLater = InsightsCodec.isLater((r.written, remoteHash), than: (l.written, localHash), now: options.now)
            if remoteLater { return try placeInsights(n, got.data, stamp: stamp, replacing: true) }
            report.skipped.append(.init(path: "\(folder)/\(name)", message: "neither copy is ordered (written beyond 7 days ahead); neither is replaced"))
            return .init(hash: localHash, stamp: stamp)
        }
    }

    /// The best of a provider's conflict versions when it is later than `current`, resolving the versions; nil when the
    /// current copy stays (the versions are still resolved: a later copy replaces none of them).
    private func settleInsightsVersions(_ n: InsightsFileName, current: Data, vault v: Vault, stands: Bool) throws -> Data? {
        let path = [Vault.insightsName, n.fileName]
        let versions = transport.conflictVersions(path)
        guard !versions.isEmpty else { return nil }
        var best = current
        var bestKey: (Int64?, String) = ((try? v.openInsights(current, name: n))?.written, FileDigest.sha256(current))
        for version in versions {
            guard let data = try? transport.readVersion(path, version, maxBytes: n.kind.maxBytes + 4096) else { continue }
            let key: (Int64?, String) = ((try? v.openInsights(data, name: n))?.written, FileDigest.sha256(data))
            if key.0 != nil, InsightsCodec.isLater((key.0, key.1), than: (bestKey.0, bestKey.1), now: options.now) {
                best = data; bestKey = key
            }
        }
        if best != current {
            guard stands, try transport.write(path, .data(best), condition: .unconditional) else { return nil }
            report.uploaded.append(path.joined(separator: "/"))
        }
        try transport.resolveConflicts(path, versions)
        report.skipped.append(.init(path: path.joined(separator: "/"), message: "\(versions.count) conflict versions on the "
            + "remote settled to the later written copy"))
        return best == current ? nil : best
    }

    private func fetchInsights(_ n: InsightsFileName, remote: RemoteEntry) throws -> (data: Data, etag: String?) {
        let reserved = try locked { try budget.willDownload(remote.size) }
        do {
            let got = try transport.read([Vault.insightsName, n.fileName], maxBytes: n.kind.maxBytes + 4096)
            try locked { try budget.downloaded(got.data.count, reserved: reserved) }
            return got
        } catch {
            locked { budget.release(reserved) }
            throw error
        }
    }

    /// Places a received copy that opened under the current key.
    private func placeInsights(_ n: InsightsFileName, _ data: Data, stamp: String?, replacing: Bool) throws -> SyncState.MutableRecord? {
        guard !options.pushOnly else { return nil }
        let path = "\(Vault.insightsName)/\(n.fileName)"
        try requireLocalWrite("write \(path)")
        let dir = root.appendingPathComponent(Vault.insightsName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard try LocalFS.write(data, to: dir.appendingPathComponent(n.fileName), replacing: replacing) else { return nil }
        report.downloaded.append(path)
        return .init(hash: FileDigest.sha256(data), stamp: stamp)
    }

    private func putInsights(_ n: InsightsFileName, _ data: Data, hash: String, condition: PutCondition) throws -> SyncState.MutableRecord? {
        let path = "\(Vault.insightsName)/\(n.fileName)"
        try ensureCollection([Vault.insightsName])
        guard try transport.write([Vault.insightsName, n.fileName], .data(data), condition: condition) else { return nil }
        report.uploaded.append(path)
        let stamp = (try? transport.stat([Vault.insightsName, n.fileName]))??.stamp
        return .init(hash: hash, stamp: stamp)
    }

    /// Deletes a target's copy (under its strong version tag when it has one). True when it went.
    @discardableResult
    private func deleteRemoteInsights(_ name: String, entry e: RemoteEntry) throws -> Bool {
        let tag = e.etag.flatMap { Self.isStrong($0) ? $0 : nil }
        guard try transport.delete([Vault.insightsName, name], ifETag: tag) else { return false }
        report.deleted.append(.init(side: "remote", path: "\(Vault.insightsName)/\(name)"))
        return true
    }
}
