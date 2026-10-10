import Foundation
import Sempere

// MARK: - Unchanged notes (`WebDAVSyncOptions.skipUnchangedNotes`)
//
// A run lists every note folder on the server (one PROPFIND each). The
// `notes/` listing already gives each folder's ETag, so a folder whose ETag
// is the one recorded when the last run left the note in step on both sides,
// and whose local copy holds exactly the recorded revisions, is taken to hold
// the recorded revisions on the server too, and is not listed. Its `att/`
// (when it has one) is still listed: many servers change a folder's ETag only
// when a direct child changes.
//
// It is only trusted where it is seen to work. When this device writes a
// revision into a note folder it keeps the folder's ETag from before; the
// next run checks the server changed it. One write seen changing it enables
// the skip, one seen not changing it disables it for good. A weak or missing
// ETag is never recorded. A run lists every note at least every
// `fullListingInterval`, and any doubt (an error, a skipped or ignored file,
// a file on one side only, a write) clears the note's record, so its next
// run lists it.

extension WebDAVSync {
    /// How far the report had grown when a note's sync started.
    struct NoteMark {
        var uploaded, deleted, issues: Int

        init(_ r: SyncReport) {
            uploaded = r.uploaded.count
            deleted = r.deleted.count
            issues = Self.issues(r)
        }

        static func issues(_ r: SyncReport) -> Int {
            r.errors.count + r.skipped.count + r.ignored.count + r.extraneous.count + r.rejected.count
                + r.quarantined.count + r.conflicts.count
        }
    }

    /// After the `notes/` listing: checks the folders this device wrote into
    /// last run, records the ETags, and decides whether this run may skip.
    func checkNoteStamps(_ dirs: [RemoteEntry]) {
        for d in dirs where d.isCollection && Vault.isNoteDirectoryName(d.name) {
            if let etag = d.etag, Self.isStrong(etag) { noteETags[d.name] = etag }
        }
        for (id, before) in state.stampProbes ?? [:] {
            guard let now = noteETags[id] else { continue }
            if now == before {
                state.folderETagsChange = false
            } else if state.folderETagsChange == nil {
                state.folderETagsChange = true
            }
        }
        state.stampProbes = nil
        if state.folderETagsChange == false { state.notes = nil }
        let fresh = state.lastFullListing.map { last in
            options.now >= last && options.now.timeIntervalSince(last) < options.fullListingInterval
        } ?? false
        skipsUnchangedNotes = options.skipUnchangedNotes && hadState && state.folderETagsChange == true && fresh
    }

    /// The remote entries of an unchanged note folder (its recorded
    /// revisions, and `att/` if it had one), or nil when it must be listed.
    func unchangedNoteEntries(_ d: RemoteEntry) -> [RemoteEntry]? {
        guard skipsUnchangedNotes, let record = state.notes?[d.name], let etag = noteETags[d.name],
              etag == record.etag else { return nil }
        let recorded = recordedRevisions(d.name)
        guard let local = localRevisionNames(d.name), local == Set(recorded.map(\.filename)) else { return nil }
        if !record.att {
            // No server att/ to list: the local one must hold nothing to upload.
            guard let blobs = localBlobNames(d.name), blobs.isEmpty, recordedBlobs(d.name).isEmpty else { return nil }
        }
        notesNotListed += 1
        var out = recorded.sorted().map { RemoteEntry(name: $0.filename, isCollection: false) }
        if record.att { out.append(RemoteEntry(name: Vault.attachmentsName, isCollection: true)) }
        return out
    }

    /// After a note synced without throwing: records its folder's ETag when
    /// the note is unchanged and in step, and keeps it to check when this
    /// run wrote a revision into the folder.
    func recordNoteStamp(_ id: String, remoteEntries: [RemoteEntry]?, since mark: NoteMark) {
        guard !options.dryRun, let etag = noteETags[id] else { return }
        let prefix = "notes/\(id)/", attPrefix = "notes/\(id)/\(Vault.attachmentsName)/"
        let uploads = report.uploaded[mark.uploaded...].filter { $0.hasPrefix(prefix) }
        let deletes = report.deleted[mark.deleted...].filter { $0.side == "remote" && $0.path.hasPrefix(prefix) }
        let clean = NoteMark.issues(report) == mark.issues
        // Only a revision upload that went through is a write the folder's ETag must show:
        // an upload is listed before it is made, and a DELETE of a file already gone succeeds.
        if clean, uploads.contains(where: { !$0.hasPrefix(attPrefix) }) {
            state.stampProbes = (state.stampProbes ?? [:]).merging([id: etag]) { _, new in new }
        }
        guard state.folderETagsChange != false, uploads.isEmpty, deletes.isEmpty, clean,
              let local = localRevisionNames(id), local == Set(remoteRevisions[id] ?? []) else { return }
        let att = (remoteEntries ?? []).contains { $0.name == Vault.attachmentsName && $0.isCollection }
        if !att {
            guard let blobs = localBlobNames(id), blobs.isEmpty else { return }
        }
        state.notes = (state.notes ?? [:]).merging([id: .init(etag: etag, att: att)]) { _, new in new }
    }

    /// After the notes loop: drops records of notes neither side has, and
    /// notes when every note was listed.
    func finishNoteStamps(notes: Set<String>) {
        guard !options.dryRun else { return }
        state.notes = state.notes?.filter { notes.contains($0.key) }
        if !skipsUnchangedNotes && report.stoppedEarly == nil { state.lastFullListing = options.now }
    }

    /// The local revision file names of a note; nil when the folder cannot be listed.
    func localRevisionNames(_ id: String) -> Set<String>? {
        let dir = root.appendingPathComponent(Vault.notesName).appendingPathComponent(id)
        guard let names = try? LocalFS.entries(dir) else { return nil }
        return Set(names.filter { RevisionName($0)?.filename == $0 })
    }

    /// The local blob file names of a note; nil when its `att/` cannot be listed.
    func localBlobNames(_ id: String) -> Set<String>? {
        guard let names = try? LocalFS.entries(attURL(id)) else { return nil }
        return Set(names.filter(Self.isBlobName))
    }
}
