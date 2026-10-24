import Foundation
import Sempere

// MARK: - Concurrent uploads (`SyncOptions.concurrency`)
//
// The note loop goes through the notes one at a time, so a run that uploads
// many files (a first upload, a push after an import) paid one round trip
// after another: a PUT per revision, a PUT and a MOVE per blob. Before the
// note loop, a run now uploads what the note loop would upload as new on
// this side `concurrency` at a time:
//
// - a two-way run: each note's revisions and blobs that the server's listing
//   lacks and the last sync did not record (the table's "upload" row);
// - a push-only run: each note's revisions and blobs the server's listing
//   lacks, whatever the last sync recorded (the server lost them);
//
// a note's blobs first, its revisions once they all finished (format.md
// §8.1.4 step 4), as the note loop orders them; when one of the note's blobs
// failed to upload, its revisions wait for the next run (`blobsHeldBack`). Each upload is the same
// `upload` / `uploadBlob` the note loop calls (`If-None-Match: *`; a blob to
// a temporary name, then `MOVE` with `Overwrite: F`), so nothing on the
// server is ever replaced. What it shares with the run is under `mutex`.
//
// The note loop then runs as before: an upload made here counts as made
// there (the file is on the server, after the note's listing was taken, as
// it would be had the loop made it), one that failed is reported once and
// not tried again in the same run, and everything else (deletions, restores,
// records) is decided there exactly as before. Revisions larger than
// `FetchScope.concurrentRevisionBytes` are read whole to upload, so
// they are left to the note loop, one at a time.
//
// A note whose `att/` listing failed uploads nothing here (the note loop
// transfers no blob for it either), and notes whose server folder could not
// be listed are not touched. Run bounds hold as for the downloads: time and
// cancellation are checked before each upload, a request in flight is cut
// by `SyncRemote.interrupt`, and the first bound reached stops the pool.

extension SyncEngine {
    /// One upload of the pre-upload pass.
    struct PreuploadItem: Sendable {
        var note: String
        /// A blob file name, else nil (then `revision` is set).
        var blob: String?
        var revision: RevisionName?
        /// `blobKey` or `key`.
        var key: String
    }

    /// The uploads the note loop would make for every note, `concurrency` at a time.
    func preuploadNewFiles(_ remoteNotes: [String: [RemoteEntry]], localNotes: [String]) throws {
        var groups: [TransferGroup<PreuploadItem>] = []
        let ids = Set(remoteNotes.keys).union(localNotes).subtracting(notesNotReadable)
        for id in ids.sorted() {
            guard let local = localRevisionNames(id) else { continue }
            let entries = remoteNotes[id] ?? []
            var remote = Set<String>()
            var remoteAtt = false
            for e in entries {
                if e.name == Vault.attachmentsName && e.isCollection { remoteAtt = true; continue }
                if !e.isCollection, let n = RevisionName(e.name), n.filename == e.name { remote.insert(e.name) }
            }
            // Revisions thinned here before are judged by the note loop (`syncNote`), never sent ahead.
            let recorded = Set(recordedRevisions(id).union(thinnedRevisions(id)).map(\.filename))
            let dir = root.appendingPathComponent(Vault.notesName).appendingPathComponent(id)
            let revisions = local.subtracting(remote).subtracting(options.pushOnly ? [] : recorded)
                .compactMap(RevisionName.init).sorted()
                .filter { !heldAside("notes/\(key(id, $0))") }
                .filter { n in
                    // Read whole to upload: only small ones here, so memory stays bounded.
                    guard let size = LocalFS.regularFileSize(dir.appendingPathComponent(n.filename)) else { return false }
                    return size <= FetchScope.concurrentRevisionBytes
                }
                .map { PreuploadItem(note: id, blob: nil, revision: $0, key: key(id, $0)) }
            var blobs: [PreuploadItem] = []
            if let names = preuploadBlobNames(id, remoteAtt: remoteAtt)?.filter({ !heldAside("notes/\(blobKey(id, $0))") }) {
                blobs = names.map { PreuploadItem(note: id, blob: $0, revision: nil, key: blobKey(id, $0)) }
            }
            guard !blobs.isEmpty || !revisions.isEmpty else { continue }
            groups.append(TransferGroup(first: blobs, then: revisions))
        }
        guard !groups.isEmpty else { return }
        updateProgress { $0.stage = .syncingNotes }
        let marks = (uploaded: report.uploaded.count, errors: report.errors.count)
        // The order the note loop would have uploaded them in (notes in order, each note's blobs first).
        var position: [String: Int] = [:]
        for item in groups.flatMap({ $0.first + $0.then }) { position["notes/\(item.key)"] = position.count }
        defer {
            // Completion order depends on the threads: keep reports reproducible, in the one-at-a-time order.
            report.uploaded[marks.uploaded...].sort { (position[$0] ?? Int.max, $0) < (position[$1] ?? Int.max, $1) }
            report.errors[marks.errors...].sort { $0.path < $1.path }
            for issue in report.errors[marks.errors...] {
                let parts = issue.path.split(separator: "/")
                if parts.count > 1, parts[0] == Vault.notesName { prefetchTroubled.insert(String(parts[1])) }
            }
        }
        let me = UncheckedSendable(self)
        try pool.run(groups) { item in try me.value.preupload(item) }
    }

