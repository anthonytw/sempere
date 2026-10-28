import Foundation
import Sempere

// MARK: - Large uploads after everything else (offline audit P3)
//
// A blob upload cannot resume: a PUT cut short keeps nothing (`BlobSync.swift`). Uploads used to go note by note, so
// one large attachment early in the order, on a link that lasts less than its upload, failed every run and took the
// rest of each window with it: nothing behind it ever went up. Now:
//
// - **Large blobs go last.** A blob larger than `largeBlobBytes` (or as large as one a window recently cut short) is
//   not uploaded with its note. The run first does everything else: every note's revisions and small blobs, in the
//   order of the note loop (the inbox and this device's summaries before the notes, notes with local changes newest
//   first, offline audit P6), the downloads, the deletions, the records. Then `uploadLargeBlobs` sends the large ones,
//   smallest first and one at a time, each note's new revisions once all of its large blobs are up (format.md §8.1.4
//   step 4: a revision never reaches a target before a blob it may reference). Until then the note's new revisions
//   stay local (`largeWaiting`), without an error: other notes do not wait for them.
// - **One a window cut short waits for a longer run.** When a window cut a large upload short (the link dropped,
//   the run's time ran out or it was cancelled), the record keeps its size (`SyncState.LargeUploadRecord.cutAt`).
//   Later runs leave blobs that large or larger (`SyncReport.deferred`), so a short window does not spend itself on an
//   upload it cannot finish. They are tried again by a run told to (`SyncOptions.largeBlobs == .now`: a background
//   processing task, Sync Now, the CLI's `--large-blobs now`), and by the run after `largeRetryAfter` runs in a row
//   that left one (the link may have improved). A larger blob that goes through clears the record. So a large blob
//   never waits for ever, and never holds anything else back.
//
// Chunked or resumable uploads (where a server offers them) would let a large blob progress across short windows;
// WebDAV has no standard for them, so that is left for a transport that has one.

extension SyncEngine {
    /// Blobs larger than this go after every other file of the run (1 MiB).
    static let largeBlobBytes = 1 << 20
    /// A cut upload smaller than this says nothing about the window (it may simply have been the one in flight).
    static let largeCutFloor = 64 << 10
    /// After this many runs in a row that left a large blob for a longer run, a run tries them anyway.
    static let largeRetryAfter = 6

    /// How long a cut upload is evidence about this target's windows (offline review of #97, S2): the link changes.
    static let largeCutLifetime: TimeInterval = 24 * 3600

    /// Before the notes, once per run: from what recent runs learned, which blobs go last and from which size this
    /// run leaves one for a longer run. Read once, so a cut during this run changes nothing until the next (review
    /// of #97, S4). A cut older than `largeCutLifetime` (or dated ahead of this clock, or undated) is forgotten.
    func prepareLargeUploads() {
        var record = state.largeUploads
        if var r = record, r.cutAt != nil {
            let fresh = r.cutWhen.map { at in
                options.now.timeIntervalSince(at) < Self.largeCutLifetime && at.timeIntervalSince(options.now) < 3600
            } ?? false
            if !fresh {
                r.cutAt = nil
                r.cutWhen = nil
                record = r
                if !options.dryRun { state.largeUploads = r.deferredRuns == 0 ? nil : r }
            }
        }
        largeTailFrom = record?.cutAt
        largeForcedTurn = options.largeBlobs == .auto && (record?.deferredRuns ?? 0) >= Self.largeRetryAfter
        // Only blobs of `largeBlobBytes` or more are ever left for a longer run; smaller ones a cut reached go last.
        largeDeferFrom = options.largeBlobs == .now || largeForcedTurn ? nil : record?.cutAt.map { max($0, Self.largeBlobBytes) }
    }

    /// Whether a blob of `size` bytes is uploaded after every other file (`uploadLargeBlobs`).
    func isLargeUpload(_ size: Int) -> Bool {
        size > Self.largeBlobBytes || largeTailFrom.map { size >= $0 } == true
    }

    /// Notes `name` (`size` bytes) of note `id` as a large upload: it and the note's new revisions wait for the
    /// large-blob pass.
    func holdForLargeUpload(_ id: String, _ name: String, size: Int) {
        locked {
            largeBlobsByNote[id, default: [:]][name] = size
            _ = largeWaiting.insert(id)
        }
    }

    /// Whether note `id`'s new revisions wait for a large blob of theirs this run.
    func waitsForLargeUpload(_ id: String) -> Bool { locked { largeWaiting.contains(id) } }

    /// A large upload of `size` bytes was cut short by the window (`error`, from the request itself): remembered, so
    /// later runs leave blobs that large for a longer one. A request that never reached the server (no network, no
    /// route, refused: `TransientRemoteError.sentNothing`) says nothing about the window, only about the link.
    func noteUploadCut(size: Int, error: Error) {
        guard size >= Self.largeCutFloor, !options.dryRun else { return }
        let cut: Bool
        if (error as? any TransientRemoteError)?.sentNothing == true {
            cut = false
        } else if LinkBreaker.isNetworkFailure(error) {
            cut = true
        } else if let e = error as? SyncError, e.isRunLimit {
            // The run's time bound or a cancellation mid-request; never a link the breaker already gave up on (the
            // request was not even made).
            if case .connectionLost = e { cut = false } else { cut = true }
        } else {
            cut = false
        }
        guard cut else { return }
        locked {
            var record = state.largeUploads ?? .init()
            record.cutAt = min(record.cutAt ?? Int.max, size)
            record.cutWhen = options.now
            state.largeUploads = record
            largeCutThisRun = true
        }
    }

