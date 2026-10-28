import Foundation

/// One line of a note listing.
///
/// `Codable` for `SummaryCache` only (the synthesized form, not a format):
/// a new field is cached automatically; bump `SummaryCache.schemaVersion`
/// whenever a field is added or computed differently.
public struct NoteSummary: Hashable, Sendable, Codable {
    /// The note id (its directory name).
    public var id: UUID
    /// The current title; empty when never set.
    public var title: String
    /// The current tags.
    public var tags: [String]
    /// The notebook, if any.
    public var notebook: String?
    /// True when the note's newest state is deleted.
    public var deleted: Bool
    /// Number of pages.
    public var pages: Int
    /// Number of strokes over all pages.
    public var strokes: Int
    /// The date of the last edit among the readable revisions (`ModifiedDate`, format.md §12.2):
    /// recognition-only deltas and compaction's snapshots do not move it.
    public var modified: Date?
    /// Set when some revisions could not be read (the numbers are then a
    /// best effort) or the note could not be reconstructed at all.
    public var problem: String?
    /// Number of pages with recognized handwriting text.
    public var recognizedPages: Int = 0
    /// The recognized text of each page that has some, for search (`NoteSearch`).
    public var pageTexts: [PageText] = []
    /// Number of pages whose recognition is missing or stale (`RecognitionPolicy`).
    public var pagesNeedingRecognition: Int = 0
    /// Number of placed items (text boxes, images, PDF pages, unknown kinds)
    /// over all pages (format.md §8.2).
    public var items: Int = 0
    /// Number of typed text boxes (`items` of kind `text`).
    public var textItems: Int = 0
    /// Number of audio recordings (format.md §8.3).
    public var recordings: Int = 0
    /// The kinds of attachments the note holds (images, PDF pages, video, equations, audio).
    public var attachments: NoteAttachments = []
    /// The recordings that have a transcript, for transcript search (`TranscriptSearch`).
    public var transcribed: [TranscribedRecording] = []
    /// The blobs the current state references (items' `blob`, recordings'
    /// `blob` and `transcript`), one per content hash, sorted by `sha256`.
    /// Older revisions may reference more (`Vault.blobInventory`).
    public var blobs: [BlobRef] = []
    /// The note's handwriting language (format.md §5.4 `lang`).
    public var lang: String?
    /// Marker strokes drawn below content items (format.md §5.4).
    public var markersBehindText = false
    /// The note is a favorite (format.md §5.4).
    public var favorite = false
    /// When the note was created (`meta.created`); nil when it could not be reconstructed.
    public var created: Date?
    /// The last vault-wide recognition run that read the note (format.md §5.4
    /// `recognized`): "Recently Recognized" lists the recent ones.
    public var recognized: RecognitionRecord?
    /// What the note holds that a newer version wrote, and what could not be
    /// shown (format.md §7.4); nil when nothing. The vault is then read-only.
    public var newer: NewerContent?

    public init(id: UUID, title: String, tags: [String], notebook: String?, deleted: Bool, pages: Int,
                strokes: Int, modified: Date?, problem: String?) {
        self.id = id; self.title = title; self.tags = tags; self.notebook = notebook; self.deleted = deleted
        self.pages = pages; self.strokes = strokes; self.modified = modified; self.problem = problem
    }

    /// Why a query matched no single note.
    public enum LookupError: Error, Hashable, Sendable {
        case notFound(String)
        case ambiguous(String, [UUID])
    }

    /// Picks one note by full id, id prefix (4 or more characters) or exact
    /// title (case-insensitive).
    public static func find(_ query: String, in notes: [NoteSummary]) throws -> NoteSummary {
        if let id = try matchID(query, among: notes.map(\.id)),
           let hit = notes.first(where: { $0.id == id }) { return hit }
        let q = query.lowercased()
        let hits = notes.filter { $0.title.lowercased() == q }
        guard let first = hits.first else { throw LookupError.notFound(query) }
        guard hits.count == 1 else { throw LookupError.ambiguous(query, hits.map(\.id)) }
        return first
    }

    /// Matches a full id or an id prefix of 4 or more characters; nil if the
    /// query is not an id of any of `ids`. Does not read any note.
    ///
    /// - Throws: `LookupError.ambiguous` when a prefix matches several.
    public static func matchID(_ query: String, among ids: [UUID]) throws -> UUID? {
        let q = query.lowercased()
        if let exact = ids.first(where: { $0.uuidString.lowercased() == q }) { return exact }
        guard q.count >= 4, q.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let hits = ids.filter { $0.uuidString.lowercased().hasPrefix(q) }
        if hits.count > 1 { throw LookupError.ambiguous(query, hits) }
        return hits.first
    }
}

