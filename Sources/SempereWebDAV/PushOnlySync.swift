import Foundation
import Sempere

// MARK: - Push-only mirror (`sempere sync webdav --push-only`)
//
// The local vault is the only source of truth; the server is a copy that is
// not trusted to write back. A two-way sync rejects a vault.json whose
// recipients changed without a valid tag (format.md §2.1) but takes everything
// else the server holds; a push-only run can see a corrupted server but never
// takes anything from it:
//
// - nothing is downloaded, and nothing in the vault folder is written,
//   replaced or deleted (`requireLocalWrite` backs this up in every local
//   write path; only the sync-state file outside the vault changes);
// - `vault.json` and `rewrap-journal.json` on the server are overwritten
//   from the local copy when they differ (reported in `overwritten`), unless
//   `keepServerChanges` is set and the server copy changed since this device's
//   last sync: then it is kept and reported as a conflict;
// - a file the server lacks is uploaded, even one the last sync had (the
//   server lost it);
// - a file only the server has is deleted there if and only if a local
//   compaction or `blobs gc` explains it (as for two-way sync: it was
//   synced before and `CompactionPlanner` / format.md §8.1.6 allow it);
// - one that was synced before but is not explained (the local copy may
//   merely be evicted from iCloud) is kept and listed in `skipped`;
// - one that was never synced (injected by the server, or from another
//   writer) is `extraneous`: reported, and removed only with `deleteExtraneous`
//   and only when an earlier sync's state exists (on a first run every server
//   file looks never synced, including the notes a local listing missed).

extension WebDAVSync {
    /// A path component that is safe to send in a DELETE (a name chosen by the server).
    private static func safeComponent(_ c: String) -> Bool {
        !c.isEmpty && c != "." && c != ".." && !c.contains("/") && !c.contains("\0")
    }

    // MARK: Mutable files

    func pushMutable(_ name: String, remote: RemoteEntry?) throws {
        let local = try localMutable(name)
        guard let local else {
            guard remote != nil else { return }
            // Nothing is ever pulled; a stale journal also blocks blob collection, so it may go.
            if reportExtraneous(name, remove: [name]) && name == Vault.journalName { remoteJournal = false }
            return
        }
        let localHash = FileDigest.sha256(local)
        guard let remote else {
            if try push(name, local, condition: .create) { try recordMutable(name, hash: localHash) }
            return
        }
        // A server file that cannot be read (too large, malformed) is just different.
        let current = try? client.get([name]).data
        if let current, FileDigest.sha256(current) == localHash {
            state.mutable[name] = .init(hash: localHash, stamp: remote.stamp)
            return
        }
        if options.keepServerChanges {
            // Replace only what this device put there: a copy changed since its last
            // sync was written by someone else (another device's key change, say).
            let record = state.mutable[name]
            guard let record, let current, FileDigest.sha256(current) == record.hash else {
                report.conflicts.append(.init(path: name, remoteCopy: nil, detail: record == nil
                    ? "the server copy differs and this device never synced it; kept on the server"
                    : "the server copy changed since this device's last sync; kept on the server"))
                return
            }
        }
        if try push(name, local, condition: .unconditional) {
            report.overwritten.append(name)
            try recordMutable(name, hash: localHash)
        }
    }

    // MARK: Notes

