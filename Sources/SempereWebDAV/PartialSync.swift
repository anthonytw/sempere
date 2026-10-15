import Foundation
import Sempere

// MARK: - Partial copies (format.md §1.2, docs/io.md "Partial copies")
//
// A partial copy holds the vault's root files and its note folders, and
// fetches revisions and blobs later. Its state is in the folder itself:
// `.sempere-partial/` at the root, a marker in each note folder whose
// revisions have not all arrived, and a stand-in for each blob not fetched.
//
// - A *metadata* pull makes (or continues) one: the root files as a sync
//   pulls them, the server's sealed summaries (into `.sempere-partial/`),
//   and one empty marked folder per note the server lists. A few requests,
//   whatever the size of the vault. It never uploads and never deletes.
// - A *fetch* run fetches what the markers say is missing: a marked note's
//   folder is listed on the server as it is now and every revision there
//   that the copy lacks is downloaded (checked as any download is), the
//   note's blobs are fetched or get stand-ins, and only then is its marker
//   removed. It never uploads, never deletes anything on the server, never
//   writes a root file and never touches a note that is not marked (save the
//   blobs named for it). When nothing is pending any more, the copy is complete.
// - Push-only runs leave everything the copy lacks alone (`PushOnlySync`).

/// A partial pull (`WebDAVSyncOptions.partial`). The metadata pull marks
/// every note the server lists until the copy's note list is complete
/// (`isUsable`), and afterwards only notes it has no folder for.
public enum WebDAVPartialRun: Sendable, Hashable {
    /// Make a partial copy in a new folder, or continue one (its root files
    /// and note list); never a complete vault.
    case metadata
    /// Fetch what a partial copy lacks.
    case fetch(WebDAVFetchScope)
}

/// What a fetch run fetches.
public struct WebDAVFetchScope: Sendable, Hashable {
    /// Which blobs.
    public enum Blobs: Sendable, Hashable {
        /// None: each fetched note's blobs only get stand-ins.
        case none
        /// Every blob stand-in of the notes in scope.
        case all
        /// These, as `<note id>/<blob file name>`.
        case only(Set<String>)
    }

    /// The notes, first ones first; nil: every incomplete note (and, for
    /// blobs, every note with a stand-in).
    public var notes: [UUID]?
    /// Fetch the revisions of incomplete notes in scope.
    public var revisions: Bool
    public var blobs: Blobs
    /// At most this many notes in one run (the app runs small batches, so a
    /// push never waits long for the sync state).
    public var maxNotes: Int?
    /// Note listings and small revision downloads made at once.
    public var concurrency: Int

    public init(notes: [UUID]? = nil, revisions: Bool = true, blobs: Blobs = .all, maxNotes: Int? = nil,
                concurrency: Int = WebDAVFetchScope.defaultConcurrency) {
        self.notes = notes; self.revisions = revisions; self.blobs = blobs
        self.maxNotes = maxNotes; self.concurrency = concurrency
    }

    public static let defaultConcurrency = 4
    /// Revisions up to this size are downloaded concurrently (memory stays
    /// below `concurrency` times this); larger ones one at a time.
    static let concurrentRevisionBytes = 8 << 20
}

/// Reading the local state of a partial copy (format.md §1.2).
public enum WebDAVPartialCopy {
    /// The server's `sempere-summaries.sealed` as the metadata pull fetched it.
    public static func summariesURL(_ root: URL) -> URL {
        root.appendingPathComponent(PartialCopy.folderName).appendingPathComponent(PublishedSummaries.fileName)
    }

    static func recordURL(_ root: URL) -> URL {
        root.appendingPathComponent(PartialCopy.folderName).appendingPathComponent("record.json")
    }

    /// The record of `.sempere-partial/`.
    struct Record: Codable, Equatable {
        var version = 1
        /// True once every note folder the server listed has a local folder:
        /// until then the copy cannot be used (notes would be missing).
        var listed = false
    }

