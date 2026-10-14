import Foundation
import Sempere

/// What deleting unused attachments did (`deleteUnusedAttachments`).
struct AttachmentDeletion: Equatable, Sendable {
    /// Blob files deleted.
    var deleted = 0
    /// Bytes freed (sizes on disk).
    var bytes: Int64 = 0
    /// Why some were not deleted (a note that could not be read in full, a
    /// blob that does not verify, iCloud): one line each.
    var problems: [String] = []
}

/// The unused-attachments index (docs/attachments.md §4, task E7).
///
/// One `AttachmentIndexEntry` per note, sealed in Application Support
/// (`AttachmentIndexStore`, per vault secret). It changes only where the
/// vault changed: every delta a `NoteWriter` writes (`DeviceClock`'s write
/// hook → `noteWritten`) and every summary read because a note's revision
/// names changed (sync and iCloud arrivals, `readSummaries`; an edit's own
/// re-read, `refresh`) queue that one note (`noteChanged`). The queue is
/// worked through by one model-owned task at utility priority
/// (`AttachmentIndexer.update`: one listing of the note's `att/`; for a note
/// with blobs, one listing of its revisions and a decryption of each revision
/// not read before). No update ever reads another note.
///
/// Settings → Storage builds its numbers from the entries
/// (`AttachmentStorageReport`, the same code as `sempere blobs unused`);
/// notes not indexed yet (an existing install, or notes whose summary came
/// from the summary cache) are indexed when Settings asks (`indexAttachments`).
/// Deleting goes through `Vault.collectBlobs(note:records:only:)` with the
/// entry's records, which reads the note again and honours the 30-day window.
/// In iCloud Drive a note with a revision not on this device decides nothing
/// (`CloudVault.requireLocal`).
extension AppModel {
    /// `Application Support/Sempere/AttachmentIndex`.
    nonisolated static var defaultAttachmentIndexRoot: URL { AppSupport.folder("AttachmentIndex") }

    /// The open vault's index files; nil while it cannot read (locked).
    func attachmentIndexStore() -> AttachmentIndexStore? {
        if let store = attachmentIndexStoreCache { return store }
        guard let vault, vault.canRead, let store = try? AttachmentIndexStore(root: attachmentIndexRoot, vault: vault)
        else { return nil }
        attachmentIndexStoreCache = store
        return store
    }

    // MARK: Updates

    /// A `NoteWriter` wrote a delta to note `id`: index it again, with the
    /// open editor's items as its current state when it is open.
    func noteWritten(_ id: UUID) {
        noteChanged(id, current: openEditor(id)?.blobHashes)
    }

    /// The revisions of note `id` changed: queue its index update. `current`
    /// is what the note now shows (a fresh summary's `blobs`), nil when unknown.
    func noteChanged(_ id: UUID, current: Set<String>?) {
        guard vault?.canRead == true, phase == .unlocked else { return }
        if let current { attachmentIndexQueue[id] = .some(current) } else if attachmentIndexQueue[id] == nil {
            attachmentIndexQueue[id] = .some(nil)
        }
        attachmentIndexPending = attachmentIndexQueue.count + (attachmentIndexTask == nil ? 0 : 1)
        startAttachmentIndexing()
    }

    /// Fresh summaries were read: queue those notes (a summary with a
    /// problem says nothing about the current state, but the note is still re-indexed).
    func summariesRead(_ summaries: [NoteSummary]) {
        for s in summaries { noteChanged(s.id, current: s.problem == nil ? Set(s.blobs.map(\.sha256)) : nil) }
    }

    private func startAttachmentIndexing() {
        guard attachmentIndexTask == nil, !attachmentIndexQueue.isEmpty else { return }
        let gen = generation
        attachmentIndexTask = Task { [weak self] in
            if let delay = self?.attachmentIndexDelay, delay > .zero { try? await Task.sleep(for: delay) }
            while let self, self.generation == gen, !Task.isCancelled,
                  let next = self.attachmentIndexQueue.first {
                self.attachmentIndexQueue[next.key] = nil
                await self.updateAttachmentIndex(next.key, current: next.value, gen: gen)
                self.attachmentIndexPending = self.attachmentIndexQueue.count
            }
            guard let self, self.generation == gen else { return }
            self.attachmentIndexTask = nil
            self.attachmentIndexPending = self.attachmentIndexQueue.count
            // Queued after the loop's last look.
            self.startAttachmentIndexing()
        }
    }

