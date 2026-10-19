import Foundation
import Sempere

// MARK: - Concurrent listings and downloads (`SyncOptions.concurrency`)
//
// A run used to make one request at a time, so on a high-latency link the
// round trips dominated: a first download of ~800 files paid ~2 000 of them
// (a PROPFIND per note folder and per `att/`, a GET per file). Now:
//
// 1. the note folders, then their `att/`, are listed `concurrency` at a time;
// 2. a two-way run downloads every file the vault lacks and the last sync did
//    not record (the note loop's "new on the server") `concurrency` at a
//    time, before the note loop: a note's blobs first, its revisions once
//    they all finished (format.md §8.1.4 step 4). Each download is the same
//    `download` / `downloadBlob` the note loop calls, with every check,
//    quarantine and resume, under `mutex` wherever it touches the run's state;
// 3. the note loop then runs as before, one note at a time: what the
//    prefetch placed is local by then, what it tried and failed (reported
//    once) is not tried again this run.
//
// Run bounds hold across threads: listed sizes are reserved before each
// download (`RunBudget.willDownload`), and the first bound reached (or a
// cancellation) stops the pool: no new transfer starts, the running ones
// finish, and the run stops early as it would one at a time. Reports are
// sorted by path where the prefetch added to them, so a run's report does
// not depend on thread timing.

extension SyncEngine {
    /// One download of the prefetch.
    struct PrefetchItem: Sendable {
        var note: String
        /// A blob file name, else nil (then `revision` is set).
        var blob: String?
        var revision: RevisionName?
        var entry: RemoteEntry
        /// `blobKey` or `key`.
        var key: String
        /// The path reports use (`notes/…`).
        var path: String
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }

    var pool: TransferPool { TransferPool(width: options.concurrency) }

    /// Throws `SyncError.cancelled` once `options.isCancelled` says so.
    func checkCancelled() throws {
        if options.isCancelled?() == true { throw SyncError.cancelled }
    }

    /// Changes `progress` and hands it to `options.progress`.
    func updateProgress(_ change: (inout SyncProgress) -> Void) {
        locked {
            change(&progress)
            options.progress?(progress)
        }
    }

    /// Counts `bytes` received for the prefetched download `key` (no-op for
    /// any other). A file with a listed size never counts more than that
    /// size, so a download that starts over (a 416, or a 200 to a resumed
    /// request: the server ignored `Range`) never pushes `bytesDone` past
    /// `bytesTotal`; one without a listed size adds what arrives to both.
    func credit(_ key: String, _ bytes: Int) {
        guard bytes > 0 else { return }
        locked {
            guard let had = credited[key] else { return }
            var added = Int64(bytes)
            if let cap = creditCap[key] {
                added = max(0, min(added, cap - had))
            } else {
                progress.bytesTotal += added
            }
            guard added > 0 else { return }
            credited[key] = had + added
            progress.bytesDone += added
            options.progress?(progress)
        }
    }

    /// Starts counting the download `key` towards `progress` (`credit`
    /// adds what arrives, capped at `size` when it is listed).
    func beginCounted(_ key: String, size: Int?) {
        locked {
            credited[key] = 0
            if let size { creditCap[key] = Int64(max(size, 0)) }
        }
    }

    /// Ends counting `key`. Counts only go up: what arrived stays counted
    /// whatever happens. A file counts as done only once it is placed (then
    /// with its whole listed size); one that failed, was quarantined, or was
    /// cut short by a cancellation or a run bound is not done, so the bar
    /// never claims it.
    func endCounted(_ key: String, placed: Bool) {
        locked {
            let got = credited.removeValue(forKey: key) ?? 0
            let cap = creditCap.removeValue(forKey: key)
            if placed {
                if let cap { progress.bytesDone += max(0, cap - got) }
                progress.filesDone += 1
            }
            options.progress?(progress)
        }
    }

    // MARK: Listings

    /// Lists each of `paths` (PROPFIND, Depth 1), `concurrency` at a time,
    /// each counted against the run's bounds. A listing that fails is its
    /// result (`.failure`); a run bound or a cancellation stops them all and
    /// is thrown. `notes`: each counts as a note folder listed.
    func listConcurrently(_ paths: [[String]], notes: Bool) throws -> [Result<[RemoteEntry]?, Error>] {
        let slots = Slots<Result<[RemoteEntry]?, Error>>(count: paths.count)
        let me = UncheckedSendable(self)
        try pool.run(Array(paths.indices)) { i in
            let sync = me.value
            try sync.checkCancelled()
            try sync.locked { try sync.budget.checkTime() }
            let result: Result<[RemoteEntry]?, Error>
            do {
                let entries = try sync.transport.list(paths[i])
                try sync.locked { try sync.budget.list(entries?.count ?? 0) }
                result = .success(entries)
            } catch {
                try rethrowRunLimit(error)
                result = .failure(error)
            }
            sync.locked { slots.values[i] = result }
            if notes { sync.updateProgress { $0.notesListed += 1 } }
        }
        return slots.values.map { $0 ?? .success(nil) }
    }