    static func readRecord(_ root: URL) -> Record? {
        guard let data = try? BoundedRead.contents(of: recordURL(root), maxBytes: 1 << 16) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func writeRecord(_ record: Record, _ root: URL) throws {
        try LocalFS.write(try JSONEncoder().encode(record), to: recordURL(root), replacing: true)
    }

    /// True when `root` is a partial copy whose note list is complete: it
    /// can be opened, and fetch runs can fill it.
    public static func isUsable(_ root: URL) -> Bool {
        PartialCopy.isPartial(root) && readRecord(root)?.listed == true
    }

    /// The note folders marked incomplete, sorted.
    public static func incompleteNotes(_ root: URL) -> [String] {
        let notes = root.appendingPathComponent(Vault.notesName)
        return ((try? LocalFS.entries(notes)) ?? []).filter {
            Vault.isNoteDirectoryName($0) && PartialCopy.isIncomplete(noteFolder: notes.appendingPathComponent($0))
        }
    }

    /// The blob stand-ins of note `id` whose blob is not local.
    static func pendingBlobs(_ root: URL, _ id: String) -> [String] {
        let att = root.appendingPathComponent(Vault.notesName).appendingPathComponent(id)
            .appendingPathComponent(Vault.attachmentsName)
        return PartialCopy.pending(in: (try? LocalFS.entries(att)) ?? [], accept: WebDAVSync.isBlobName)
    }

    /// Notes with at least one blob stand-in, with their pending blob names.
    public static func pendingBlobsByNote(_ root: URL) -> [String: [String]] {
        let notes = root.appendingPathComponent(Vault.notesName)
        var out: [String: [String]] = [:]
        for id in ((try? LocalFS.entries(notes)) ?? []) where Vault.isNoteDirectoryName(id) {
            let names = pendingBlobs(root, id)
            if !names.isEmpty { out[id] = names }
        }
        return out
    }

    /// What `root` still lacks; nil when it is not a partial copy.
    public static func status(_ root: URL) -> SyncReport.PartialStatus? {
        guard PartialCopy.isPartial(root) else { return nil }
        return SyncReport.PartialStatus(incompleteNotes: incompleteNotes(root).count,
                                        pendingBlobs: pendingBlobsByNote(root).values.reduce(0) { $0 + $1.count })
    }

    /// Removes `.sempere-partial/` when nothing is pending and the note list
    /// is complete. Returns true when the copy is (now) complete.
    @discardableResult
    static func finishIfComplete(_ root: URL) -> Bool {
        guard PartialCopy.isPartial(root) else { return true }
        guard readRecord(root)?.listed == true, incompleteNotes(root).isEmpty, pendingBlobsByNote(root).isEmpty else {
            return false
        }
        do { try FileManager.default.removeItem(at: root.appendingPathComponent(PartialCopy.folderName)) } catch {
            return false
        }
        return true
    }
}

extension WebDAVSync {
    func runPartial(_ run: WebDAVPartialRun) throws -> SyncReport {
        guard !options.dryRun else { throw WebDAVError.io("a partial pull has no dry run") }
        switch run {
        case .metadata: try runMetadata()
        case .fetch(let scope): try runFetch(scope)
        }
        if report.partial?.completed != true { report.partial = WebDAVPartialCopy.status(root) }
        report.progress = locked { var p = progress; p.stage = .done; return p }
        do {
            try state.save(stateURL)
            SyncState.removeTransfers(stateURL)
        } catch {
            report.errors.append(.init(path: stateURL.path, message: "cannot save sync state: \(Self.describe(error))"))
        }
        return report
    }

    // MARK: Metadata

