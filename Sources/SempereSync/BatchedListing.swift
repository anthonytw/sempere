import Foundation
import Sempere

// MARK: - Listing note folders in batches, across runs (offline audit P7)
//
// Without a tree (`TreeListing.swift`: deep listing off or refused by the server, more than 5 000 note folders, a
// tree over the 16 MiB listing bound), a run lists every note folder one by one. It used to list them all before any
// transfer, in the same order every run: a window shorter than the listing never moved a file, and the next window
// started over. Where more than `batchListingAbove` folders must be listed that way, a run now goes through the notes
// in batches (`firstListingBatch` notes, doubling up to `largestListingBatch`): each batch's folders are listed, then
// its downloads, uploads and note loop run, then the next batch. The order is the note loop's (the notes with changes
// made here first, newest first; offline audit P6), and the rest, by id, start after the last note an earlier run
// synced (`SyncState.ListingPass.cursor`), so short windows sweep the vault instead of redoing its first notes.
//
// A sweep that reaches the last note (by id) after starting at the first, with every folder listed and none failing,
// counts as a full listing even when it took several runs: `lastFullListing` is set to when it started, so
// `skipUnchangedNotes` (which needs a full listing every `fullListingInterval`) works on short windows too.
//
// Nothing else changes: each note is judged from its own folder's listing, as before; what needs the whole server
// listed (`notesListed`: the web index, the published summaries, `synced`) still waits for a run that listed every
// folder; and the large blobs still go after every batch (`LargeUploads.swift`).

extension SyncEngine {
    /// More note folders to list one by one than this: listed in batches with their transfers.
    static let batchListingAbove = 32
    /// The first batch of a run, in notes; each next batch is twice as large, up to `largestListingBatch`.
    static let firstListingBatch = 8
    static let largestListingBatch = 128

    /// The note loop over batches: `known` holds the folders whose entries are known already (unchanged, or not on
    /// the server), `unlisted` the folders to list one by one.
    func syncNotesInBatches(_ known: [String: [RemoteEntry]], unlisted: [String], localNotes: [String]) throws {
        var remoteNotes = known
        let toList = Set(unlisted)
        let local = Set(localNotes)
        let ids = Set(known.keys).union(unlisted).union(localNotes).subtracting(notesNotReadable)
        let parts = notesInOrderParts(ids, remoteNotes: remoteNotes)

        // The sweep over the rest goes on after the last note an earlier run synced.
        var pass = state.listingPass ?? .init(cursor: nil, started: options.now, clean: true)
        // A sweep left unclean only by runs that skipped unchanged folders starts over once a run must list them all
        // (the daily full listing): it can then still earn `lastFullListing` (review of #97).
        if !skipsUnchangedNotes, !pass.clean, pass.skipRun == true {
            pass = .init(cursor: nil, started: options.now, clean: true)
        }
        if skipsUnchangedNotes { pass.clean = false; if pass.skipRun == nil { pass.skipRun = true } }
        if !notesNotReadable.isEmpty { pass.clean = false; pass.skipRun = false }
        let start = pass.cursor.map { c in parts.rest.firstIndex { $0 > c } ?? parts.rest.count } ?? 0
        let rest = Array(parts.rest[start...] + parts.rest[..<start])
        let last = parts.rest.last
        func passEnded() {
            // Every folder listed since the sweep started, none failing: a full listing (`NoteStamps.swift`).
            if pass.clean, !skipsUnchangedNotes, !options.dryRun { state.lastFullListing = pass.started }
            pass = .init(cursor: nil, started: options.now, clean: !skipsUnchangedNotes && notesNotReadable.isEmpty)
        }
        // The notes after the cursor are gone: the sweep reached its end with the last run.
        if start == parts.rest.count, start > 0 { passEnded() }
        defer { if !options.dryRun { state.listingPass = pass } }

        let order = parts.changed + rest
        noteRank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let restSet = Set(parts.rest)
        updateProgress { $0.notesTotal = ids.count }
        var next = 0
        var size = Self.firstListingBatch
        var held = false
        while next < order.count {
            let batch = Array(order[next..<min(next + size, order.count)])
            next += batch.count
            size = min(size * 2, Self.largestListingBatch)
            let names = batch.filter { toList.contains($0) && !notesNotReadable.contains($0) }
            if !names.isEmpty {
                updateProgress { $0.stage = .listing }
                let listed = setAsideArrivingAttachments(try listNoteFolders(names))
                noteRevisionsListed(listed)
                remoteNotes.merge(listed) { _, new in new }
                if !notesNotReadable.isEmpty { pass.clean = false; pass.skipRun = false }
            }
            let inBatch = batch.filter { !notesNotReadable.contains($0) }
            let members = Set(inBatch)
            let batchRemote = remoteNotes.filter { members.contains($0.key) }
            try listAttachments(batchRemote)
            requestArrivals(batchRemote)
            if !options.dryRun && !options.pushOnly { try prefetchDownloads(batchRemote) }
            if !options.dryRun { try preuploadNewFiles(batchRemote, localNotes: inBatch.filter(local.contains)) }
            updateProgress { $0.stage = .syncingNotes }
            // Every note of the batch, those whose listing failed too: they are not synced, but the cursor must see
            // them (review of #97, S3).
            for id in batch {
                if members.contains(id) { try syncNoteOfLoop(id, remoteEntries: remoteNotes[id]) }
                guard restSet.contains(id), !held else { continue }
                // A note whose listing or transfers met the dying link (its downloads, made ahead, failed; the loop then
                // makes no request for it) is where the next run goes on: the cursor stops before it for the rest of
                // this run. A listing that failed otherwise (a lasting error) is passed: it waits for the next sweep.
                if breaker.trippedError != nil || metNetworkFailure(id) { held = true; continue }
                pass.cursor = id
                if id == last { passEnded() }
            }
        }
        notesListed = notesNotReadable.isEmpty
        finishNoteStamps(notes: ids.union(notesNotReadable))
    }

    /// Whether a transfer of note `id` failed for the network this run (`LinkBreaker`).
    func metNetworkFailure(_ id: String) -> Bool {
        let prefix = "\(Vault.notesName)/\(id)"
        return locked { report.errors.contains { $0.path.hasPrefix(prefix) && breaker.sawNetworkFailure($0.message) } }
    }
}