    /// A blob upload of `size` bytes went through: a cut at that size or below is no longer evidence.
    func noteUploadDone(size: Int) {
        guard !options.dryRun else { return }
        locked {
            guard var record = state.largeUploads, let at = record.cutAt, size >= at else { return }
            record.cutAt = nil
            record.cutWhen = nil
            state.largeUploads = record.deferredRuns == 0 ? nil : record
        }
    }

    /// After the notes: the large blobs, smallest first, one at a time, each note's new revisions once all of its
    /// large blobs are up. A blob this run leaves (`largeDeferFrom`) is reported in `deferred`, its note's revisions
    /// still wait. Throws only what stops the run.
    func uploadLargeBlobs() throws {
        let byNote = locked { largeBlobsByNote }
        defer { largePassDone = true }
        guard !byNote.isEmpty else { return }
        let order = byNote.map { (id: $0.key, largest: $0.value.values.max() ?? 0) }
            .sorted { ($0.largest, $0.id) < ($1.largest, $1.id) }
        for (id, _) in order {
            var ready = true
            for (name, size) in (byNote[id] ?? [:]).sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
                if let from = largeDeferFrom, size >= from {
                    report.deferred.append(.init(path: blobPath(id, name), message: "\(Self.mib(size)) MB: an upload of "
                        + "\(Self.mib(from)) MB or more was cut short by a recent connection window; it waits for a longer "
                        + "run, with its note's new revisions"))
                    ready = false
                    continue
                }
                try checkCancelled()
                try budget.checkTime()
                do {
                    try uploadBlob(id, name)
                    // Both sides hold it now, as the note loop records a blob it uploaded (review of #97, S1).
                    if !options.dryRun { locked { state.files[blobKey(id, name)] = SyncState.FileRecord() } }
                } catch {
                    try rethrowRunLimit(error)
                    report.errors.append(.init(path: blobPath(id, name), message: Self.describe(error)))
                    ready = false
                }
            }
            guard ready else { continue }
            locked { _ = largeWaiting.remove(id) }
            // The note's new revisions, now that its blobs are there.
            for n in pendingRevisionUploads(id) {
                try checkCancelled()
                try budget.checkTime()
                do {
                    try upload(id, n)
                    remoteRevisions[id] = ((remoteRevisions[id] ?? []) + [n.filename]).sorted()
                    recordUploaded(revision: key(id, n))
                } catch {
                    try rethrowRunLimit(error)
                    report.errors.append(.init(path: "notes/\(key(id, n))", message: Self.describe(error)))
                }
            }
        }
    }

    /// Records a revision the large-blob pass uploaded as both sides holding it, with the bytes it sent, as the note
    /// loop does (`syncNote`; review of #97, S1): the next run then judges it as shared, never as new.
    func recordUploaded(revision k: String) {
        guard !options.dryRun else { return }
        locked {
            state.files[k] = SyncState.FileRecord(included: nil, sha256: placedShas[k], stamp: nil)
            state.thinned?[k] = nil
            if state.thinned?.isEmpty == true { state.thinned = nil }
        }
    }

    /// Note `id`'s revisions the run would upload as new: local, not on the target as the note loop left it, not
    /// recorded by the last sync (a two-way run judges those apart), not set aside.
    func pendingRevisionUploads(_ id: String) -> [RevisionName] {
        guard let local = localRevisionNames(id) else { return [] }
        let remote = Set(remoteRevisions[id] ?? [])
        let recorded = options.pushOnly ? [] : Set(recordedRevisions(id).union(thinnedRevisions(id)).map(\.filename))
        return local.subtracting(remote).subtracting(recorded).compactMap(RevisionName.init).sorted()
            .filter { !heldAside("notes/\(key(id, $0))") }
    }

    /// At the end of a run: counts the runs in a row that left a large blob (only when the large-blob pass ran).
    /// A forced turn spends the cut it was made for: unless it was cut again, the next runs try large blobs normally.
    func settleLargeUploads() {
        guard !options.dryRun, largePassDone else { return }
        var record = state.largeUploads ?? .init()
        record.deferredRuns = report.deferred.isEmpty ? 0 : record.deferredRuns + 1
        if largeForcedTurn, !locked({ largeCutThisRun }) {
            record.cutAt = nil
            record.cutWhen = nil
        }
        state.largeUploads = record.cutAt == nil && record.deferredRuns == 0 ? nil : record
    }

    /// `bytes` in MB with one decimal, for the report.
    static func mib(_ bytes: Int) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
}

/// How a run treats attachment blobs too large for recent connection windows (`SyncOptions.largeBlobs`).
public enum LargeBlobPolicy: String, Sendable, CaseIterable {
    /// After every other file; one as large as an upload a recent window cut short waits for a longer run.
    case auto
    /// After every other file, every one this run.
    case now
}