    private func runMetadata() throws {
        let manifestURL = root.appendingPathComponent(Vault.manifestName)
        if FileManager.default.fileExists(atPath: manifestURL.path) && !PartialCopy.isPartial(root) {
            // Marking a complete vault's notes would block edits to them until fetched again.
            throw WebDAVError.io("\(root.path) holds a complete vault; a metadata pull only makes or continues a partial copy "
                                 + "(run an ordinary sync instead)")
        }
        try checkCancelled()
        let rootEntries = try client.list([]) ?? []
        try budget.list(rootEntries.count)
        let remoteRoot = Dictionary(rootEntries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        guard let manifest = remoteRoot[Vault.manifestName], !manifest.isCollection else {
            throw WebDAVError.io("there is no vault at \(SyncReport.printable(client.baseURL.absoluteString)) (no vault.json)")
        }
        try checkSameVault(remoteRoot)
        // Marked partial before anything else arrives, so an interrupted pull never looks complete.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(PartialCopy.folderName),
                                                withIntermediateDirectories: true)
        var record = WebDAVPartialCopy.readRecord(root) ?? .init()
        if WebDAVPartialCopy.readRecord(root) == nil { try WebDAVPartialCopy.writeRecord(record, root) }
        checkerBaseManifest = manifestHash()
        remoteJournal = remoteRoot[Vault.journalName] != nil
        if !remoteJournal { state.inFlightJournal = nil }

        for name in [Vault.manifestName, Vault.journalName] {
            let remote = remoteRoot[name].flatMap { $0.isCollection ? nil : $0 }
            do { try syncMutable(name, remote: remote) } catch {
                report.errors.append(.init(path: name, message: Self.describe(error)))
            }
        }
        let remoteSettings = remoteRoot[SharedSettings.fileName].flatMap { $0.isCollection ? nil : $0 }
        do { try syncSharedSettings(remote: remoteSettings) } catch {
            report.errors.append(.init(path: SharedSettings.fileName, message: Self.describe(error)))
        }
        // Notebook records are root files of a partial copy (format.md §1.2, §14).
        do { try syncNotebookRecords(remoteRoot: remoteRoot) } catch {
            report.errors.append(.init(path: NotebookRecords.folderName, message: Self.describe(error)))
        }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            // Nothing can be checked or opened without it; the next run tries again.
            report.errors.append(.init(path: Vault.manifestName, message: "not received; run again"))
            return
        }
        fetchPublishedSummaries(remoteRoot[PublishedSummaries.fileName])

        // The note list: one folder per note, marked incomplete until a fetch fills it.
        try checkCancelled()
        var dirs: [RemoteEntry] = []
        if rootEntries.contains(where: { $0.name == Vault.notesName && $0.isCollection }) {
            dirs = try client.list([Vault.notesName]) ?? []
            try budget.list(dirs.count)
        }
        let notes = dirs.filter { $0.isCollection && Vault.isNoteDirectoryName($0.name) }
        updateProgress { $0.notesTotal = notes.count; $0.notesListed = notes.count }
        if notes.count > options.limits.maxNotes {
            throw WebDAVError.limitExceeded("the server lists \(notes.count) notes, more than \(options.limits.maxNotes) (--max-notes)")
        }
        for d in dirs where !(d.isCollection && Vault.isNoteDirectoryName(d.name)) {
            report.ignored.append(SyncReport.printable("notes/\(d.name)"))
        }
        // Until the note list is complete, every note the server lists is marked, whatever its
        // folder holds (files linked in by "Download Again", or left by an unfinished download, are
        // only a head start: a fetch takes the rest). A pull continuing a usable copy marks only
        // notes it has no folder for: the others are complete or already marked.
        let local = Set(try localNoteIDs())
        for d in notes where !record.listed || !local.contains(d.name) {
            try markIncomplete(d.name)
        }
        record.listed = true
        try WebDAVPartialCopy.writeRecord(record, root)
        if WebDAVPartialCopy.finishIfComplete(root) { report.partial = .init(completed: true) }
    }

    /// The server's sealed summaries (format.md §12) into `.sempere-partial/`:
    /// what a reader lists the copy's notes from before their revisions
    /// arrive. Opened (authenticated) only by the reader, with the key; an
    /// unreadable one is only a slower listing. A server without one leaves none.
    private func fetchPublishedSummaries(_ remote: RemoteEntry?) {
        let target = WebDAVPartialCopy.summariesURL(root)
        guard let remote, !remote.isCollection else {
            try? FileManager.default.removeItem(at: target)
            return
        }
        do {
            if let size = remote.size, size > PublishedSummaries.maxFileBytes {
                throw WebDAVError.responseTooLarge(path: PublishedSummaries.fileName, limit: PublishedSummaries.maxFileBytes)
            }
            budget.release(try budget.willDownload(remote.size))   // a check: counted below
            let data = try client.get([PublishedSummaries.fileName], maxBytes: PublishedSummaries.maxFileBytes).data
            try budget.downloaded(data.count)
            try LocalFS.write(data, to: target, replacing: true)
            report.downloaded.append(PublishedSummaries.fileName)
        } catch {
            try? FileManager.default.removeItem(at: target)
            report.skipped.append(.init(path: PublishedSummaries.fileName, message: "not fetched (\(Self.describe(error))); "
                                        + "notes are listed as their revisions arrive"))
        }
    }

