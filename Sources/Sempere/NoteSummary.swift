import Foundation

/// One line of a note listing.
///
/// `Codable` for `SummaryCache` only (the synthesised form, not a format):
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
    /// Wall time of the newest readable revision.
    public var modified: Date?
    /// Set when some revisions could not be read (the numbers are then a
    /// best effort) or the note could not be reconstructed at all.
    public var problem: String?
    /// Number of pages with recognised handwriting text.
    public var recognizedPages: Int = 0
    /// The recognised text of each page that has some, for search (`NoteSearch`).
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
    /// Summarises one note from whatever revisions can be read. Stroke
    /// geometry is skipped (`RevisionDetail.withoutStrokePoints`); the result
    /// equals `summary(of:loaded:)` of the fully decoded note.
    public func summary(of noteId: UUID) throws -> NoteSummary {
        summary(of: noteId, loaded: try loadNote(noteId, detail: .withoutStrokePoints))
    }

    /// Summarises a note already loaded with `loadNote` (any `RevisionDetail`).
    public func summary(of noteId: UUID, loaded: LoadedNote) -> NoteSummary {
        var s = NoteSummary(id: noteId, title: "", tags: [], notebook: nil, deleted: false, pages: 0, strokes: 0,
                            modified: loaded.revisions.map(\.wall).max(), problem: nil)
        if !loaded.failures.isEmpty {
            s.problem = "\(loaded.failures.count) unreadable revision(s)"
        }
        s.newer = loaded.newer
        do {
            let state = try NoteReducer.reconstruct(loaded.revisions)
            s.title = state.meta.title
            s.tags = state.meta.tags
            s.notebook = state.meta.notebook
            s.deleted = state.deleted
            s.pages = state.pages.count
            s.strokes = state.pages.reduce(0) { $0 + $1.strokes.count }
            s.recognizedPages = state.pages.filter { !($0.recognition?.text.isEmpty ?? true) }.count
            s.pageTexts = PageText.texts(of: state.pages)
            s.pagesNeedingRecognition = state.pages.filter { RecognitionPolicy.needsRecognition($0) }.count
            let items = state.pages.flatMap(\.items)
            s.items = items.count
            s.textItems = items.filter { $0.kind == .text }.count
            s.recordings = state.recordings.count
            s.transcribed = state.recordings.compactMap { r in
                r.transcript.map { TranscribedRecording(recording: r.id, title: r.title, blob: $0) }
            }
            s.blobs = state.blobReferences
            s.lang = state.meta.lang
            s.markersBehindText = state.meta.markersBehindText
            s.favorite = state.meta.favorite
            s.created = state.meta.created
            s.recognized = state.meta.recognized
        } catch {
            s.problem = "cannot reconstruct: \(error)"
        }
        return s
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
        try requireMigrated()
        _ = try requireReadable()
        let all = ids == nil
        let ids = try ids ?? noteIDs()
        let counter = ProgressCounter()
        let total = ids.count
        let results = Parallel.map(ids, width: maxConcurrency > 0 ? maxConcurrency : Parallel.defaultWidth) { id in
            Result { () throws -> (NoteSummary, Bool, [String]) in
                let names = try revisionNames(of: id)
                let files = names.map(\.filename).sorted()
                if let hit = cache?.summary(for: id, names: files) { return (hit, true, files) }
                let loaded = try loadNote(id, names: names, detail: .withoutStrokePoints)
                let s = summary(of: id, loaded: loaded)
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
    public func resolveNote(_ query: String) throws -> UUID {
        if let id = try NoteSummary.matchID(query, among: try noteIDs()) { return id }
        return try NoteSummary.find(query, in: try summaries()).id
    }

    /// The revisions `compact` would delete, without deleting them.
    public func compactionPlan(noteId: UUID, retention: TimeInterval = CompactionPlanner.defaultRetention,
                               now: Date = Date(), assumingSnapshot: Bool = false) throws -> [RevisionName] {
        try loadNote(noteId).compactionPlan(retention: retention, now: now, assumingSnapshot: assumingSnapshot)
    }

    /// See `LoadedNote.needsSnapshotBeforeCompaction`.
    public func needsSnapshotBeforeCompaction(noteId: UUID, retention: TimeInterval = CompactionPlanner.defaultRetention,
                                              now: Date = Date()) throws -> Bool {
        try loadNote(noteId).needsSnapshotBeforeCompaction(retention: retention, now: now)
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
    /// `<sanitised title>-<first 8 hex of the id>`, safe on every filesystem:
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