extension LoadedNote {
    /// The same rows as `Vault.history(noteId:)`, from what was already
    /// loaded: readable revisions with their wall time and app, unreadable
    /// ones with their error, oldest first.
    public var history: [HistoryEntry] {
        let ok = revisions.map { HistoryEntry(name: $0.name, wall: $0.wall, app: $0.app, error: nil) }
        let bad = failures.map { HistoryEntry(name: $0.key, wall: nil, app: nil, error: $0.value) }
        return (ok + bad).sorted { $0.name < $1.name }
    }

    /// Revisions `compact` would delete from this note.
    ///
    /// The first revision is kept when another has an earlier `wall`, so
    /// that `created` cannot move (`CompactionPlanner.createdAnchor`).
    /// Checkpoints (format.md §5.8.1) are never deleted. With
    /// `protectingCheckpoints`, nothing that a complete checkpoint depends on
    /// is deleted either, since this plan writes no positioned snapshot: no
    /// revision ordered at or before the newest complete checkpoint, nor the
    /// first revision of each other device after a complete checkpoint (its
    /// witness, §5.8.4 rule 3). `CompactionPlanner.plan` keeps checkpoints
    /// complete with positioned snapshots instead and passes false.
    ///
    /// - Parameter assumingSnapshot: plan as if a snapshot of everything
    ///   were written now: it covers every revision, so every older snapshot
    ///   is subsumed and every delta past retention is covered.
    public func compactionPlan(retention: TimeInterval = CompactionPlanner.defaultRetention, now: Date = Date(),
                               assumingSnapshot: Bool = false, protectingCheckpoints: Bool = true) -> [RevisionName] {
        let anchor = CompactionPlanner.createdAnchor(revisions)
        let plan = unprotectedCompactionPlan(retention: retention, now: now, assumingSnapshot: assumingSnapshot)
            .filter { $0 != anchor }
        let checkpoints = Set(revisions.filter { $0.kind == .delta && $0.checkpoint != nil }.map(\.name))
        guard !checkpoints.isEmpty else { return plan }
        var out = plan.filter { !checkpoints.contains($0) }
        guard protectingCheckpoints else { return out }
        let complete = restorePoints.filter { $0.complete && checkpoints.contains($0.name) }.map(\.name)
        guard let newest = complete.max() else { return out }
        out = out.filter { $0 > newest }
        // A positioned snapshot (format.md §5.8.3) of a point at or before the
        // newest complete checkpoint is ordered after it but may be what keeps it complete.
        let positioned = NoteHistory.positions(revisions, unreadable: Array(failures.keys))
        out.removeAll { name in positioned[name].map { $0 <= RevisionKey(newest) } ?? false }
        let names = (revisions.map(\.name) + failures.keys).sorted()
        for c in complete {
            var seen = Set<DeviceID>([c.device])
            for n in names where n > c && seen.insert(n.device).inserted {
                out.removeAll { $0 == n }
            }
        }
        return out
    }

    private func unprotectedCompactionPlan(retention: TimeInterval, now: Date, assumingSnapshot: Bool) -> [RevisionName] {
        var wall: [RevisionName: Date] = [:]
        for r in revisions { wall[r.name] = r.wall }
        var snapshots = revisions.compactMap(SnapshotCoverage.init)
        if assumingSnapshot {
            var included = Included()
            for r in revisions {
                switch r.body {
                case .delta: included.insert(device: r.device, seq: r.seq)
                case .snapshot(let inc, _): included = included.union(inc)
                }
            }
            // The greatest possible name, so it wins every tie.
            let name = RevisionName(hlc: HLC(millis: HLC.maxMillis, counter: HLC.maxCounter) ?? .zero,
                                    device: .zero, seq: 1, kind: .snapshot)
            snapshots.append(SnapshotCoverage(name: name, included: included, wall: now))
        }
        let existing = Set(revisions.map(\.name))
        return CompactionPlanner.deletable(names: revisions.map(\.name), wall: wall, snapshots: snapshots,
                                           retention: retention, now: now).filter(existing.contains)
    }