    /// Creates note `id`'s folder (if needed) with its incomplete marker.
    func markIncomplete(_ id: String) throws {
        let dir = root.appendingPathComponent(Vault.notesName).appendingPathComponent(id)
        let marker = dir.appendingPathComponent(PartialCopy.noteMarkerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try LocalFS.write(Data(), to: marker, replacing: true)
    }

    // MARK: Fetch

    /// One note's work in a fetch run.
    private struct NoteWork: Sendable {
        var id: String
        /// Fetch its revisions (it is marked incomplete).
        var revisions: Bool
        /// The blob file names to fetch; nil: every stand-in.
        var blobs: Set<String>?
        var fetchBlobs: Bool
    }

    /// A note folder as the server lists it now.
    private struct NoteListing: Sendable {
        var entries: [RemoteEntry]?
        var att: [RemoteEntry]?
        var error: String?
    }

    private func runFetch(_ scope: WebDAVFetchScope) throws {
        guard PartialCopy.isPartial(root) else { return }   // complete: nothing to fetch
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(Vault.manifestName).path) else {
            throw WebDAVError.io("no \(Vault.manifestName) in \(root.path): run a metadata pull first (--metadata-only)")
        }
        guard WebDAVPartialCopy.readRecord(root)?.listed == true else {
            throw WebDAVError.io("the partial copy's note list is not complete: run a metadata pull again (--metadata-only)")
        }
        checkerBaseManifest = manifestHash()
        recordedFiles = state.fileNamesByNote()
        let work = fetchWork(scope)
        let width = max(1, scope.concurrency)

        // 1. Listings, concurrently (network only).
        let client = self.client
        let listings = Parallel.map(work, width: width) { w -> NoteListing in
            do {
                guard let entries = try client.list([Vault.notesName, w.id]) else { return NoteListing() }
                var listing = NoteListing(entries: entries)
                if entries.contains(where: { $0.name == Vault.attachmentsName && $0.isCollection }) {
                    listing.att = try client.list([Vault.notesName, w.id, Vault.attachmentsName]) ?? []
                }
                return listing
            } catch {
                return NoteListing(error: Self.describe(error))
            }
        }

        // What this run will fetch, for `progress` (the same choice `fetchNote` makes below).
        var files = 0
        var bytes: Int64 = 0
        for (w, l) in zip(work, listings) {
            if w.revisions, let entries = l.entries {
                let have = localRevisionNames(w.id) ?? []
                for e in entries where !e.isCollection && RevisionName(e.name)?.filename == e.name && !have.contains(e.name) {
                    files += 1
                    bytes += Int64(max(e.size ?? 0, 0))
                }
            }
            if w.fetchBlobs, let att = l.att {
                let local = localBlobNames(w.id) ?? []
                for e in att where !e.isCollection && Self.isBlobName(e.name) && !local.contains(e.name)
                    && (w.blobs?.contains(e.name) ?? true) {
                    files += 1
                    bytes += Int64(max(e.size ?? 0, 0))
                }
            }
        }
        updateProgress {
            $0.stage = .downloading
            $0.notesTotal = work.count
            $0.notesListed = work.count
            $0.filesTotal += files
            $0.bytesTotal += bytes
        }

        // 2. Small revisions, concurrently; the rest are downloaded one at a time below.
        var small: [(id: String, name: RevisionName, entry: RemoteEntry)] = []
        for (w, l) in zip(work, listings) where w.revisions {
            guard let entries = l.entries else { continue }
            let have = localRevisionNames(w.id) ?? []
            for e in entries where !e.isCollection {
                guard let n = RevisionName(e.name), n.filename == e.name, !have.contains(e.name),
                      let size = e.size, size >= 0, size <= WebDAVFetchScope.concurrentRevisionBytes, size <= options.maxFileBytes,
                      state.quarantined?[key(w.id, n)] == nil else { continue }
                small.append((w.id, n, e))
            }
        }
        var bodies: [String: Data] = [:]
        if !small.isEmpty {
            // Each size is 0...8 MiB here; summed saturating anyway (sizes come from the server).
            // A check: each body is counted when it is placed.
            budget.release(try budget.willDownload(small.reduce(0) { sum, job in
                let (total, overflow) = sum.addingReportingOverflow(max(0, job.entry.size ?? 0))
                return overflow ? Int.max : total
            }))
            let maxBytes = WebDAVFetchScope.concurrentRevisionBytes
            let fetched = Parallel.map(small.map { [Vault.notesName, $0.id, $0.name.filename] }, width: width) { path in
                try? client.get(path, maxBytes: maxBytes).data
            }
            for (job, data) in zip(small, fetched) {
                guard let data else { continue }   // downloaded again below, where an error is reported
                bodies[key(job.id, job.name)] = data
            }
        }

        // A note folder that answered 404 is gone only if `notes/` no longer lists it either: one
        // listing confirms it (a server's passing 404 must not drop a note from this copy).
        var serverNotes: Set<String>?
        if zip(work, listings).contains(where: { $0.1.entries == nil && $0.1.error == nil }) {
            if let dirs = try? client.list([Vault.notesName]) {
                serverNotes = Set(dirs.filter(\.isCollection).map(\.name))
            }
        }

        // 3. Per note: place, then blobs, then the marker.
        do {
            for (w, l) in zip(work, listings) {
                try checkCancelled()
                try budget.checkTime()
                do {
                    try fetchNote(w, listing: l, serverNotes: serverNotes, bodies: &bodies)
                } catch {
                    try rethrowRunLimit(error)
                    report.errors.append(.init(path: "notes/\(w.id)", message: Self.describe(error)))
                }
                updateProgress { $0.notesSynced += 1 }
            }
        } catch let e as WebDAVError where e.isRunLimit {
            report.stoppedEarly = Self.describe(e)
            report.errors.append(.init(path: Vault.notesName, message: Self.describe(e)))
        }
        if WebDAVPartialCopy.finishIfComplete(root) { report.partial = .init(completed: true) }
    }