    func syncNotePushOnly(_ id: String, remoteEntries: [RemoteEntry]?) throws {
        let dir = root.appendingPathComponent(Vault.notesName).appendingPathComponent(id)
        var R = Set<RevisionName>()
        var remoteAtt: RemoteEntry?
        for e in remoteEntries ?? [] {
            if e.name == Vault.attachmentsName && e.isCollection { remoteAtt = e; continue }
            guard !e.isCollection, let n = RevisionName(e.name), n.filename == e.name else {
                report.ignored.append(SyncReport.printable("notes/\(id)/\(e.name)"))
                remoteJunk.append([Vault.notesName, id, e.name])
                continue
            }
            R.insert(n)
        }
        defer { remoteRevisions[id] = R.isEmpty ? nil : R.map(\.filename).sorted() }
        // Blobs first, so a revision never reaches the server before the blobs it references.
        var blobs = try syncBlobTransfers(id, remoteAtt: remoteAtt)
        var L = Set<RevisionName>()
        for f in try LocalFS.entries(dir) {
            if let n = RevisionName(f), n.filename == f { L.insert(n) }
        }
        let prefix = "\(id)/"
        let S = Set(state.files.keys.filter { $0.hasPrefix(prefix) }.compactMap { RevisionName(String($0.dropFirst(prefix.count))) })

        func attempt(_ n: RevisionName, _ body: () throws -> Void) {
            do { try body() } catch {
                report.errors.append(.init(path: "notes/\(key(id, n))", message: Self.describe(error)))
            }
        }

        let serverOnly = R.subtracting(L)
        for n in L.subtracting(R).sorted() { attempt(n) { try upload(id, n); R.insert(n) } }

        var loaded: LoadedNote?
        if let vault, let uuid = UUID(uuidString: id) { loaded = try? vault.loadNote(uuid) }
        let cover = (loaded?.revisions ?? []).filter { R.contains($0.name) }.compactMap(SnapshotCoverage.init)
        let epoch = Date(timeIntervalSince1970: 0)

        for n in serverOnly.sorted() {
            attempt(n) {
                let path = "notes/\(key(id, n))"
                guard S.contains(n) else {   // never synced: not ours
                    if reportExtraneous(path, remove: [Vault.notesName, id, n.filename]) { R.remove(n) }
                    return
                }
                guard loaded != nil else {
                    report.skipped.append(.init(path: path, message: "missing locally; cannot check it against compaction (vault not unlocked), kept on the server"))
                    return
                }
                var snaps = cover
                if n.kind == .snapshot {
                    guard let included = state.files[key(id, n)]?.included else {
                        report.skipped.append(.init(path: path, message: "missing locally; its coverage was never recorded, kept on the server"))
                        return
                    }
                    snaps.append(SnapshotCoverage(name: n, included: included, wall: epoch))
                }
                guard CompactionPlanner.deletable(names: [n], wall: [n: epoch], snapshots: snaps, retention: 0,
                                                  now: options.now).contains(n) else {
                    report.skipped.append(.init(path: path, message: "missing locally and not explained by compaction, kept on the server"))
                    return
                }
                report.deleted.append(.init(side: "remote", path: path))
                if !options.dryRun { try client.delete([Vault.notesName, id, n.filename]) }
                R.remove(n)
            }
        }

        try syncBlobDeletions(id, &blobs, remoteRevisions: R)

        guard !options.dryRun else { return }
        var coverage: [RevisionName: Included] = [:]
        for r in loaded?.revisions ?? [] {
            if case .snapshot(let inc, _) = r.body { coverage[r.name] = inc }
        }
        for n in L.intersection(R) {
            let k = key(id, n)
            state.files[k] = SyncState.FileRecord(included: coverage[n] ?? state.files[k]?.included)
        }
        for n in S where !L.contains(n) && !R.contains(n) { state.files[key(id, n)] = nil }
    }

    // MARK: Extraneous

    /// Lists `path` as extraneous and, with `deleteExtraneous`, removes `remove`
    /// from the server. Returns true when it was (or in a dry run would be) removed.
    @discardableResult
    func reportExtraneous(_ path: String, remove components: [String]) -> Bool {
        report.extraneous.append(SyncReport.printable(path))
        guard options.deleteExtraneous, components.allSatisfy(Self.safeComponent) else { return false }
        guard hadState else {
            // First sync: a note iCloud has not listed locally yet looks like this too.
            report.skipped.append(.init(path: SyncReport.printable(path),
                                        message: "first sync to this server: extraneous files are only listed; run again to remove them"))
            return false
        }
        report.deleted.append(.init(side: "remote", path: SyncReport.printable(path)))
        if !options.dryRun {
            do { try client.delete(components) } catch {
                report.deleted.removeLast()
                report.errors.append(.init(path: SyncReport.printable(path), message: Self.describe(error)))
                return false
            }
        }
        return true
    }

    /// Entries the server holds that are not vault files (`ignored`) are extraneous too.
    func deleteRemoteJunk() {
        for comps in remoteJunk {
            reportExtraneous(comps.joined(separator: "/"), remove: comps)
        }
    }
}