    /// The blobs of a note the note loop would upload as new on this side, in
    /// its order (`syncBlobTransfers`); nil when it would upload none or
    /// cannot tell (the server's `att/` listing failed).
    private func preuploadBlobNames(_ id: String, remoteAtt: Bool) -> [String]? {
        var remote = Set<String>()
        if remoteAtt {
            switch attListings[id] {
            case .success(let listed)?:
                for e in listed ?? [] where !e.isCollection { remote.insert(e.name) }
            case .failure?, nil:
                return nil
            }
        }
        let att = attURL(id)
        guard let names = localBlobNames(id) else { return nil }
        var local: [String: Int] = [:]
        for name in names {
            if let size = LocalFS.regularFileSize(att.appendingPathComponent(name)) { local[name] = size }
        }
        let recorded = options.pushOnly ? [] : recordedBlobs(id)
        var new = Set(local.keys).subtracting(remote).subtracting(recorded)
        // A superseded old name is never uploaded (KH6).
        new.subtract(supersededNames(id, new, present: Set(local.keys).union(remote)).keys)
        guard !new.isEmpty else { return nil }
        return new.sorted {
            (Self.priority($0), local[$0] ?? 0, $0) < (Self.priority($1), local[$1] ?? 0, $1)
        }
    }

    /// One upload of the pass: made (and recorded in `preuploaded`) or
    /// reported. Throws only what stops the run.
    private func preupload(_ item: PreuploadItem) throws {
        try checkCancelled()
        try locked { try budget.checkTime() }
        locked { _ = preuploadTried.insert(item.key) }
        do {
            if let blob = item.blob {
                try uploadBlob(item.note, blob)
            } else if let n = item.revision {
                try upload(item.note, n)
            }
            locked { _ = preuploaded[item.note, default: []].insert(item.key) }
        } catch {
            try rethrowRunLimit(error)
            locked { report.errors.append(.init(path: "notes/\(item.key)", message: Self.describe(error))) }
        }
    }

    /// Whether the pre-upload pass made the upload `key` (the note loop
    /// counts it as made), tried it and failed (the note loop leaves it), or
    /// did not try it (the note loop makes it).
    enum PreuploadOutcome { case uploaded, failed, notTried }

    func preuploadOutcome(_ note: String, _ key: String) -> PreuploadOutcome {
        locked {
            if preuploaded[note]?.contains(key) == true { return .uploaded }
            return preuploadTried.contains(key) ? .failed : .notTried
        }
    }
}