    /// The notes a fetch run looks at, in order.
    private func fetchWork(_ scope: WebDAVFetchScope) -> [NoteWork] {
        let incomplete = Set(WebDAVPartialCopy.incompleteNotes(root))
        let withStandIns = scope.blobs == .none ? [:] : WebDAVPartialCopy.pendingBlobsByNote(root)
        var only: [String: Set<String>] = [:]
        if case .only(let keys) = scope.blobs {
            for k in keys {
                let parts = k.split(separator: "/", maxSplits: 1).map(String.init)
                if parts.count == 2 { only[parts[0].lowercased(), default: []].insert(parts[1]) }
            }
        }
        var ids: [String]
        if let notes = scope.notes {
            var seen = Set<String>()
            ids = notes.map { $0.uuidString.lowercased() }.filter { seen.insert($0).inserted }
        } else {
            ids = incomplete.sorted() + Set(withStandIns.keys).union(only.keys).subtracting(incomplete).sorted()
        }
        var out: [NoteWork] = []
        for id in ids {
            let revisions = scope.revisions && incomplete.contains(id)
            var blobs: Set<String>?
            let fetchBlobs: Bool
            switch scope.blobs {
            case .none: fetchBlobs = false
            case .all: fetchBlobs = true
            case .only: fetchBlobs = only[id] != nil; blobs = only[id] ?? []
            }
            let wantsBlobs = fetchBlobs && (blobs.map { !$0.isEmpty } ?? (withStandIns[id] != nil || revisions))
            guard revisions || wantsBlobs else { continue }
            out.append(NoteWork(id: id, revisions: revisions, blobs: blobs, fetchBlobs: fetchBlobs))
        }
        if let max = scope.maxNotes, out.count > max { out = Array(out.prefix(Swift.max(1, max))) }
        return out
    }