    /// True when `compact` could not make progress without a snapshot: the
    /// note has deltas past retention that no snapshot covers (which includes
    /// a note without any snapshot, once something is old enough).
    public func needsSnapshotBeforeCompaction(retention: TimeInterval = CompactionPlanner.defaultRetention,
                                              now: Date = Date()) -> Bool {
        let snaps = revisions.compactMap(SnapshotCoverage.init)
        return revisions.contains { r in
            r.kind == .delta && now.timeIntervalSince(r.wall) > retention
                && !snaps.contains { $0.included.covers(device: r.device, seq: r.seq) }
        }
    }
}

extension NoteSummary {
    /// The summary of a reconstructed note.
    init(id: UUID, state: NoteState, modified: Date?, problem: String?, newer: NewerContent?) {
        self.init(id: id, title: state.meta.title, tags: state.meta.tags, notebook: state.meta.notebook,
                  deleted: state.deleted, pages: state.pages.count,
                  strokes: state.pages.reduce(0) { $0 + $1.strokes.count }, modified: modified, problem: problem)
        self.newer = newer
        recognizedPages = state.pages.filter { !($0.recognition?.text.isEmpty ?? true) }.count
        pageTexts = PageText.texts(of: state.pages)
        pagesNeedingRecognition = state.pages.filter { RecognitionPolicy.needsRecognition($0) }.count
        let items = state.pages.flatMap(\.items)
        self.items = items.count
        textItems = items.filter { $0.kind == .text }.count
        recordings = state.recordings.count
        attachments = NoteAttachments(state: state)
        transcribed = state.recordings.compactMap { r in
            r.transcript.map { TranscribedRecording(recording: r.id, title: r.title, blob: $0) }
        }
        blobs = state.blobReferences
        lang = state.meta.lang
        markersBehindText = state.meta.markersBehindText
        favorite = state.meta.favorite
        created = state.meta.created
        recognized = state.meta.recognized
    }
}

/// One note finished by `Vault.summaries(of:cache:maxConcurrency:progress:)`.
public struct SummaryProgress: Hashable, Sendable {
    /// The note's summary.
    public var summary: NoteSummary
    /// True when it came from the `SummaryCache` (nothing was decrypted).
    public var cached: Bool
    /// Notes finished so far, this one included.
    public var completed: Int
    /// Notes in the call.
    public var total: Int
}

extension Vault {
    /// Summarizes one note from whatever revisions can be read. Stroke
    /// geometry is skipped (`RevisionDetail.withoutStrokePoints`); the result
    /// equals `summary(of:loaded:)` of the fully decoded note.
    public func summary(of noteId: UUID) throws -> NoteSummary {
        summary(of: noteId, loaded: try loadNote(noteId, detail: .withoutStrokePoints))
    }

    /// Summarizes a note already loaded with `loadNote` (any `RevisionDetail`).
    public func summary(of noteId: UUID, loaded: LoadedNote) -> NoteSummary {
        summaryAndCheckpoint(of: noteId, loaded: loaded, wantCheckpoint: false).summary
    }

    /// `summary(of:loaded:)` and, with `wantCheckpoint`, the checkpoint of
    /// its reduction (nil when the note had unreadable or newer revisions,
    /// did not reconstruct, or cannot be checkpointed).
    func summaryAndCheckpoint(of noteId: UUID, loaded: LoadedNote, wantCheckpoint: Bool)
        -> (summary: NoteSummary, checkpoint: SummaryCheckpoint?) {
        let newer = loaded.newer
        let problem = loaded.failures.isEmpty ? nil : "\(loaded.failures.count) unreadable revision(s)"
        let modified = ModifiedDate.of(loaded.revisions)
        do {
            if wantCheckpoint, problem == nil, newer == nil {
                let (state, cp) = try NoteReducer.reconstructWithCheckpoint(loaded.revisions)
                return (NoteSummary(id: noteId, state: state, modified: modified, problem: nil, newer: nil), cp)
            }
            let state = try NoteReducer.reconstruct(loaded.revisions)
            return (NoteSummary(id: noteId, state: state, modified: modified, problem: problem, newer: newer), nil)
        } catch {
            var s = NoteSummary(id: noteId, title: "", tags: [], notebook: nil, deleted: false, pages: 0, strokes: 0,
                                modified: modified, problem: "cannot reconstruct: \(error)")
            s.newer = newer
            return (s, nil)
        }
    }