    /// Lists the server's `att/` of every note that has one (`attListings`;
    /// `syncBlobTransfers` takes them from there).
    func listAttachments(_ remoteNotes: [String: [RemoteEntry]]) throws {
        let ids = remoteNotes.keys.sorted().filter { id in
            // Taken from the tree when the run used one (`TreeListing.swift`).
            attListings[id] == nil && !notesNotReadable.contains(id)
                && (remoteNotes[id] ?? []).contains { $0.name == Vault.attachmentsName && $0.isCollection }
        }
        let results = try listConcurrently(ids.map { [Vault.notesName, $0, Vault.attachmentsName] }, notes: false)
        for (id, result) in zip(ids, results) { attListings[id] = result }
    }

    // MARK: Downloads

    /// Downloads, `concurrency` at a time, what the note loop would download
    /// as new on the server: each note's revisions and blobs that neither the
    /// vault holds nor the last sync recorded.
    func prefetchDownloads(_ remoteNotes: [String: [RemoteEntry]]) throws {
        var groups: [TransferGroup<PrefetchItem>] = []
        var files = 0
        var bytes: Int64 = 0
        for id in remoteNotes.keys.sorted() where !notesNotReadable.contains(id) {
            // A note whose local folder cannot be listed is left to the note loop, which reports it.
            guard let local = localRevisionNames(id) else { continue }
            let recorded = recordedRevisions(id)
            let revisions = (remoteNotes[id] ?? []).compactMap { e -> (RevisionName, RemoteEntry)? in
                guard !e.isCollection, let n = RevisionName(e.name), n.filename == e.name,
                      !local.contains(e.name), !recorded.contains(n) else { return nil }
                return (n, e)
            }.sorted { $0.0 < $1.0 }.map { n, e in
                PrefetchItem(note: id, blob: nil, revision: n, entry: e, key: key(id, n), path: "notes/\(key(id, n))")
            }
            var blobs: [PrefetchItem] = []
            if case .success(let listed?)? = attListings[id], let localBlobs = localBlobNames(id) {
                let recordedBlobs = recordedBlobs(id)
                blobs = listed.filter { e in
                    !e.isCollection && !e.name.hasPrefix(FileIO.tempPrefix) && Self.isBlobName(e.name)
                        && !localBlobs.contains(e.name) && !recordedBlobs.contains(e.name)
                }.sorted {
                    (Self.priority($0.name), $0.size ?? Int.max, $0.name) < (Self.priority($1.name), $1.size ?? Int.max, $1.name)
                }.map { e in
                    PrefetchItem(note: id, blob: e.name, revision: nil, entry: e, key: blobKey(id, e.name), path: blobPath(id, e.name))
                }
            }
            guard !blobs.isEmpty || !revisions.isEmpty else { continue }
            groups.append(TransferGroup(first: blobs, then: revisions))
            for item in blobs + revisions {
                files += 1
                bytes += Int64(max(item.entry.size ?? 0, 0))
            }
        }
        guard files > 0 else { return }
        updateProgress {
            $0.stage = .downloading
            $0.filesTotal += files
            $0.bytesTotal += bytes
        }
        let marks = (downloaded: report.downloaded.count, errors: report.errors.count, skipped: report.skipped.count,
                     quarantined: report.quarantined.count)
        defer {
            // Completion order depends on the threads: keep reports reproducible.
            report.downloaded[marks.downloaded...].sort()
            report.errors[marks.errors...].sort { $0.path < $1.path }
            report.skipped[marks.skipped...].sort { $0.path < $1.path }
            report.quarantined[marks.quarantined...].sort { $0.path < $1.path }
            for issue in report.errors[marks.errors...] + report.skipped[marks.skipped...] + report.quarantined[marks.quarantined...] {
                let parts = issue.path.split(separator: "/")
                if parts.count > 1, parts[0] == Vault.notesName { prefetchTroubled.insert(String(parts[1])) }
            }
        }
        let me = UncheckedSendable(self)
        try pool.run(groups) { item in try me.value.prefetch(item) }
    }

    /// One prefetched download: placed, quarantined, skipped or reported, as
    /// in the note loop. Throws only what stops the run.
    private func prefetch(_ item: PrefetchItem) throws {
        try checkCancelled()
        locked { prefetched.insert(item.key) }
        beginCounted(item.key, size: item.entry.size)
        var placed = false
        defer { endCounted(item.key, placed: placed) }
        do {
            if let blob = item.blob {
                placed = try downloadBlob(item.note, blob, entry: item.entry) != nil
            } else if let n = item.revision {
                placed = try download(item.note, n, entry: item.entry)
            }
        } catch {
            try rethrowRunLimit(error)
            locked { report.errors.append(.init(path: item.path, message: Self.describe(error))) }
        }
    }
}

/// Results of concurrent work, one slot per item; accessed under the owner's lock.
final class Slots<Value>: @unchecked Sendable {
    var values: [Value?]
    init(count: Int) { values = Array(repeating: nil, count: count) }
}