    /// Fetches one note of a partial copy: its missing revisions (when it is
    /// marked incomplete), its blobs or their stand-ins, then removes its
    /// marker once it holds every revision the server listed and its blobs
    /// are accounted for. Records what both sides now share.
    private func fetchNote(_ w: NoteWork, listing: NoteListing, serverNotes: Set<String>?,
                           bodies: inout [String: Data]) throws {
        if let error = listing.error { throw WebDAVError.io(error) }
        let dir = root.appendingPathComponent(Vault.notesName).appendingPathComponent(w.id)
        guard let entries = listing.entries else {
            // The note folder answered 404. Gone from the server only if `notes/` no longer lists
            // it (`serverNotes`): then a marked note without local revisions is only the metadata
            // pull's stub and goes. Otherwise (still listed, or `notes/` could not be listed) the
            // note stays as it is, marked, and a later run tries again; any other is reported.
            let local = localRevisionNames(w.id) ?? []
            guard let serverNotes, !serverNotes.contains(w.id) else {
                let why = serverNotes == nil ? "and notes/ could not be listed to confirm it is gone" : "but still lists the note"
                report.errors.append(.init(path: "notes/\(w.id)", message: "the server did not list this note's folder (404) "
                                           + "\(why); kept, tried again later"))
                return
            }
            if w.revisions, local.isEmpty {
                try FileManager.default.removeItem(at: dir)
                report.skipped.append(.init(path: "notes/\(w.id)", message: "no longer on the server; its empty local folder was removed"))
            } else {
                report.errors.append(.init(path: "notes/\(w.id)", message: "the server has no such note folder; nothing fetched"))
            }
            return
        }
        try budget.list(entries.count + (listing.att?.count ?? 0))
        var R = Set<RevisionName>()
        var byName: [RevisionName: RemoteEntry] = [:]
        for e in entries where !e.isCollection {
            guard let n = RevisionName(e.name), n.filename == e.name else {
                report.ignored.append(SyncReport.printable("notes/\(w.id)/\(e.name)"))
                continue
            }
            R.insert(n)
            byName[n] = e
        }
        var complete = true
        if w.revisions {
            let have = Set((localRevisionNames(w.id) ?? []).compactMap(RevisionName.init))
            for n in R.subtracting(have).sorted() {
                let k = key(w.id, n)
                beginCounted(k, size: byName[n]?.size)
                var placed = false
                defer { endCounted(k, placed: placed) }
                do {
                    if let data = bodies.removeValue(forKey: k) {
                        try budget.downloaded(data.count)
                        placed = try placeRevision(w.id, n, entry: byName[n], data: data)
                    } else {
                        placed = try download(w.id, n, entry: byName[n])
                    }
                    // Refused and quarantined (reported in `quarantined`, then `skipped`): settled, as a
                    // full download leaves it out. Anything else not placed keeps the note incomplete.
                    if !placed && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(n.filename).path)
                        && state.quarantined?[k] == nil {
                        complete = false
                    }
                } catch {
                    try rethrowRunLimit(error)
                    complete = false
                    report.errors.append(.init(path: "notes/\(k)", message: Self.describe(error)))
                }
            }
        }

        // Blobs: fetched, or a stand-in for each one the copy lacks; stand-ins of blobs the server no longer has go.
        let att = attURL(w.id)
        var remoteBlobs: [String: RemoteEntry] = [:]
        if let listed = listing.att {
            for e in listed where !e.isCollection && !e.name.hasPrefix(FileIO.tempPrefix) {
                if Self.isBlobName(e.name) { remoteBlobs[e.name] = e } else {
                    report.ignored.append(SyncReport.printable("notes/\(w.id)/\(Vault.attachmentsName)/\(e.name)"))
                }
            }
        }
        let localBlobs = localBlobNames(w.id) ?? []
        var placedBlobs = Set<String>()
        let wanted = w.fetchBlobs ? (w.blobs ?? Set(remoteBlobs.keys)) : []
        for name in remoteBlobs.keys.sorted() where !localBlobs.contains(name) {
            let standInURL = att.appendingPathComponent(PartialCopy.standInName(for: name))
            if wanted.contains(name) {
                let k = blobKey(w.id, name)
                beginCounted(k, size: remoteBlobs[name]?.size)
                defer { endCounted(k, placed: placedBlobs.contains(name)) }
                do {
                    if try downloadBlob(w.id, name, entry: remoteBlobs[name]) != nil { placedBlobs.insert(name) }
                } catch {
                    try rethrowRunLimit(error)
                    report.errors.append(.init(path: blobPath(w.id, name), message: Self.describe(error)))
                }
            }
            if !placedBlobs.contains(name), isQuarantined(blobKey(w.id, name)) {
                // Refused by a check (this run or an earlier one, reported there): settled, no
                // stand-in, as a full download leaves it out.
                try? LocalFS.remove(standInURL)
                continue
            }
            if !placedBlobs.contains(name) {
                if !FileManager.default.fileExists(atPath: standInURL.path) {
                    do { try LocalFS.write(Data(), to: standInURL, replacing: true) } catch {
                        complete = false
                        report.errors.append(.init(path: blobPath(w.id, name), message: Self.describe(error)))
                    }
                }
            }
        }
        for name in WebDAVPartialCopy.pendingBlobs(root, w.id) where remoteBlobs[name] == nil || placedBlobs.contains(name)
            || localBlobs.contains(name) {
            try? LocalFS.remove(att.appendingPathComponent(PartialCopy.standInName(for: name)))
        }