    /// The summary of note `id` from its revisions `names` (sorted files
    /// `files`), when `cache` holds a checkpoint of some of them and only
    /// new deltas were added: just those are read and merged in
    /// (`NoteReducer.advance`). Nil when that cannot give exactly what a
    /// full read gives; nothing is stored then.
    func incrementalSummary(of id: UUID, names: [RevisionName], files: [String], cache: SummaryCache)
        -> (summary: NoteSummary, history: [RevisionMeta]?)? {
        guard let cp = cache.checkpoint(of: id), cp.names.count < files.count else { return nil }
        let old = Set(cp.names)
        guard old.isSubset(of: files) else { return nil }
        let added = names.filter { !old.contains($0.filename) }
        guard added.allSatisfy(cp.admits) else { return nil }
        var revs: [Revision] = []
        for n in added {
            guard let r = try? readRevision(noteId: id, name: n, detail: .withoutStrokePoints), r.newer == nil
            else { return nil }
            revs.append(r)
        }
        guard let (state, next) = NoteReducer.advance(cp, with: revs) else { return nil }
        cache.storeCheckpoint(next, for: id)
        let history = cache.history(for: id, names: cp.names).map { ($0 + revs.map(RevisionMeta.init)) }
        return (NoteSummary(id: id, state: state, modified: next.modified, problem: nil, newer: nil), history)
    }

    /// Summaries of every note, sorted by title then id.
    public func summaries() throws -> [NoteSummary] {
        try summaries(of: nil)
    }

    /// Summaries of `ids` (every note when nil), sorted by title then id.
    ///
    /// Notes are read on up to `maxConcurrency` threads (0: one per core,
    /// at most 8; `Parallel.defaultWidth`), without stroke geometry. With a
    /// `cache`, a note whose revision file names match its entry is not
    /// decrypted at all; fresh summaries are stored and the cache is saved
    /// at the end (a failed save is kept in `cache.saveProblem`, the listing
    /// still succeeds). Listing every note also drops the entries of notes
    /// that are gone.
    ///
    /// `progress` is called once per note as it finishes, from worker
    /// threads, possibly concurrently.
    ///
    /// - Throws: `VaultError` when the vault cannot read or a note folder
    ///   cannot be listed (the first such note in `ids` order). Unreadable
    ///   revisions are not errors: they set the summary's `problem`.
    public func summaries(of ids: [UUID]?, cache: SummaryCache? = nil, maxConcurrency: Int = 0, saveCache: Bool = true,
                          progress: (@Sendable (SummaryProgress) -> Void)? = nil) throws -> [NoteSummary] {
        try summaryEntries(of: ids, cache: cache, maxConcurrency: maxConcurrency, saveCache: saveCache, progress: progress)
            .map(\.summary)
    }

    /// `summaries(of:cache:...)` with, per summary, the sorted revision file
    /// names it was made from (what a reader compares later listings with).
    public func summaryEntries(of ids: [UUID]?, cache: SummaryCache? = nil, maxConcurrency: Int = 0,
                               saveCache: Bool = true, progress: (@Sendable (SummaryProgress) -> Void)? = nil) throws
        -> [(summary: NoteSummary, revisions: [String])] {
        _ = try requireReadable()
        let all = ids == nil
        let ids = try ids ?? noteIDs()
        let counter = ProgressCounter()
        let total = ids.count
        let results = Parallel.map(ids, width: maxConcurrency > 0 ? maxConcurrency : Parallel.defaultWidth) { id in
            Result { () throws -> (NoteSummary, Bool, [String]) in
                let names = try revisionNames(of: id)
                let files = names.map(\.filename).sorted()
                if isNoteIncomplete(id) {
                    // A partial copy's note not fetched in full (format.md §1.2): never summarized from part of its log.
                    return (NoteSummary(id: id, title: "", tags: [], notebook: nil, deleted: false, pages: 0, strokes: 0,
                                        modified: nil, problem: Self.incompleteNoteProblem), false, files)
                }
                if let hit = cache?.summary(for: id, names: files) { return (hit, true, files) }
                if let cache, let (s, history) = incrementalSummary(of: id, names: names, files: files, cache: cache) {
                    cache.store(s, revisions: names, history: history)
                    return (s, false, files)
                }
                let loaded = try loadNote(id, names: names, detail: .withoutStrokePoints)
                // A note that changed since it was cached is likely to change again: keep its
                // reduction so the next change reads only the new files.
                let (s, checkpoint) = summaryAndCheckpoint(of: id, loaded: loaded,
                                                           wantCheckpoint: cache?.wantsCheckpoint(of: id) ?? false)
                if let cache {
                    if let checkpoint { cache.storeCheckpoint(checkpoint, for: id) } else { cache.dropCheckpoint(of: id) }
                }
                // The revisions' metadata too, so thinning need not read them again (`revisionIndex`).
                cache?.store(s, revisions: names, history: loaded.failures.isEmpty ? loaded.revisions.map(RevisionMeta.init) : nil)
                return (s, false, files)
            }
        } done: { _, result in
            guard let progress, case .success(let (s, cached, _)) = result else { return }
            progress(SummaryProgress(summary: s, cached: cached, completed: counter.increment(), total: total))
        }
        var out: [(summary: NoteSummary, revisions: [String])] = []
        out.reserveCapacity(results.count)
        for r in results {
            let (s, _, files) = try r.get()
            out.append((s, files))
        }
        if let cache {
            if all { cache.retain(only: Set(ids)) }
            // A caller reading in batches passes false and saves once at the
            // end: every save rewrites the whole file.
            if saveCache { try? cache.save() }
        }
        return out.sorted {
            ($0.summary.title.lowercased(), $0.summary.id.uuidString) < ($1.summary.title.lowercased(), $1.summary.id.uuidString)
        }
    }