    /// Updates the entry of one note, off the main actor, and publishes it.
    private func updateAttachmentIndex(_ id: UUID, current: Set<String>?, gen: Int) async {
        guard let vault, let store = attachmentIndexStore() else { return }
        let previous = attachmentIndex[id]
        let source: any AttachmentIndexSource = attachmentIndexSource?(vault) ?? vault
        let cloud = isCloudVault, url = vault.url, hooks = cloudHooks, coordinate = coordinationURL
        let current = current ?? summaryBlobHashes(id)
        let now = attachmentNow()
        let entry = try? await offMain(priority: .utility) { () throws -> AttachmentIndexEntry in
            let previous = previous ?? store.load(id)
            let entry = try CloudVault.coordinatedRead(coordinate) { () -> AttachmentIndexEntry in
                // iCloud: never decide anything while a revision is not on this device.
                let local = !cloud || (try? CloudVault.requireLocal(note: id, vault: url, hooks: hooks)) != nil
                return AttachmentIndexer.update(note: id, previous: previous, source: source, current: current,
                                                local: local, now: now)
            }
            try? store.save(entry)
            return entry
        }
        guard generation == gen, let entry else { return }
        attachmentIndex[id] = entry
        attachmentIndexVersion &+= 1
    }

    /// Notes gone from the vault: their entries go too.
    func forgetAttachmentIndex(_ ids: some Sequence<UUID>) {
        let store = attachmentIndexStoreCache
        let gone = Array(ids)
        var changed = false
        for id in gone where attachmentIndex.removeValue(forKey: id) != nil { changed = true }
        for id in gone { attachmentIndexQueue[id] = nil }
        if changed { attachmentIndexVersion &+= 1 }
        guard let store, !gone.isEmpty else { return }
        Task.detached(priority: .utility) { for id in gone { store.remove(id) } }
    }

    /// Waits until every queued update is done (tests, and Settings' "Check").
    func attachmentIndexIdle() async {
        while let task = attachmentIndexTask { await task.value; if attachmentIndexTask == task { break } }
    }

    /// The vault closed: forget the index (its files stay for the next opening).
    func resetAttachmentIndex() {
        attachmentIndexTask?.cancel()
        attachmentIndexTask = nil
        attachmentIndexQueue = [:]
        attachmentIndexPending = 0
        attachmentIndex = [:]
        attachmentIndexLoaded = false
        attachmentIndexStoreCache = nil
        attachmentIndexVersion &+= 1
    }

    /// The hashes the list's summary of `id` says the note shows; nil when unknown.
    func summaryBlobHashes(_ id: UUID) -> Set<String>? {
        guard let s = notes.first(where: { $0.id == id }), s.problem == nil, !placeholderNoteIDs.contains(id) else {
            return nil
        }
        return Set(s.blobs.map(\.sha256))
    }

    /// The editor that has note `id` open, if any (library or note window).
    func openEditor(_ id: UUID) -> NoteEditor? {
        if let editor, editor.noteID == id { return editor }
        return windowEditors[id]
    }

    // MARK: Settings

    /// Reads every stored entry of the open vault once (entries updated this
    /// session are newer and kept).
    func loadAttachmentIndex() async {
        guard !attachmentIndexLoaded, let store = attachmentIndexStore() else { return }
        let gen = generation
        let stored = (try? await offMain(priority: .utility) { store.loadAll() }) ?? [:]
        guard gen == generation else { return }
        for (id, entry) in stored where attachmentIndex[id] == nil { attachmentIndex[id] = entry }
        attachmentIndexLoaded = true
        attachmentIndexVersion &+= 1
    }

    /// Queues the notes of the list that have no entry yet (`all`: every
    /// note, to look at each one's `att/` again, e.g. for blobs that arrived
    /// without a revision). Returns at once; the model's task does the work.
    func indexAttachments(all: Bool = false) async {
        await loadAttachmentIndex()
        for s in notes where !placeholderNoteIDs.contains(s.id) && (all || attachmentIndex[s.id] == nil) {
            noteChanged(s.id, current: s.problem == nil ? Set(s.blobs.map(\.sha256)) : nil)
        }
    }

    /// Notes in the list without an entry (Settings offers to check them).
    var notesWithoutAttachmentIndex: Int {
        notes.filter { !placeholderNoteIDs.contains($0.id) && attachmentIndex[$0.id] == nil }.count
    }

    /// Settings' numbers and lists, from the entries of the notes in the list.
    func attachmentStorage() -> AttachmentStorageReport {
        let listed = Set(notes.map(\.id))
        return AttachmentStorageReport(entries: attachmentIndex.values.filter { listed.contains($0.note) })
    }

    /// The title the list shows for note `id`.
    func noteTitle(_ id: UUID) -> String { notesByID[id]?.title ?? "" }

    // MARK: Deleting