        // What both sides hold now is recorded, as a sync does (a push then judges it like any synced file).
        let localNow = Set((localRevisionNames(w.id) ?? []).compactMap(RevisionName.init))
        for n in localNow.intersection(R) where state.files[key(w.id, n)] == nil {
            state.files[key(w.id, n)] = SyncState.FileRecord()
        }
        for name in (localBlobNames(w.id) ?? []).intersection(remoteBlobs.keys) where state.files[blobKey(w.id, name)] == nil {
            state.files[blobKey(w.id, name)] = SyncState.FileRecord()
        }
        // The marker goes last: from then on the note holds every revision the server listed.
        if w.revisions, complete, R.subtracting(quarantinedRevisions(w.id)).isSubset(of: localNow) {
            try LocalFS.remove(dir.appendingPathComponent(PartialCopy.noteMarkerName))
        }
    }

    /// True when `key` (`<id>/<file>` or `<id>/att/<file>`) is quarantined by this or an earlier run.
    func isQuarantined(_ key: String) -> Bool { state.quarantined?[key] != nil }

    /// The revisions of note `id` that are quarantined: settled for a partial
    /// copy's completeness, as a full download leaves them out (format.md §1.2).
    func quarantinedRevisions(_ id: String) -> Set<RevisionName> {
        let prefix = "\(id)/"
        return Set((state.quarantined ?? [:]).keys.compactMap { k -> RevisionName? in
            guard k.hasPrefix(prefix) else { return nil }
            return RevisionName(String(k.dropFirst(prefix.count)))
        })
    }

    // MARK: Ordinary runs on a partial copy

    /// After an ordinary two-way run synced note `id` (listed on the server
    /// as `remote`): a marked note that now holds every revision the server
    /// listed loses its marker, and stand-ins of blobs that are now local or
    /// gone from the server are removed.
    func settlePartialNote(_ id: String, remote: Set<RevisionName>, remoteBlobs: Set<String>?) {
        guard !options.dryRun, !options.pushOnly, PartialCopy.isPartial(root) else { return }
        let dir = root.appendingPathComponent(Vault.notesName).appendingPathComponent(id)
        let local = Set((localRevisionNames(id) ?? []).compactMap(RevisionName.init))
        if PartialCopy.isIncomplete(noteFolder: dir), remote.subtracting(quarantinedRevisions(id)).isSubset(of: local) {
            if remote.isEmpty && local.isEmpty {
                // A metadata pull's stub of a note the server no longer has.
                try? FileManager.default.removeItem(at: dir)
                return
            }
            try? LocalFS.remove(dir.appendingPathComponent(PartialCopy.noteMarkerName))
        }
        guard let remoteBlobs else { return }
        let localBlobs = localBlobNames(id) ?? []
        for name in WebDAVPartialCopy.pendingBlobs(root, id)
        where localBlobs.contains(name) || !remoteBlobs.contains(name) || isQuarantined(blobKey(id, name)) {
            try? LocalFS.remove(attURL(id).appendingPathComponent(PartialCopy.standInName(for: name)))
        }
    }
}