    /// Resolves a full id, an id prefix of 4 or more characters, or an exact
    /// title to a note id. Ids are matched against the directory names
    /// without decrypting anything; only a title lookup reads the notes.
    ///
    /// - Throws: `VaultError.noteIncomplete` for a note a partial copy has not
    ///   fetched in full (format.md §1.2): it is neither shown nor edited from part of its log.
    public func resolveNote(_ query: String) throws -> UUID {
        if let id = try NoteSummary.matchID(query, among: try noteIDs()) {
            try requireNoteComplete(id)
            return id
        }
        return try NoteSummary.find(query, in: try summaries()).id
    }

    /// The revisions `compact` would delete, without deleting them.
    public func compactionPlan(noteId: UUID, retention: TimeInterval = CompactionPlanner.defaultRetention,
                               now: Date = Date(), assumingSnapshot: Bool = false) throws -> [RevisionName] {
        // Names, kinds, checkpoints and snapshot coverage only: no stroke geometry is decoded.
        try loadNote(noteId, detail: .withoutStrokePoints).compactionPlan(retention: retention, now: now,
                                                                         assumingSnapshot: assumingSnapshot)
    }

    /// See `LoadedNote.needsSnapshotBeforeCompaction`.
    public func needsSnapshotBeforeCompaction(noteId: UUID, retention: TimeInterval = CompactionPlanner.defaultRetention,
                                              now: Date = Date()) throws -> Bool {
        try loadNote(noteId, detail: .withoutStrokePoints).needsSnapshotBeforeCompaction(retention: retention, now: now)
    }
}

/// A thread-safe running count.
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// File names for exports.
public enum ExportName {
    /// `<sanitized title>-<first 8 hex of the id>`, safe on every filesystem:
    /// path separators, control and reserved characters become `-`, runs
    /// collapse, length is capped, an empty title becomes `untitled`.
    public static func stem(title: String, noteId: UUID) -> String {
        "\(component(title))-\(noteId.uuidString.lowercased().prefix(8))"
    }

    /// A title or notebook segment made safe as one file or folder name:
    /// path separators, control and reserved characters become `-`, runs
    /// collapse, length is capped, an empty result becomes `fallback`.
    public static func component(_ title: String, fallback: String = "untitled") -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var out = ""
        for scalar in title.unicodeScalars {
            if bad.contains(scalar) || scalar == " " { out += "-" } else { out.unicodeScalars.append(scalar) }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if out.count > 60 { out = String(out.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-.")) }
        // File names are limited in bytes (255 on most file systems), not characters: 60 emoji
        // are 240 bytes and one letter with many combining marks is unbounded. Leave room for
        // `-<8 hex>` and `.html`, `-assets` or `.pdf`.
        while out.utf8.count > maxBytes, !out.isEmpty { out.removeLast() }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return out.isEmpty ? fallback : out
    }

    /// Longest `component` result in UTF-8 bytes.
    public static let maxBytes = 120

    /// `component(_:)` for a folder: also avoids names that are reserved on Windows
    /// (`CON`, `NUL`, `COM1`, ...) and the names of the index files an export writes
    /// into a folder (`README.md`, `index.html`), which would otherwise collide with a
    /// notebook of that name.
    public static func folderComponent(_ name: String) -> String {
        let c = component(name)
        let lower = c.lowercased()
        let stem = lower.split(separator: ".", maxSplits: 1).first.map(String.init) ?? lower
        let reserved: Set<String> = ["con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6",
                                     "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6",
                                     "lpt7", "lpt8", "lpt9"]
        return reserved.contains(stem) || lower == "readme.md" || lower == "index.html" ? c + "_" : c
    }
}