    /// Deletes `items` through B2's per-note collection
    /// (`Vault.collectBlobs(note:records:only:)`): each note is read again in
    /// full and a blob goes only if no revision references it and this device
    /// first found it unused at least 30 days ago (the entry's records). In
    /// iCloud Drive the note and the blobs are made local first.
    func deleteUnusedAttachments(_ items: [AttachmentStorageReport.Unused]) async throws -> AttachmentDeletion {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        var result = AttachmentDeletion()
        let byNote = Dictionary(grouping: items, by: \.note)
        for note in byNote.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            try ensureCurrent(gen)
            let names = Set(byNote[note]?.map(\.fileName) ?? [])
            let cloud = isCloudVault, url = vault.url, hooks = cloudHooks
            if cloud {
                do {
                    try await downloadNote(note)
                    for name in names.sorted() {
                        try await CloudVault.downloadBlob(note: note, fileName: name, vault: url, hooks: hooks,
                                                          stallTimeout: cloudStallTimeout, pollInterval: cloudPollInterval)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    result.problems.append(String(localized: "\(noteTitleOrID(note)): not downloaded: \(String(describing: error))", comment: "Delete result; the note's title, then the error (English)"))
                    continue
                }
                try ensureCurrent(gen)
            }
            let records = attachmentIndex[note]?.unusedSince ?? [:]
            let now = attachmentNow()
            let folder = cloud ? CloudScan.noteFolder(inVault: url, id: note) : nil
            let outcome: (BlobCollectionReport, [String: Date])
            do {
                outcome = try await offMain(priority: .userInitiated) { () throws -> (BlobCollectionReport, [String: Date]) in
                    try CloudVault.coordinatedWrite(folder) { () throws -> (BlobCollectionReport, [String: Date]) in
                        if cloud { try CloudVault.requireLocal(note: note, vault: url, hooks: hooks) }
                        var r = records
                        let report = try vault.collectBlobs(note: note, records: &r, only: names, now: now)
                        return (report, r)
                    }
                }
            } catch {
                try ensureCurrent(gen)
                result.problems.append("\(noteTitleOrID(note)): \(error)")
                continue
            }
            try ensureCurrent(gen)
            let (report, kept) = outcome
            let sizes = Dictionary(byNote[note]?.map { ($0.fileName, $0.bytes) } ?? [], uniquingKeysWith: { a, _ in a })
            result.deleted += report.deleted.count
            result.bytes += report.deleted.reduce(0) { $0 + (sizes[$1] ?? 0) }
            if let blocked = report.blocked { result.problems.append("\(noteTitleOrID(note)): \(blocked)") }
            for (name, why) in report.failures.sorted(by: { $0.key < $1.key }) where names.contains(name) {
                result.problems.append(String(localized: "\(noteTitleOrID(note)): a file does not verify and was kept: \(why)", comment: "Delete result; the note's title, then the reason (English)"))
            }
            // Collection's look is the newest: keep its records, then refresh the entry.
            var entry = attachmentIndex[note] ?? AttachmentIndexEntry(note: note)
            entry.unusedSince = kept
            attachmentIndex[note] = entry
            await updateAttachmentIndex(note, current: nil, gen: gen)
        }
        return result
    }

    /// The unused attachments that may be deleted now ("Delete All Eligible").
    func eligibleUnusedAttachments() -> [AttachmentStorageReport.Unused] {
        attachmentStorage().eligible(at: attachmentNow())
    }

    private func noteTitleOrID(_ id: UUID) -> String {
        let t = noteTitle(id)
        return t.isEmpty ? String(id.uuidString.lowercased().prefix(8)) : NoteTitle.display(t)
    }

    // MARK: Previews

    /// The largest attachment Settings decrypts for a preview.
    nonisolated static let maxPreviewBytes = 32 << 20

    /// The content of an image or PDF blob for its preview in Settings
    /// (verified, in memory only); nil for other kinds, large files, or when
    /// it cannot be read.
    func attachmentPreviewData(note: UUID, fileName: String, kind: BlobKind) async -> Data? {
        guard kind == .image || kind == .pdf, let vault, phase == .unlocked else { return nil }
        if isCloudVault {
            try? await CloudVault.downloadBlob(note: note, fileName: fileName, vault: vault.url, hooks: cloudHooks,
                                               stallTimeout: cloudStallTimeout, pollInterval: cloudPollInterval)
        }
        let gen = generation
        let data = try? await offMain(priority: .utility) {
            try vault.readBlobFile(note: note, fileName: fileName, maxBytes: Self.maxPreviewBytes).content
        }
        guard gen == generation else { return nil }
        return data
    }
}

extension NoteEditor {
    /// The content hashes the note shows now (`Item.blobReferences`: blobs,
    /// video posters, equation renders; recordings' audio and transcripts),
    /// as `NoteState.blobReferences` gives them.
    var blobHashes: Set<String> {
        Set(pages.flatMap { $0.items.flatMap(\.blobReferences).map(\.sha256) }
            + recordings.flatMap { [$0.blob.sha256] + ($0.transcript.map { [$0.sha256] } ?? []) })
    }
}
